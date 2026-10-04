import Foundation
import Observation

enum OnboardingDefaultsKey {
    static let hasCompleted = "wordrus.onboarding.hasCompleted"
    static let displayName = "wordrus.onboarding.displayName"
    static let notificationsEnabled = "wordrus.onboarding.notificationsEnabled"
    static let notificationsPerDay = "wordrus.onboarding.notificationsPerDay"
    static let notificationStartHour = "wordrus.onboarding.notificationStartHour"
    static let notificationStartMinute = "wordrus.onboarding.notificationStartMinute"
    static let notificationEndHour = "wordrus.onboarding.notificationEndHour"
    static let notificationEndMinute = "wordrus.onboarding.notificationEndMinute"
    static let notificationDaysOfWeek = "wordrus.onboarding.notificationDaysOfWeek"
    static let topics = "wordrus.onboarding.topics"
    static let vocabularyLevel = "wordrus.onboarding.vocabularyLevel"
    static let cefrLevel = "wordrus.onboarding.cefrLevel"
    static let cefrPassesAtCurrentLevel = "wordrus.onboarding.cefrPassesAtCurrentLevel"
    /// Whether the rotating-word Live Activity is switched on (Settings toggle).
    static let liveActivityEnabled = "wordrus.liveActivity.enabled"
    static let lastWalterCallDate = "wordrus.walter.lastCallDate"
    static let scheduledWalterCallDates = "wordrus.walter.scheduledCallDates"
    static let targetLanguage = "wordrus.onboarding.targetLanguage"
    /// The learner's own language — see `NativeLanguage.current`.
    static let nativeLanguage = "wordrus.onboarding.nativeLanguage"
    /// Language whose vocabulary was last loaded into SwiftData. Tracked
    /// separately from `targetLanguage` so we can detect mismatches (e.g. user
    /// reset onboarding) and avoid wiping data when no swap is needed.
    /// Intentionally NOT cleared by `OnboardingStore.reset()` — the bundled
    /// data outlives an onboarding reset until a different language is picked.
    static let seededLanguage = "wordrus.seed.seededLanguage"
    /// Version of the deck taxonomy last applied to the local SwiftData store.
    /// Bumped whenever the bundled seeds change their deck slugs so existing
    /// installs can migrate without a full wipe.
    static let deckTaxonomyVersion = "wordrus.seed.deckTaxonomyVersion"
    /// Set once existing `ChatSession` rows have had their `languageRaw`
    /// stamped with the then-current target language. Before the per-language
    /// Phone history feature, switching language wiped all sessions, so any
    /// pre-existing rows belong to the active language at upgrade time.
    static let chatSessionLanguageBackfilled = "wordrus.seed.chatSessionLanguageBackfilled"
}

enum TargetLanguage: String, CaseIterable, Identifiable {
    case spanish
    case french
    case italian
    case german
    /// British English, for es/fr/it/de speakers. Only offered once its seed
    /// ships (see `isBundled`) so a missing file can't fall back to Spanish.
    case english

    var id: String { rawValue }

    /// Targets a speaker of `native` can pick: English speakers learn the
    /// four European languages, everyone else learns English. Never the
    /// learner's own language, and never a language whose seed isn't bundled.
    static func offered(to native: NativeLanguage) -> [TargetLanguage] {
        let candidates: [TargetLanguage] = native == .english
            ? [.spanish, .french, .italian, .german]
            : [.english]
        return candidates.filter(\.isBundled)
    }

    /// Whether this language's vocabulary seed is in the app bundle.
    var isBundled: Bool {
        Bundle.main.url(forResource: seedResourceName, withExtension: "json") != nil
    }

    /// Display name in the UI language ("Spanish", "Español", "Spagnolo"…).
    /// Prompts must use `englishName` instead.
    var title: String {
        switch self {
        case .spanish: String(localized: "Spanish")
        case .french: String(localized: "French")
        case .italian: String(localized: "Italian")
        case .german: String(localized: "German")
        case .english: String(localized: "English")
        }
    }

