import Foundation
import SwiftData

/// Review state for a backed-up word — enough to rebuild its Known/Learning
/// bucket and its spaced-repetition schedule on restore. `latestRating` is the
/// signal that drives the Known vs Learning split (a Good/Easy review = Known).
struct BackupProgress: Codable {
    var state: String
    var easeFactor: Double
    var intervalDays: Int
    var repetitions: Int
    var lapses: Int
    var dueDate: Double
    var lastReviewedAt: Double?
    var latestRating: Int?
}

/// One user-added word, as backed up to the walrus proxy. Flat shape so the
/// worker can store it opaquely; `VocabularyWord` (+ progress) is rebuilt from
/// it on restore.
struct BackupWord: Codable {
    var id: String
    var lang: String
    var localeKey: String
    var lemma: String
    var partOfSpeech: String
    var definition: String
    var exampleSentence: String
    var exampleTranslation: String
    var addedAt: Double?
    var progress: BackupProgress?
}

/// Backs the user's added words (with review progress) up to the walrus proxy,
/// keyed by the Keychain device ID — which survives app delete/reinstall and,
/// being iCloud-synced, follows the user to a new device. See
/// `tools/walrus-proxy/src/index.ts` (`/v1/walrus/words`).
@MainActor
final class WordBackupClient {
    static let shared = WordBackupClient()

    private let session: URLSession

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        config.waitsForConnectivity = false
        self.session = URLSession(configuration: config)
    }

    private struct ListResponse: Decodable { let words: [BackupWord] }
    private struct ReplaceBody: Encodable { let words: [BackupWord] }

    /// Fetch every word backed up for this device.
    func list() async throws -> [BackupWord] {
        let (data, _) = try await send(path: "/v1/walrus/words", method: "GET", body: nil)
        return try JSONDecoder().decode(ListResponse.self, from: data).words
    }

    /// Replace the whole backup with the given snapshot (one round trip).
    func replaceAll(_ words: [BackupWord]) async throws {
        let body = try JSONEncoder().encode(ReplaceBody(words: words))
        _ = try await send(path: "/v1/walrus/words", method: "POST", body: body)
    }

    private func send(path: String, method: String, body: Data?) async throws -> (Data, HTTPURLResponse) {
        guard let url = URL(string: WalrusProxyConfig.proxyURL)?.appendingPathComponent(path) else {
            throw URLError(.badURL)
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(DeviceKeyManager.deviceID(), forHTTPHeaderField: "X-Walrus-Device-ID")
        req.setValue(Bundle.main.bundleIdentifier ?? "unknown.bundle", forHTTPHeaderField: "X-Walrus-Bundle-ID")
        req.httpBody = body

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return (data, http)
    }
}

/// Reconciles the per-device word backup with the local SwiftData store.
@MainActor
enum CustomWordSync {
    /// Push a snapshot of every custom word (with its current review progress)
    /// to the backup. One network call; called after add/delete and when the
    /// app backgrounds, so reviews from any screen are captured.
    static func pushAll(context: ModelContext) async {
        let all = (try? context.fetch(FetchDescriptor<VocabularyWord>())) ?? []
        let custom = all.filter { $0.id.hasPrefix("custom-") }.sorted { $0.rank < $1.rank }

        let progresses = (try? context.fetch(FetchDescriptor<LearningProgress>())) ?? []
        let progressByID = Dictionary(progresses.map { ($0.wordID, $0) }) { first, _ in first }

        let logs = (try? context.fetch(
            FetchDescriptor<ReviewLog>(sortBy: [SortDescriptor(\.reviewedAt, order: .reverse)])
        )) ?? []
        var latestRatingByID: [String: Int] = [:]
        for log in logs where latestRatingByID[log.wordID] == nil {
            latestRatingByID[log.wordID] = log.ratingRaw
        }

        let entries: [BackupWord] = custom.map { word in
            let def = word.definitions.first
            let localeKey = def?.key ?? "en"
            let progress = progressByID[word.id].map { p in
                BackupProgress(
                    state: p.state.rawValue,
                    easeFactor: p.easeFactor,
                    intervalDays: p.intervalDays,
                    repetitions: p.repetitions,
                    lapses: p.lapses,
                    dueDate: p.dueDate.timeIntervalSince1970,
                    lastReviewedAt: p.lastReviewedAt?.timeIntervalSince1970,
                    latestRating: latestRatingByID[word.id]
                )
            }
            return BackupWord(
                id: word.id,
                lang: word.languageCode,
                localeKey: localeKey,
                lemma: word.lemma,
                partOfSpeech: word.partOfSpeech,
                definition: def?.value ?? "",
                exampleSentence: word.exampleSentence,
                exampleTranslation: word.exampleTranslations[localeKey]
                    ?? word.exampleTranslations.values.first ?? "",
                addedAt: nil,
                progress: progress
            )
        }

        // Even an empty list is pushed, so a deletion of the last word clears
        // the backup rather than leaving a stale entry to be re-restored.
        try? await WordBackupClient.shared.replaceAll(entries)
    }

