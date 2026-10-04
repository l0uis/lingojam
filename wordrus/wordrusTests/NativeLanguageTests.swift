import Foundation
import Testing
@testable import wordrus

/// Touches the real `UserDefaults.standard` keys `NativeLanguage.current`
/// reads, so the suite is serialized and restores whatever was there.
@Suite(.serialized)
@MainActor
struct NativeLanguageTests {
    private let defaults = UserDefaults.standard
    private let nativeKey = OnboardingDefaultsKey.nativeLanguage
    private let completedKey = OnboardingDefaultsKey.hasCompleted

    private func withCleanDefaults(_ body: () -> Void) {
        let savedNative = defaults.object(forKey: nativeKey)
        let savedCompleted = defaults.object(forKey: completedKey)
        defaults.removeObject(forKey: nativeKey)
        defaults.removeObject(forKey: completedKey)
        body()
        defaults.set(savedNative, forKey: nativeKey)
        defaults.set(savedCompleted, forKey: completedKey)
    }

    private func word(definitions: String, translations: String = "{}") -> VocabularyWord {
        VocabularyWord(
            id: "en-0001",
            rank: 1,
            lemma: "house",
            partOfSpeech: "noun",
            definitionsJSON: definitions,
            exampleSentence: "I'm going home.",
            exampleTranslationsJSON: translations
        )
    }

    @Test func existingInstallsResolveToEnglishAndPersistIt() {
        withCleanDefaults {
            defaults.set(true, forKey: completedKey)
            #expect(NativeLanguage.current == .english)
            #expect(defaults.string(forKey: nativeKey) == NativeLanguage.english.rawValue)
        }
    }

    @Test func freshInstallsFollowTheDeviceWithoutPersisting() {
        withCleanDefaults {
            #expect(NativeLanguage.current == NativeLanguage.deviceDefault)
            #expect(defaults.string(forKey: nativeKey) == nil)
        }
    }

    @Test func storedValueWins() {
        withCleanDefaults {
            defaults.set(true, forKey: completedKey)
            NativeLanguage.current = .spanish
            #expect(NativeLanguage.current == .spanish)
            #expect(LocaleService.preferredDefinitionLocale == "es")
        }
    }

    @Test func glossesFollowNativeLanguageThenFallBackToEnglish() {
        withCleanDefaults {
            NativeLanguage.current = .spanish
            let both = word(
                definitions: #"{"en":"house","es":"casa"}"#,
                translations: #"{"en":"I'm going home.","es":"Voy a casa."}"#
            )
            #expect(LocaleService.definition(for: both) == "casa")
            #expect(LocaleService.exampleTranslation(for: both) == "Voy a casa.")

            let englishOnly = word(definitions: #"{"en":"house"}"#)
            #expect(LocaleService.definition(for: englishOnly) == "house")

            NativeLanguage.current = .english
            #expect(LocaleService.definition(for: both) == "house")
        }
    }

    @Test func codesRoundTrip() {
        for language in NativeLanguage.allCases {
            #expect(NativeLanguage(code: language.code) == language)
        }
        #expect(NativeLanguage(code: "pt") == nil)
    }
}