    /// Native-script subtitle for visual interest in the picker.
    var subtitle: String {
        switch self {
        case .spanish: "Español"
        case .french: "Français"
        case .italian: "Italiano"
        case .german: "Deutsch"
        case .english: String(localized: "British English")
        }
    }

    var flag: String {
        switch self {
        case .spanish: "🇪🇸"
        case .french: "🇫🇷"
        case .italian: "🇮🇹"
        case .german: "🇩🇪"
        case .english: "🇬🇧"
        }
    }

    /// Image asset name for the country flag artwork in Assets.xcassets.
    var flagAssetName: String {
        switch self {
        case .spanish: "ES - Spain"
        case .french: "FR - France"
        case .italian: "IT - Italy"
        case .german: "DE - Germany"
        case .english: "GB - United Kingdom"
        }
    }

    /// ISO 639-1 code used as the JSON key for example sentences and as
    /// the suffix for language-specific resources (e.g. walrus templates).
    var languageCode: String {
        switch self {
        case .spanish: "es"
        case .french: "fr"
        case .italian: "it"
        case .german: "de"
        case .english: "en"
        }
    }

    /// BCP-47 region-tagged locale used by AVSpeechSynthesis and OpenAI TTS.
    var bcp47: String {
        switch self {
        case .spanish: "es-ES"
        case .french: "fr-FR"
        case .italian: "it-IT"
        case .german: "de-DE"
        case .english: "en-GB"
        }
    }

    /// Filename (without extension) of the bundled vocabulary seed.
    var seedResourceName: String {
        switch self {
        case .spanish: "spanish_top1000"
        case .french: "french_top1000"
        case .italian: "italian_top1000"
        case .german: "german_top1000"
        case .english: "english_top1000"
        }
    }

    /// `title` for use mid-sentence ("practise your español" → "tu
    /// español"): Romance languages lowercase language names; German and
    /// English capitalise them.
    var titleInSentence: String {
        let ui = Bundle.main.preferredLocalizations.first ?? "en"
        return ["es", "fr", "it"].contains(ui) ? title.lowercased() : title
    }

    /// English name for LLM prompts and proxy payloads ("learn Spanish").
    /// Never shown to the user — UI copy uses the localized `title`.
    var englishName: String {
        switch self {
        case .spanish: "Spanish"
        case .french: "French"
        case .italian: "Italian"
        case .german: "German"
        case .english: "English"
        }
    }

    /// Endonym used in chat prompts ("habla en español", "parle en français").
    var endonym: String {
        switch self {
        case .spanish: "español"
        case .french: "français"
        case .italian: "italiano"
        case .german: "Deutsch"
        case .english: "English"
        }
    }

    /// Endonym for "in {language}" used in TTS placeholders / inline prompts.
    var inEndonym: String {
        switch self {
        case .spanish: "en español"
        case .french: "en français"
        case .italian: "in italiano"
        case .german: "auf Deutsch"
        case .english: "in English"
        }
    }
}

/// Onboarding interest picker. These mirror the bundled deck taxonomy 1:1 —
/// each topic's `rawValue` is the deck slug, so a selection maps straight onto
/// a `Deck`. Keep in sync with the `decks` array in the `*_top1000.json` seeds.
enum LearningTopic: String, CaseIterable, Identifiable {
    case traveling
    case weatherAndNature = "weather-and-nature"
    case animals
    case foodAndDrink = "food-and-drink"
    case shopping
    case health
    case work
    case money
    case feelings
    case home
    case family
    case outAndAbout = "out-and-about"
    case studying
    case phoneAndInternet = "phone-and-internet"

    var id: String { rawValue }

    /// The slug of the `Deck` this topic corresponds to.
    var deckSlug: String { rawValue }

