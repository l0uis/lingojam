import Foundation

/// The language the learner already speaks. It decides which locale key
/// `LocaleService` reads glosses from, and which language Walter writes
/// anything shown outside the role-play in (call encouragement, bubble
/// translations, enrichment definitions).
///
/// Stored, not read live from `Locale.current`: a Spanish speaker with an
/// English-language iPhone learning English needs Spanish glosses, which the
/// device locale alone would never give them.
enum NativeLanguage: String, CaseIterable, Identifiable {
    case english
    case spanish
    case french
    case italian
    case german

    var id: String { rawValue }

    /// ISO 639-1 code — the key glosses are stored under in the seed JSON's
    /// `definitions` / `translations` maps.
    var code: String {
        switch self {
        case .english: "en"
        case .spanish: "es"
        case .french: "fr"
        case .italian: "it"
        case .german: "de"
        }
    }

    /// English name, for prompts ("Write the encouragement in Spanish").
    var englishName: String {
        switch self {
        case .english: "English"
        case .spanish: "Spanish"
        case .french: "French"
        case .italian: "Italian"
        case .german: "German"
        }
    }

    /// The language's own name, for pickers ("Español").
    var endonym: String {
        switch self {
        case .english: "English"
        case .spanish: "Español"
        case .french: "Français"
        case .italian: "Italiano"
        case .german: "Deutsch"
        }
    }

    init?(code: String) {
        guard let match = Self.allCases.first(where: { $0.code == code }) else { return nil }
        self = match
    }

    /// First supported language in the user's device preference order, or
    /// English when none match.
    static var deviceDefault: NativeLanguage {
        for identifier in Locale.preferredLanguages {
            if let code = Locale(identifier: identifier).language.languageCode?.identifier,
               let match = NativeLanguage(code: code) {
                return match
            }
        }
        return .english
    }

    /// Native languages that currently have at least one target to learn.
    /// Until the English seed ships this is just `.english`, which keeps the
    /// native picker hidden.
    static var selectable: [NativeLanguage] {
        allCases.filter { !TargetLanguage.offered(to: $0).isEmpty }
    }

    /// Pre-selection for onboarding's "I speak" picker: the device language
    /// when it's selectable, English otherwise.
    static var onboardingDefault: NativeLanguage {
        selectable.contains(deviceDefault) ? deviceDefault : .english
    }

    /// The learner's native language.
    ///
    /// Installs that finished onboarding before this setting existed were
    /// all English speakers by construction (English was the only gloss and
    /// UI language), so they resolve to `.english` — not the device default,
    /// which would reclassify e.g. a Spanish-locale user learning French as
    /// a Spanish speaker. The value is persisted on first read so it can't
    /// drift if the device language changes later.
    static var current: NativeLanguage {
        get {
            let defaults = UserDefaults.standard
            if let raw = defaults.string(forKey: OnboardingDefaultsKey.nativeLanguage),
               let stored = NativeLanguage(rawValue: raw) {
                return stored
            }
            guard OnboardingStore.hasCompleted else { return deviceDefault }
            defaults.set(NativeLanguage.english.rawValue, forKey: OnboardingDefaultsKey.nativeLanguage)
            return .english
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: OnboardingDefaultsKey.nativeLanguage)
        }
    }
}
