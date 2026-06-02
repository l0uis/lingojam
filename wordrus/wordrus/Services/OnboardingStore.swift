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
    static let learningReason = "wordrus.onboarding.learningReason"
    static let vocabularyLevel = "wordrus.onboarding.vocabularyLevel"
    static let cefrLevel = "wordrus.onboarding.cefrLevel"
    static let cefrPassesAtCurrentLevel = "wordrus.onboarding.cefrPassesAtCurrentLevel"
    static let lastWalterCallDate = "wordrus.walter.lastCallDate"
    static let scheduledWalterCallDates = "wordrus.walter.scheduledCallDates"
    static let targetLanguage = "wordrus.onboarding.targetLanguage"
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

    var id: String { rawValue }

    var title: String {
        switch self {
        case .spanish: "Spanish"
        case .french: "French"
        case .italian: "Italian"
        case .german: "German"
        }
    }

    /// Native-script subtitle for visual interest in the picker.
    var subtitle: String {
        switch self {
        case .spanish: "Español"
        case .french: "Français"
        case .italian: "Italiano"
        case .german: "Deutsch"
        }
    }

    var flag: String {
        switch self {
        case .spanish: "🇪🇸"
        case .french: "🇫🇷"
        case .italian: "🇮🇹"
        case .german: "🇩🇪"
        }
    }

    /// Image asset name for the country flag artwork in Assets.xcassets.
    var flagAssetName: String {
        switch self {
        case .spanish: "ES - Spain"
        case .french: "FR - France"
        case .italian: "IT - Italy"
        case .german: "DE - Germany"
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
        }
    }

    /// BCP-47 region-tagged locale used by AVSpeechSynthesis and OpenAI TTS.
    var bcp47: String {
        switch self {
        case .spanish: "es-ES"
        case .french: "fr-FR"
        case .italian: "it-IT"
        case .german: "de-DE"
        }
    }

    /// Filename (without extension) of the bundled vocabulary seed.
    var seedResourceName: String {
        switch self {
        case .spanish: "spanish_top1000"
        case .french: "french_top1000"
        case .italian: "italian_top1000"
        case .german: "german_top1000"
        }
    }

    /// English name used in prompts and UI strings ("learn Spanish",
    /// "practice your French"). Same as `title` but kept distinct so callers
    /// can express intent (display vs. prompt copy) clearly.
    var englishName: String { title }

    /// Endonym used in chat prompts ("habla en español", "parle en français").
    var endonym: String {
        switch self {
        case .spanish: "español"
        case .french: "français"
        case .italian: "italiano"
        case .german: "Deutsch"
        }
    }

    /// Endonym for "in {language}" used in TTS placeholders / inline prompts.
    var inEndonym: String {
        switch self {
        case .spanish: "en español"
        case .french: "en français"
        case .italian: "in italiano"
        case .german: "auf Deutsch"
        }
    }
}

/// Onboarding interest picker. These mirror the bundled deck taxonomy 1:1 —
/// each topic's `rawValue` is the deck slug, so a selection maps straight onto
/// a `Deck`. Keep in sync with the `decks` array in the `*_top1000.json` seeds.
enum LearningTopic: String, CaseIterable, Identifiable {
    case traveling
    case foodAndDrink = "food-and-drink"
    case shopping
    case health
    case workAndMoney = "work-and-money"
    case feelings
    case home
    case family

    var id: String { rawValue }

    /// The slug of the `Deck` this topic corresponds to.
    var deckSlug: String { rawValue }

    var title: String {
        switch self {
        case .traveling: "Traveling"
        case .foodAndDrink: "Food & Drink"
        case .shopping: "Shopping"
        case .health: "Health & Body"
        case .workAndMoney: "Work & Money"
        case .feelings: "Feelings"
        case .home: "Home & Daily Life"
        case .family: "Family & People"
        }
    }

    var systemImage: String {
        switch self {
        case .traveling: "airplane"
        case .foodAndDrink: "fork.knife"
        case .shopping: "cart.fill"
        case .health: "heart.fill"
        case .workAndMoney: "briefcase.fill"
        case .feelings: "face.smiling.fill"
        case .home: "house.fill"
        case .family: "person.2.fill"
        }
    }
}

enum LearningReason: String, CaseIterable, Identifiable {
    case travel
    case work
    case family
    case study
    case curiosity

    var id: String { rawValue }

    var title: String {
        switch self {
        case .travel: "Travel"
        case .work: "Career & work"
        case .family: "Connect with family"
        case .study: "School or study"
        case .curiosity: "Personal interest"
        }
    }

    var subtitle: String {
        switch self {
        case .travel: "Get by — and beyond — on trips."
        case .work: "Communicate confidently at work."
        case .family: "Chat with friends and relatives."
        case .study: "Pass classes, exams, or research."
        case .curiosity: "Just love languages."
        }
    }

    var systemImage: String {
        switch self {
        case .travel: "airplane"
        case .work: "briefcase.fill"
        case .family: "person.2.fill"
        case .study: "graduationcap.fill"
        case .curiosity: "sparkles"
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
        case .beginner: "Beginner"
        case .intermediate: "Intermediate"
        case .advanced: "Advanced"
        }
    }

    var subtitle: String {
        switch self {
        case .beginner: "Just getting started"
        case .intermediate: "I can hold short conversations"
        case .advanced: "I'm comfortable in most situations"
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
    var topics: Set<LearningTopic> = []
    var learningReason: LearningReason?
    var cefrLevel: CEFRLevel?
    var knownWordIDs: Set<String> = []
    var targetLanguage: TargetLanguage?
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
            OnboardingDefaultsKey.learningReason,
            OnboardingDefaultsKey.vocabularyLevel,
            OnboardingDefaultsKey.cefrLevel,
            OnboardingDefaultsKey.cefrPassesAtCurrentLevel,
            OnboardingDefaultsKey.lastWalterCallDate,
            OnboardingDefaultsKey.targetLanguage,
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
        if let reason = state.learningReason {
            defaults.set(reason.rawValue, forKey: OnboardingDefaultsKey.learningReason)
        }
        if let level = state.cefrLevel {
            defaults.set(level.rawValue, forKey: OnboardingDefaultsKey.cefrLevel)
        }
        if let language = state.targetLanguage {
            defaults.set(language.rawValue, forKey: OnboardingDefaultsKey.targetLanguage)
        }
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

    static var topics: [LearningTopic] {
        let raws = UserDefaults.standard.stringArray(forKey: OnboardingDefaultsKey.topics) ?? []
        return raws.compactMap { LearningTopic(rawValue: $0) }
    }
}
