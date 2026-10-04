import Foundation

enum LocaleService {
    /// Locale key glosses are read from and written under — the learner's
    /// stored native language, not the device locale (see `NativeLanguage`).
    static var preferredDefinitionLocale: String {
        NativeLanguage.current.code
    }

    static func definition(for word: VocabularyWord) -> String {
        let map = word.definitions
        if let value = map[preferredDefinitionLocale], !value.isEmpty {
            return value
        }
        if let fallback = map["en"], !fallback.isEmpty {
            return fallback
        }
        return map.values.first ?? ""
    }

    static func exampleTranslation(for word: VocabularyWord) -> String? {
        let map = word.exampleTranslations
        if let value = map[preferredDefinitionLocale], !value.isEmpty {
            return value
        }
        return map["en"]
    }
}
