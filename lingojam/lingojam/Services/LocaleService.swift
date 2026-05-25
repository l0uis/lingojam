import Foundation

enum LocaleService {
    static var preferredDefinitionLocale: String {
        Locale.current.language.languageCode?.identifier ?? "en"
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
