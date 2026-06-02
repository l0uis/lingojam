import Foundation

/// One-shot migration that moves users from the old self-assessed
/// `VocabularyLevel` (Beginner/Intermediate/Advanced) to a CEFR level
/// stored under [`OnboardingDefaultsKey.cefrLevel`].
///
/// The old `VocabularyLevel` enum is preserved internally because the
/// onboarding "tell me which words you know" screens still use it as
/// a rank-bucket selector — that's an internal concept, distinct from
/// the user's self-assessed level.
enum VocabularyLevelMigrator {
    static func migrateIfNeeded() {
        let defaults = UserDefaults.standard
        guard defaults.string(forKey: OnboardingDefaultsKey.cefrLevel) == nil,
              let oldRaw = defaults.string(forKey: OnboardingDefaultsKey.vocabularyLevel),
              let old = VocabularyLevel(rawValue: oldRaw) else { return }

        let mapped: CEFRLevel = switch old {
        case .beginner: .a1
        case .intermediate: .b1
        case .advanced: .c1
        }
        defaults.set(mapped.rawValue, forKey: OnboardingDefaultsKey.cefrLevel)
    }
}