    var title: String {
        switch self {
        case .traveling: String(localized: "Traveling")
        case .weatherAndNature: String(localized: "Weather & Nature")
        case .animals: String(localized: "Animals")
        case .foodAndDrink: String(localized: "Food & Drink")
        case .shopping: String(localized: "Shopping")
        case .health: String(localized: "Health & Body")
        case .work: String(localized: "Work")
        case .money: String(localized: "Money & Bills")
        case .feelings: String(localized: "Feelings")
        case .home: String(localized: "Home & Daily Life")
        case .family: String(localized: "Family & People")
        case .outAndAbout: String(localized: "Out & About")
        case .studying: String(localized: "Studying")
        case .phoneAndInternet: String(localized: "Phone & Internet")
        }
    }

    var systemImage: String {
        switch self {
        case .traveling: "airplane"
        case .weatherAndNature: "cloud.sun.fill"
        case .animals: "pawprint.fill"
        case .foodAndDrink: "fork.knife"
        case .shopping: "bag.fill"
        case .health: "heart.fill"
        case .work: "briefcase.fill"
        case .money: "creditcard.fill"
        case .feelings: "face.smiling"
        case .home: "house.fill"
        case .family: "person.2.fill"
        case .outAndAbout: "figure.walk"
        case .studying: "book.fill"
        case .phoneAndInternet: "iphone"
        }
    }
    /// Localized version of the seed deck's `description`.
    var summary: String {
        switch self {
        case .traveling: String(localized: "Trips, hotels, airports, tickets.")
        case .weatherAndNature: String(localized: "Seasons, forecast, landscape, plants.")
        case .animals: String(localized: "Pets, farm animals, birds, insects.")
        case .foodAndDrink: String(localized: "Groceries, cooking, ingredients.")
        case .shopping: String(localized: "Clothes, stores, prices, sizes.")
        case .health: String(localized: "Doctor, pharmacy, body parts, symptoms.")
        case .work: String(localized: "Jobs, office, colleagues, careers.")
        case .money: String(localized: "Banking, salary, rent, paying up.")
        case .feelings: String(localized: "Emotions, moods, reactions.")
        case .home: String(localized: "Rooms, routines, household items.")
        case .family: String(localized: "Relatives, friends, describing people.")
        case .outAndAbout: String(localized: "Going out, music, sport, hobbies.")
        case .studying: String(localized: "School, exams, courses, learning.")
        case .phoneAndInternet: String(localized: "Apps, accounts, messages, devices.")
        }
    }
}

/// Real-life situations offered on the onboarding "where will you use it"
/// step. Deliberately separate from `LearningTopic`, which names the word
/// decks: decks are vocabulary buckets (Animals, Shopping…), while learners
/// think in moments they need to get through.
enum LearningSituation: String, CaseIterable, Identifiable {
    case gettingAround = "getting-around"
    case eatingOut = "eating-out"
    case goingOut = "going-out"
    case makingFriends = "making-friends"
    case smallTalk = "small-talk"
    case trips
    case atWork = "at-work"
    case health
    case livingAbroad = "living-abroad"
    case dating
    case textingAndCalls = "texting-and-calls"
    case studying

    var id: String { rawValue }

    var title: String {
        switch self {
        case .gettingAround: String(localized: "Getting around")
        case .eatingOut: String(localized: "Eating out")
        case .goingOut: String(localized: "Going out")
        case .makingFriends: String(localized: "Making friends")
        case .smallTalk: String(localized: "Small talk")
        case .trips: String(localized: "Trips & hotels")
        case .atWork: String(localized: "At work")
        case .health: String(localized: "Health & emergencies")
        case .livingAbroad: String(localized: "Living abroad")
        case .dating: String(localized: "Dating")
        case .textingAndCalls: String(localized: "Texting & calls")
        case .studying: String(localized: "Studying")
        }
    }

    var systemImage: String {
        switch self {
        case .gettingAround: "map.fill"
        case .eatingOut: "fork.knife"
        case .goingOut: "wineglass.fill"
        case .makingFriends: "person.2.fill"
        case .smallTalk: "bubble.left.and.bubble.right.fill"
        case .trips: "airplane"
        case .atWork: "briefcase.fill"
        case .health: "cross.case.fill"
        case .livingAbroad: "house.fill"
        case .dating: "heart.fill"
        case .textingAndCalls: "message.fill"
        case .studying: "book.fill"
        }
    }

