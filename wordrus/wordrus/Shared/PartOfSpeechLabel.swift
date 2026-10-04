import Foundation

/// Localized display text for a seed `partOfSpeech` value. Seeds store English
/// tags — "noun (fem.)", "noun (der)", "adjective/adverb" — and the label is
/// shown under every word, so it follows the UI language. German articles in
/// the qualifier ("der", "die/der") are target-language data and stay as-is.
enum PartOfSpeechLabel {
    static func localized(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return raw }

        var base = trimmed
        var qualifier: String?
        if let open = trimmed.firstIndex(of: "("), let close = trimmed.lastIndex(of: ")"), open < close {
            base = String(trimmed[..<open]).trimmingCharacters(in: .whitespaces)
            qualifier = String(trimmed[trimmed.index(after: open)..<close])
        }

        let head = base.split(separator: "/").map { word(String($0)) }.joined(separator: "/")
        guard let qualifier else { return head }
        return "\(head) (\(qualifierLabel(qualifier)))"
    }

    private static func word(_ english: String) -> String {
        switch english.lowercased() {
        case "noun": String(localized: "noun", comment: "Part of speech label")
        case "verb": String(localized: "verb", comment: "Part of speech label")
        case "adjective": String(localized: "adjective", comment: "Part of speech label")
        case "adverb": String(localized: "adverb", comment: "Part of speech label")
        case "interjection": String(localized: "interjection", comment: "Part of speech label")
        case "number": String(localized: "number", comment: "Part of speech label")
        case "ordinal": String(localized: "ordinal", comment: "Part of speech label")
        case "phrase": String(localized: "phrase", comment: "Part of speech label")
        case "pronoun": String(localized: "pronoun", comment: "Part of speech label")
        case "preposition": String(localized: "preposition", comment: "Part of speech label")
        case "conjunction": String(localized: "conjunction", comment: "Part of speech label")
        default: english
        }
    }

    /// "masc." / "fem." / "pl." and combinations; anything else (German
    /// articles) passes through.
    private static func qualifierLabel(_ qualifier: String) -> String {
        qualifier
            .components(separatedBy: " ")
            .map { token in
                token.split(separator: "/", omittingEmptySubsequences: false).map { part -> String in
                    switch part {
                    case "masc.": String(localized: "masc.", comment: "Grammatical gender abbreviation: masculine")
                    case "fem.": String(localized: "fem.", comment: "Grammatical gender abbreviation: feminine")
                    case "pl.": String(localized: "pl.", comment: "Grammatical number abbreviation: plural")
                    default: String(part)
                    }
                }.joined(separator: "/")
            }
            .joined(separator: " ")
    }
}
