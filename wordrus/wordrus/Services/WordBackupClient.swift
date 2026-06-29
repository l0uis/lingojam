import Foundation
import SwiftData

/// One user-added word, as backed up to the walrus proxy. Flat shape so the
/// worker can store it as plain JSON; `VocabularyWord` is reconstructed from
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
}

/// Backs the user's added words up to the walrus proxy (keyed by the Keychain
/// device ID, which survives app delete/reinstall) so they aren't lost when
/// the local SwiftData store is wiped. See `tools/walrus-proxy/src/index.ts`
/// (`/v1/walrus/words`).
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

    /// Fetch every word backed up for this device.
    func list() async throws -> [BackupWord] {
        let (data, _) = try await send(path: "/v1/walrus/words", method: "GET", body: nil)
        return try JSONDecoder().decode(ListResponse.self, from: data).words
    }

    /// Add or update one word in the backup.
    func upsert(_ word: BackupWord) async throws {
        let body = try JSONEncoder().encode(word)
        _ = try await send(path: "/v1/walrus/words", method: "POST", body: body)
    }

    /// Remove one word from the backup (called when the user deletes it).
    func delete(id: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["id": id])
        _ = try await send(path: "/v1/walrus/words/delete", method: "POST", body: body)
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

/// Reconciles the per-device word backup into the local SwiftData store.
@MainActor
enum CustomWordSync {
    /// Pull the backup and insert any custom words missing locally — this is
    /// what restores a user's words after a delete/reinstall. Idempotent:
    /// words already present are left untouched, so it's safe to run on every
    /// launch.
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
        // Restore in the order they were added, where known.
        for entry in backup.sorted(by: { ($0.addedAt ?? 0) < ($1.addedAt ?? 0) })
        where !existingIDs.contains(entry.id) {
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
            // Seed Learning progress (unless it somehow survived) so the word
            // shows in the Learning tab, matching a fresh add.
            if !progressIDs.contains(entry.id) {
                context.insert(LearningProgress(wordID: entry.id, state: .learning, lastReviewedAt: .now))
            }
            changed = true
        }
        if changed { try? context.save() }
    }
}