    /// The decks whose words serve this situation — for steering word
    /// selection toward what the learner picked.
    var decks: [LearningTopic] {
        switch self {
        case .gettingAround: [.traveling, .outAndAbout]
        case .eatingOut: [.foodAndDrink, .money]
        case .goingOut: [.outAndAbout, .foodAndDrink]
        case .makingFriends: [.family, .feelings, .outAndAbout]
        case .smallTalk: [.feelings, .weatherAndNature, .home]
        case .trips: [.traveling]
        case .atWork: [.work]
        case .health: [.health]
        case .livingAbroad: [.home, .money, .shopping]
        case .dating: [.feelings, .family, .outAndAbout]
        case .textingAndCalls: [.phoneAndInternet]
        case .studying: [.studying]
        }
    }
}

enum VocabularyLevel: String, CaseIterable, Identifiable {
    case beginner
    case intermediate
    case advanced

    var id: String { rawValue }

    var title: String {
        switch self {
        case .beginner: String(localized: "Beginner")
        case .intermediate: String(localized: "Intermediate")
        case .advanced: String(localized: "Advanced")
        }
    }

    var subtitle: String {
        switch self {
        case .beginner: String(localized: "Just getting started")
        case .intermediate: String(localized: "I can hold short conversations")
        case .advanced: String(localized: "I'm comfortable in most situations")
        }
    }

    var systemImage: String {
        switch self {
        case .beginner: "leaf"
        case .intermediate: "flame"
        case .advanced: "bolt.fill"
        }
    }

    /// Inclusive rank range used to bucket the top-N word list.
    /// Beginner = most common, Advanced = least common in the list.
    var rankRange: ClosedRange<Int> {
        switch self {
        case .beginner: 1...200
        case .intermediate: 201...500
        case .advanced: 501...1000
        }
    }
}

@Observable
final class OnboardingState {
    var displayName: String = ""
    var dailySetSize: Int = DailySetConfig.defaultSize
    var notificationsPerDay: Int = 5
    var notificationStart: DateComponents = DateComponents(hour: 9, minute: 0)
    var notificationEnd: DateComponents = DateComponents(hour: 20, minute: 0)
    var notificationsAuthorized: Bool = false
    var topics: Set<LearningSituation> = []
    var cefrLevel: CEFRLevel?
    var knownWordIDs: Set<String> = []
    var targetLanguage: TargetLanguage?
    /// Only defaults to the device language when that language has something
    /// to learn (see `NativeLanguage.onboardingDefault`); otherwise a
    /// Spanish-locale user would be offered no targets at all.
    var nativeLanguage: NativeLanguage = .onboardingDefault
}

enum OnboardingStore {
    static var hasCompleted: Bool {
        UserDefaults.standard.bool(forKey: OnboardingDefaultsKey.hasCompleted)
    }

    static func reset() {
        let defaults = UserDefaults.standard
        let keys = [
            OnboardingDefaultsKey.hasCompleted,
            OnboardingDefaultsKey.displayName,
            DailySetConfig.defaultsKey,
            OnboardingDefaultsKey.notificationsEnabled,
            OnboardingDefaultsKey.notificationsPerDay,
            OnboardingDefaultsKey.notificationStartHour,
            OnboardingDefaultsKey.notificationStartMinute,
            OnboardingDefaultsKey.notificationEndHour,
            OnboardingDefaultsKey.notificationEndMinute,
            OnboardingDefaultsKey.topics,
            OnboardingDefaultsKey.vocabularyLevel,
            OnboardingDefaultsKey.cefrLevel,
            OnboardingDefaultsKey.cefrPassesAtCurrentLevel,
            OnboardingDefaultsKey.lastWalterCallDate,
            OnboardingDefaultsKey.targetLanguage,
            OnboardingDefaultsKey.nativeLanguage,
        ]
        for key in keys { defaults.removeObject(forKey: key) }
    }

