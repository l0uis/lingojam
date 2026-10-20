import Foundation

/// A language curiosity — an idiom, a word English doesn't have, a false
/// friend, or a compound that's funny taken literally. Every few days one sits
/// on top of the end-of-day card as a bonus, with a share image in the style
/// of the TikTok posts. Content lives in `curiosities_<code>.json`.
struct Curiosity: Decodable, Identifiable, Equatable {
    enum Kind: String, Decodable {
        case idiom
        case untranslatable
        case falseFriend
        case literal
    }

    let id: String
    let kind: Kind
    /// The word or phrase in the target language.
    let phrase: String
    /// Word-for-word English ("to give pumpkins"). Idioms and compounds.
    let literal: String?
    /// The English word it's mistaken for. False friends only.
    let looksLike: String?
    let meaning: String
    let example: String
    let exampleTranslation: String
    /// Dr Tusk's aside, shown in his speech bubble.
    let quip: String
}

/// Decides when a curiosity is due and remembers today's pick, so a relaunch
/// mid-set brings back the same card until it's swiped away.
///
/// Cadence: every 2–3 days (alternating gaps of 2 and 3), counted from the
/// learner's first set, which never gets one — the first day already ends
/// with a call and the paywall.
enum CuriosityService {
    private static let lastShownDayKey = "curiosity.lastShownDay"
    private static let shownCountKey = "curiosity.shownCount"
    private static let todayKey = "curiosity.todayDay"
    private static let todayIDKey = "curiosity.todayID"
    private static let dismissedKey = "curiosity.dismissed"

    private static var defaults: UserDefaults { .standard }
    private static var cache: [String: [Curiosity]] = [:]

    static func all(for language: TargetLanguage) -> [Curiosity] {
        let code = language.languageCode
        if let cached = cache[code] { return cached }
        guard let url = Bundle.main.url(forResource: "curiosities_\(code)", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let items = try? JSONDecoder().decode([Curiosity].self, from: data)
        else {
            cache[code] = []
            return []
        }
        cache[code] = items
        return items
    }

    /// Called as the daily set nears its end. Returns the curiosity to deal
    /// in as the set's last card, or nil when none is due today. Safe to call
    /// repeatedly: it returns today's pick until it's dismissed, then nil.
    static func pickForToday(language: TargetLanguage, now: Date = .now) -> Curiosity? {
        if let pending = pending(language: language, now: now) { return pending }
        let today = dayNumber(now)
        let lastShown = defaults.integer(forKey: lastShownDayKey)
        if lastShown == 0 {
            // First set: start the clock so the first curiosity lands the
            // next time they reach the end of a set from tomorrow on.
            defaults.set(today - 1, forKey: lastShownDayKey)
            return nil
        }
        let shownCount = defaults.integer(forKey: shownCountKey)
        let gap = shownCount.isMultiple(of: 2) ? 2 : 3
        guard today - lastShown >= gap else { return nil }

        let items = all(for: language)
        guard !items.isEmpty else { return nil }
        let indexKey = "curiosity.nextIndex.\(language.languageCode)"
        let index = defaults.integer(forKey: indexKey)
        let item = items[index % items.count]

        defaults.set(index + 1, forKey: indexKey)
        defaults.set(today, forKey: lastShownDayKey)
        defaults.set(shownCount + 1, forKey: shownCountKey)
        defaults.set(DailySetConfig.dayKey(now), forKey: todayKey)
        defaults.set(item.id, forKey: todayIDKey)
        defaults.set(false, forKey: dismissedKey)
        Analytics.capture(.curiosityShown, [
            "curiosity": item.id,
            "kind": item.kind.rawValue,
            "language": language.languageCode,
        ])
        return item
    }

    /// Today's curiosity if one was picked and hasn't been swiped away yet.
    /// Nil after a language switch: the pick belongs to the old language.
    static func pending(language: TargetLanguage, now: Date = .now) -> Curiosity? {
        guard defaults.string(forKey: todayKey) == DailySetConfig.dayKey(now),
              !defaults.bool(forKey: dismissedKey),
              let id = defaults.string(forKey: todayIDKey)
        else { return nil }
        return all(for: language).first { $0.id == id }
    }

    static func dismiss(_ curiosity: Curiosity) {
        defaults.set(true, forKey: dismissedKey)
        Analytics.capture(.curiosityDismissed, ["curiosity": curiosity.id])
    }

    /// Days since the start of the calendar's era — consecutive integers, so
    /// differences are day gaps in the learner's own time zone.
    private static func dayNumber(_ date: Date) -> Int {
        Calendar.current.ordinality(of: .day, in: .era, for: date) ?? 0
    }
}
