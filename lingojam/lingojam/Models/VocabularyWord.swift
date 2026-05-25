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
}