    static func persist(_ state: OnboardingState) {
        let defaults = UserDefaults.standard
        let trimmedName = state.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedName.isEmpty {
            defaults.set(trimmedName, forKey: OnboardingDefaultsKey.displayName)
        }
        defaults.set(DailySetConfig.clamp(state.dailySetSize), forKey: DailySetConfig.defaultsKey)
        defaults.set(state.notificationsAuthorized, forKey: OnboardingDefaultsKey.notificationsEnabled)
        defaults.set(state.notificationsPerDay, forKey: OnboardingDefaultsKey.notificationsPerDay)
        defaults.set(state.notificationStart.hour ?? 9, forKey: OnboardingDefaultsKey.notificationStartHour)
        defaults.set(state.notificationStart.minute ?? 0, forKey: OnboardingDefaultsKey.notificationStartMinute)
        defaults.set(state.notificationEnd.hour ?? 20, forKey: OnboardingDefaultsKey.notificationEndHour)
        defaults.set(state.notificationEnd.minute ?? 0, forKey: OnboardingDefaultsKey.notificationEndMinute)
        defaults.set(state.topics.map(\.rawValue), forKey: OnboardingDefaultsKey.topics)
        if let level = state.cefrLevel {
            defaults.set(level.rawValue, forKey: OnboardingDefaultsKey.cefrLevel)
        }
        if let language = state.targetLanguage {
            defaults.set(language.rawValue, forKey: OnboardingDefaultsKey.targetLanguage)
        }
        defaults.set(state.nativeLanguage.rawValue, forKey: OnboardingDefaultsKey.nativeLanguage)
        defaults.set(true, forKey: OnboardingDefaultsKey.hasCompleted)
    }

    static var displayName: String? {
        let value = UserDefaults.standard.string(forKey: OnboardingDefaultsKey.displayName)
        return value?.isEmpty == false ? value : nil
    }

    static var notificationsPerDay: Int {
        let value = UserDefaults.standard.integer(forKey: OnboardingDefaultsKey.notificationsPerDay)
        return value > 0 ? value : 10
    }

    static var notificationStart: DateComponents {
        let hour = UserDefaults.standard.object(forKey: OnboardingDefaultsKey.notificationStartHour) as? Int ?? 9
        let minute = UserDefaults.standard.object(forKey: OnboardingDefaultsKey.notificationStartMinute) as? Int ?? 0
        return DateComponents(hour: hour, minute: minute)
    }

    static var notificationEnd: DateComponents {
        let hour = UserDefaults.standard.object(forKey: OnboardingDefaultsKey.notificationEndHour) as? Int ?? 20
        let minute = UserDefaults.standard.object(forKey: OnboardingDefaultsKey.notificationEndMinute) as? Int ?? 0
        return DateComponents(hour: hour, minute: minute)
    }

    static var notificationDaysOfWeek: Set<Int> {
        get {
            guard let stored = UserDefaults.standard.array(forKey: OnboardingDefaultsKey.notificationDaysOfWeek) as? [Int],
                  !stored.isEmpty else {
                return Set(1...7)
            }
            return Set(stored.filter { (1...7).contains($0) })
        }
        set {
            let normalized = newValue.filter { (1...7).contains($0) }.sorted()
            UserDefaults.standard.set(normalized, forKey: OnboardingDefaultsKey.notificationDaysOfWeek)
        }
    }

    static func setNotificationStart(_ components: DateComponents) {
        UserDefaults.standard.set(components.hour ?? 9, forKey: OnboardingDefaultsKey.notificationStartHour)
        UserDefaults.standard.set(components.minute ?? 0, forKey: OnboardingDefaultsKey.notificationStartMinute)
    }

    static func setNotificationEnd(_ components: DateComponents) {
        UserDefaults.standard.set(components.hour ?? 20, forKey: OnboardingDefaultsKey.notificationEndHour)
        UserDefaults.standard.set(components.minute ?? 0, forKey: OnboardingDefaultsKey.notificationEndMinute)
    }