    /// Pull the backup and insert any custom words missing locally, rebuilding
    /// their Known/Learning state and spaced-repetition schedule. Idempotent:
    /// words already present are left untouched, so it's safe on every launch.
    static func restore(context: ModelContext) async {
        let backup: [BackupWord]
        do {
            backup = try await WordBackupClient.shared.list()
        } catch {
            #if DEBUG
            print("CustomWordSync.restore failed: \(error)")
            #endif
            return
        }
        guard !backup.isEmpty else { return }

        let existing = (try? context.fetch(FetchDescriptor<VocabularyWord>())) ?? []
        let existingIDs = Set(existing.map(\.id))
        let progressIDs = Set(
            ((try? context.fetch(FetchDescriptor<LearningProgress>())) ?? []).map(\.wordID)
        )

        let encoder = JSONEncoder()
        func encode(_ map: [String: String]) -> String {
            (try? encoder.encode(map)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        }

        var nextRank = (existing.map(\.rank).max() ?? 1000) + 1
        var changed = false
        for entry in backup where !existingIDs.contains(entry.id) {
            let word = VocabularyWord(
                id: entry.id,
                rank: nextRank,
                lemma: entry.lemma,
                partOfSpeech: entry.partOfSpeech,
                definitionsJSON: encode([entry.localeKey: entry.definition]),
                exampleSentence: entry.exampleSentence,
                exampleTranslationsJSON: entry.exampleTranslation.isEmpty
                    ? "{}"
                    : encode([entry.localeKey: entry.exampleTranslation])
            )
            word.setDeckSlugs([DeckConstants.myWordsSlug])
            context.insert(word)
            nextRank += 1

            if !progressIDs.contains(entry.id) {
                restoreProgress(entry, into: context)
            }
            changed = true
        }
        if changed { try? context.save() }
    }

    /// Rebuild a word's `LearningProgress` (and a `ReviewLog` for the latest
    /// rating, which is what `MyWordsView.bucket` reads to place the word in
    /// Known vs Learning). Falls back to a fresh Learning state for old backup
    /// entries that predate progress storage.
    private static func restoreProgress(_ entry: BackupWord, into context: ModelContext) {
        guard let bp = entry.progress else {
            context.insert(LearningProgress(wordID: entry.id, state: .learning, lastReviewedAt: .now))
            return
        }
        let lastReviewedAt = bp.lastReviewedAt.map { Date(timeIntervalSince1970: $0) }
        context.insert(LearningProgress(
            wordID: entry.id,
            state: LearningState(rawValue: bp.state) ?? .learning,
            easeFactor: bp.easeFactor,
            intervalDays: bp.intervalDays,
            repetitions: bp.repetitions,
            lapses: bp.lapses,
            dueDate: Date(timeIntervalSince1970: bp.dueDate),
            lastReviewedAt: lastReviewedAt
        ))
        if let raw = bp.latestRating, let rating = ReviewRating(rawValue: raw) {
            context.insert(ReviewLog(
                wordID: entry.id,
                reviewedAt: lastReviewedAt ?? .now,
                rating: rating,
                intervalBeforeDays: bp.intervalDays,
                intervalAfterDays: bp.intervalDays
            ))
        }
    }
}
