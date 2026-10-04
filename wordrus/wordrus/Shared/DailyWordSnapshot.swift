import Foundation

struct DailyWordSnapshot: Codable, Equatable, Hashable {
    let wordID: String
    let lemma: String
    let partOfSpeech: String
    let definition: String
    let exampleSentence: String
    let exampleTranslation: String?
    let isDueNow: Bool
    let dueDate: Date?
    let computedAt: Date

    static let storageKey = "dailyWordSnapshot.v1"

    static func load(from defaults: UserDefaults? = AppGroup.sharedDefaults) -> DailyWordSnapshot? {
        guard let data = defaults?.data(forKey: storageKey) else { return nil }
        return try? JSONDecoder.snapshot.decode(DailyWordSnapshot.self, from: data)
    }

    func save(to defaults: UserDefaults? = AppGroup.sharedDefaults) {
        guard let defaults, let data = try? JSONEncoder.snapshot.encode(self) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }

    static func clear(from defaults: UserDefaults? = AppGroup.sharedDefaults) {
        defaults?.removeObject(forKey: storageKey)
    }
}

/// Today's ordered list of words, shared with the widget and reminders so they
/// can rotate through the stack throughout the day without the app being open.
/// The first element is the current front card; the rest are upcoming. Saved
/// alongside the single `DailyWordSnapshot`, which remains the fallback before
/// the first set is built.
struct DailyWordSet: Codable, Equatable {
    let words: [DailyWordSnapshot]
    let computedAt: Date

    static let storageKey = "dailyWordSet.v1"

    static func load(from defaults: UserDefaults? = AppGroup.sharedDefaults) -> DailyWordSet? {
        guard let data = defaults?.data(forKey: storageKey) else { return nil }
        return try? JSONDecoder.snapshot.decode(DailyWordSet.self, from: data)
    }

    func save(to defaults: UserDefaults? = AppGroup.sharedDefaults) {
        guard let defaults, let data = try? JSONEncoder.snapshot.encode(self) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }

    static func clear(from defaults: UserDefaults? = AppGroup.sharedDefaults) {
        defaults?.removeObject(forKey: storageKey)
    }
}

/// Deterministic clock-driven rotation over today's word set, shared by the
/// home-screen widget timeline, the Live Activity, and the background refresh
/// task so they all agree on "which word is current right now" regardless of
/// when each of them happens to render or wake up.
enum DailyWordRotation {
    /// How long each word stays on screen. Spreads the set across ~12 waking
    /// hours, clamped so a tiny set still changes a few times a day and a large
    /// one doesn't flip too fast. Matches the widget's original inline math.
    static func interval(count: Int) -> TimeInterval {
        let span: TimeInterval = 12 * 3600
        return min(3 * 3600, max(60 * 60, span / Double(max(count, 1))))
    }

    /// Index into a `count`-element set for `date`, cycling as time passes.
    static func index(at date: Date, count: Int, since computedAt: Date) -> Int {
        guard count > 0 else { return 0 }
        let elapsed = max(0, date.timeIntervalSince(computedAt))
        let step = Int(elapsed / interval(count: count))
        return step % count
    }

    /// The next instant after `date` at which `index(at:)` advances — used for
    /// the Live Activity `staleDate` and to time the next background refresh.
    static func nextBoundary(at date: Date, count: Int, since computedAt: Date) -> Date {
        let ivl = interval(count: count)
        let elapsed = max(0, date.timeIntervalSince(computedAt))
        let nextStep = floor(elapsed / ivl) + 1
        return computedAt.addingTimeInterval(nextStep * ivl)
    }
}

private extension JSONEncoder {
    static let snapshot: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
}

private extension JSONDecoder {
    static let snapshot: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
