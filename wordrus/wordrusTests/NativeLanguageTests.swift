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
            #expect(NativeLanguage.stored == .english)
            #expect(defaults.string(forKey: nativeKey) == NativeLanguage.english.rawValue)
        }
    }

    @Test func freshInstallsFollowTheDeviceWithoutPersisting() {
        withCleanDefaults {
            #expect(NativeLanguage.stored == NativeLanguage.deviceDefault)
            #expect(defaults.string(forKey: nativeKey) == nil)
        }
    }

    @Test func storedValueWins() {
        withCleanDefaults {
            defaults.set(true, forKey: completedKey)
            NativeLanguage.stored = .spanish
            #expect(NativeLanguage.stored == .spanish)
            // With the English target switched off the app treats everyone
            // as an English speaker, whatever was stored.
            #expect(NativeLanguage.current == (FeatureFlags.offersEnglishTarget ? .spanish : .english))
        }
    }

    @Test func glossesFollowNativeLanguageThenFallBackToEnglish() {
        withCleanDefaults {
            let both = word(
                definitions: #"{"en":"house","es":"casa"}"#,
                translations: #"{"en":"I'm going home.","es":"Voy a casa."}"#
            )
            #expect(LocaleService.definition(for: both, locale: "es") == "casa")
            #expect(LocaleService.exampleTranslation(for: both, locale: "es") == "Voy a casa.")

            let englishOnly = word(definitions: #"{"en":"house"}"#)
            #expect(LocaleService.definition(for: englishOnly, locale: "es") == "house")

            #expect(LocaleService.definition(for: both, locale: "en") == "house")
        }
    }

    @Test func englishSpeakersAreOfferedTheFourEuropeanLanguages() {
        #expect(TargetLanguage.offered(to: .english) == [.spanish, .french, .italian, .german])
    }

    @Test func nobodyIsOfferedTheirOwnLanguage() {
        for native in NativeLanguage.allCases {
            #expect(!TargetLanguage.offered(to: native).map(\.languageCode).contains(native.code))
        }
    }

    @Test func otherSpeakersLearnEnglishWhenEnabled() {
        for native in NativeLanguage.allCases where native != .english {
            let expected: [TargetLanguage] = TargetLanguage.english.isBundled ? [.english] : []
            #expect(TargetLanguage.offered(to: native, englishTargetEnabled: true) == expected)
            #expect(TargetLanguage.offered(to: native, englishTargetEnabled: false) == [])
        }
        // The picker must never offer a native language with nothing to learn.
        for native in NativeLanguage.selectable {
            #expect(!TargetLanguage.offered(to: native).isEmpty)
        }
    }

    @Test func englishOnlyBuildHidesTheNativePicker() {
        guard !FeatureFlags.offersEnglishTarget else { return }
        #expect(NativeLanguage.selectable == [.english])
        #expect(NativeLanguage.onboardingDefault == .english)
        #expect(NativeLanguage.current == .english)
    }

    @Test func codesRoundTrip() {
        for language in NativeLanguage.allCases {
            #expect(NativeLanguage(code: language.code) == language)
        }
        #expect(NativeLanguage(code: "pt") == nil)
    }
}