    static var notificationsEnabled: Bool {
        UserDefaults.standard.bool(forKey: OnboardingDefaultsKey.notificationsEnabled)
    }

    static var vocabularyLevel: VocabularyLevel? {
        guard let raw = UserDefaults.standard.string(forKey: OnboardingDefaultsKey.vocabularyLevel) else { return nil }
        return VocabularyLevel(rawValue: raw)
    }

    static var targetLanguage: TargetLanguage? {
        guard let raw = UserDefaults.standard.string(forKey: OnboardingDefaultsKey.targetLanguage) else { return nil }
        return TargetLanguage(rawValue: raw)
    }

    static var cefrLevel: CEFRLevel {
        get {
            if let raw = UserDefaults.standard.string(forKey: OnboardingDefaultsKey.cefrLevel),
               let level = CEFRLevel(rawValue: raw) {
                return level
            }
            return .a1
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: OnboardingDefaultsKey.cefrLevel)
        }
    }

    static var cefrPassesAtCurrentLevel: Int {
        get { UserDefaults.standard.integer(forKey: OnboardingDefaultsKey.cefrPassesAtCurrentLevel) }
        set { UserDefaults.standard.set(newValue, forKey: OnboardingDefaultsKey.cefrPassesAtCurrentLevel) }
    }

    // MARK: - Per-language level snapshots

    /// The learner's level differs per language (C1 German, A1 Italian). The
    /// global `cefrLevel` key stays the *active* level — every @AppStorage
    /// binding, Walter prompt, and LevelAnchor read goes through it — and
    /// these snapshots swap it on language switch. Any level change made from
    /// the UI while a language is active is captured by `stashLevel` at the
    /// moment the user switches away.

    private static func levelKey(for language: TargetLanguage) -> String {
        "\(OnboardingDefaultsKey.cefrLevel).\(language.rawValue)"
    }

    private static func passesKey(for language: TargetLanguage) -> String {
        "\(OnboardingDefaultsKey.cefrPassesAtCurrentLevel).\(language.rawValue)"
    }

    /// Save the active level + promotion progress under `language`'s keys.
    /// Call with the OLD language before a switch.
    static func stashLevel(for language: TargetLanguage) {
        let defaults = UserDefaults.standard
        defaults.set(cefrLevel.rawValue, forKey: levelKey(for: language))
        defaults.set(cefrPassesAtCurrentLevel, forKey: passesKey(for: language))
    }

    /// Load `language`'s stored level + promotion progress into the active
    /// keys. A language never used before starts at A1 with zero passes —
    /// the level chips in the filter sheet are right there to correct it.
    static func activateLevel(for language: TargetLanguage) {
        let defaults = UserDefaults.standard
        let stored = defaults.string(forKey: levelKey(for: language))
            .flatMap(CEFRLevel.init(rawValue:)) ?? .a1
        cefrLevel = stored
        cefrPassesAtCurrentLevel = defaults.integer(forKey: passesKey(for: language))
    }

    static var lastWalterCallDate: Date? {
        get { UserDefaults.standard.object(forKey: OnboardingDefaultsKey.lastWalterCallDate) as? Date }
        set { UserDefaults.standard.set(newValue, forKey: OnboardingDefaultsKey.lastWalterCallDate) }
    }

    /// Fire dates of currently scheduled walrus call notifications. Used
    /// by `MissedCallReconciler` to detect calls that rang but were never
    /// answered.
    static var scheduledWalterCallDates: [Date] {
        get { (UserDefaults.standard.array(forKey: OnboardingDefaultsKey.scheduledWalterCallDates) as? [Date]) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: OnboardingDefaultsKey.scheduledWalterCallDates) }
    }

    /// Situations picked during onboarding. Installs from before the
    /// switch to situations stored deck slugs here; those don't parse and
    /// are dropped.
    static var topics: [LearningSituation] {
        let raws = UserDefaults.standard.stringArray(forKey: OnboardingDefaultsKey.topics) ?? []
        return raws.compactMap { LearningSituation(rawValue: $0) }
    }
}
