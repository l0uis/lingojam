import Foundation
import Testing
@testable import wordrus

/// English story vocabulary checks. The checker's apostrophe handling was
/// written for French/Italian elision, so these pin down that English
/// contractions and possessives come out as function words, not unknowns.
struct EnglishStoryCheckerTests {
    private func checker(_ known: [StoryWord], usesTaggerLemmas: Bool = true) throws -> StoryVocabularyChecker {
        let lexicon = try #require(StoryLexicon.load(languageCode: "en"))
        return StoryVocabularyChecker(
            lexicon: lexicon, known: known, new: [],
            policy: .init(wordCount: 1...500), usesTaggerLemmas: usesTaggerLemmas
        )
    }

    @Test func lexiconShipsWithRankedLemmas() throws {
        let lexicon = try #require(StoryLexicon.load(languageCode: "en"))
        #expect(lexicon.language == "en")
        #expect(lexicon.frequency.count > 4000)
        #expect(lexicon.functionWords.contains("don't"))
        #expect(lexicon.aliases["went"]?.contains("go") == true)
    }

    @Test(arguments: [true, false])
    func contractionsAndThePronounIAreFunctionWords(usesTaggerLemmas: Bool) throws {
        let c = try checker(["like", "rain", "nice", "today"], usesTaggerLemmas: usesTaggerLemmas)
        let report = c.check(story: "I don't like the rain, but it's nice today. We're fine, aren't we?")
        #expect(report.unknownLemmas.filter { $0 != "fine" } == [])
    }

    @Test(arguments: [true, false])
    func regularAndIrregularInflectionsMatchTheirLemma(usesTaggerLemmas: Bool) throws {
        let c = try checker(["go", "home", "stop", "dog", "run", "try", "hide", "city", "make"],
                            usesTaggerLemmas: usesTaggerLemmas)
        let report = c.check(story: "She went home and stopped. The dogs were running and tried to hide in the cities. He made tea.")
        #expect(report.unknownLemmas.filter { $0 != "tea" } == [])
    }

    @Test func possessivesAndNamesAreNotUnknown() throws {
        let c = try checker(["boat", "big"])
        let report = c.check(story: "Dr Tusk's boat is big. Maria's boat is big too.")
        #expect(report.unknownLemmas == [])
    }

    @Test func genuinelyUnknownWordsAreReported() throws {
        let c = try checker(["buy"])
        let report = c.check(story: "Dr Tusk bought a kite.")
        #expect(report.unknownLemmas.contains("kite"))
        #expect(!report.unknownLemmas.contains("buy"))
        #expect(!report.unknownLemmas.contains("bought"))
    }
}
