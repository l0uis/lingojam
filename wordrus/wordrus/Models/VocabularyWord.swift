import Foundation
import SwiftData

@Model
final class VocabularyWord {
    @Attribute(.unique) var id: String
    var rank: Int
    var lemma: String
    var partOfSpeech: String
    var definitionsJSON: String
    var exampleSentence: String
    var exampleTranslationsJSON: String
    var deckSlugsJSON: String = "[]"
    var cefrLevel: String? = nil

    init(
        id: String,
        rank: Int,
        lemma: String,
        partOfSpeech: String,
        definitionsJSON: String,
        exampleSentence: String,
        exampleTranslationsJSON: String,
        deckSlugsJSON: String = "[]",
        cefrLevel: String? = nil
    ) {
        self.id = id
        self.rank = rank
        self.lemma = lemma
        self.partOfSpeech = partOfSpeech
        self.definitionsJSON = definitionsJSON
        self.exampleSentence = exampleSentence
        self.exampleTranslationsJSON = exampleTranslationsJSON
        self.deckSlugsJSON = deckSlugsJSON
        self.cefrLevel = cefrLevel
    }

    var definitions: [String: String] {
        decodeStringMap(definitionsJSON)
    }

    var exampleTranslations: [String: String] {
        decodeStringMap(exampleTranslationsJSON)
    }

    var deckSlugs: [String] {
        guard let data = deckSlugsJSON.data(using: .utf8),
              let list = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return list
    }

    func setDeckSlugs(_ slugs: [String]) {
        let unique = Array(NSOrderedSet(array: slugs)) as? [String] ?? slugs
        if let data = try? JSONEncoder().encode(unique),
           let json = String(data: data, encoding: .utf8) {
            deckSlugsJSON = json
        }
    }

    private func decodeStringMap(_ json: String) -> [String: String] {
        guard let data = json.data(using: .utf8),
              let dict = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return dict
    }

    /// The language this word belongs to, derived from its `id`. Seeded ids
    /// are `"<lang>-NNNN"` (e.g. `"es-0001"`); user-added ids are
    /// `"custom-<lang>-<uuid>"`. Used to scope queries now that custom words
    /// of multiple languages can coexist (they survive language switches).
    var languageCode: String {
        let parts = id.split(separator: "-", omittingEmptySubsequences: false)
        if id.hasPrefix("custom-") {
            return parts.count >= 2 ? String(parts[1]) : ""
        }
        return parts.first.map(String.init) ?? ""
    }
}

extension Sequence where Element == VocabularyWord {
    /// Keep only the words belonging to `languageCode`. Required because
    /// user-added custom words persist across language switches, so the store
    /// can hold words from several languages at once.
    func scoped(to languageCode: String) -> [VocabularyWord] {
        filter { $0.languageCode == languageCode }
    }
}
