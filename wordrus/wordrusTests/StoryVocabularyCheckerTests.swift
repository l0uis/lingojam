import Foundation
import Testing
@testable import wordrus

/// These run the real NLTagger against the bundled story lexicons, so they pin
/// down both our rules and the lemmatiser quirks the lexicon aliases cover.
///
/// NLTagger's lemma model differs by platform (the iOS simulator has none for
/// Spanish), so every expectation here must hold with or without it; the
/// `withoutLemmaModel` cases force the fallback for all four languages.
struct StoryVocabularyCheckerTests {
    private func checker(
        _ code: String,
        known: [StoryWord],
        new: [StoryWord] = [],
        policy: StoryVocabularyChecker.Policy = .init(wordCount: 1...500),
        usesTaggerLemmas: Bool = true
    ) throws -> StoryVocabularyChecker {
        let lexicon = try #require(StoryLexicon.load(languageCode: code))
        return StoryVocabularyChecker(
            lexicon: lexicon, known: known, new: new, policy: policy, usesTaggerLemmas: usesTaggerLemmas
        )
    }

    // MARK: Lexicon data

    @Test(arguments: ["es", "fr", "de", "it"])
    func lexiconLoadsWithRankedSeedLemmas(code: String) throws {
        let lexicon = try #require(StoryLexicon.load(languageCode: code))
        #expect(lexicon.language == code)
        #expect(lexicon.frequency.count > 6000)
        #expect(lexicon.functionWords.count > 100)
        #expect(!lexicon.aliases.isEmpty)
        let ranks = lexicon.frequencyRanks()
        let topVerb = ["es": "ser", "fr": "être", "de": "sein", "it": "essere"][code]!
        #expect(try #require(ranks[topVerb]) <= 3)
    }

    @Test func languageSpecificMorphologyShipsOnlyWhereNeeded() throws {
        let de = try #require(StoryLexicon.load(languageCode: "de"))
        #expect(de.separablePrefixes?.contains("auf") == true)
        #expect(de.compoundLinkers?.contains("s") == true)
        let fr = try #require(StoryLexicon.load(languageCode: "fr"))
        #expect(fr.functionWords.contains("l'"))
        #expect(fr.cliticSuffixes == nil)
        let es = try #require(StoryLexicon.load(languageCode: "es"))
        #expect(es.cliticSuffixes?.first?.count == 5)   // longest first
    }

    // MARK: Spanish

    @Test func spanishContractionsNamesAndNumbers() throws {
        let c = try checker("es", known: ["ir", "mercado", "puerto", "comprar", "pez"])
        let report = c.check(story: "Dr Tusk fue al mercado del puerto con María. Compró 3 peces.")
        #expect(report.unknownLemmas == [])
        #expect(report.coverage == 1)
        // mercado puerto compró peces — "fue" is also a form of the auxiliary
        // ser, so it counts as a function word.
        #expect(report.contentTokenCount == 4)
    }

    @Test func spanishCliticsAndReflexives() throws {
        let c = try checker("es", known: ["dar", "decir", "querer", "comprar", "levantarse", "temprano"])
        let report = c.check(story: "Dámelo, dijo Dr Tusk. Quiero comprarlo. Se levanta temprano.")
        #expect(report.unknownLemmas == [])
    }

    @Test func spanishFlagsUnknownWordAndIgnoresAccents() throws {
        let c = try checker("es", known: ["comer", "café", "tomar"])
        let report = c.check(story: "Dr Tusk come una manzana y toma un cafe.")
        #expect(report.unknownLemmas == ["manzana"])
        #expect(report.unknownTokenCount == 1)
        #expect(abs(report.coverage - 3.0 / 4.0) < 0.0001)
    }

    @Test func spanishCountsNewWordUsesAcrossInflections() throws {
        let c = try checker("es", known: ["ir", "grande", "bonito"], new: ["playa"])
        let report = c.check(story: "Dr Tusk va a la playa. Las playas son grandes y bonitas.")
        #expect(report.newWordUses["playa"] == 2)
        #expect(report.passed)
    }

    @Test func spanishMultiwordNewWordCountsAsPhrase() throws {
        let c = try checker("es", known: ["comer", "pez"], new: ["tal vez"])
        let report = c.check(story: "Tal vez Dr Tusk come un pez. Tal vez no.")
        #expect(report.newWordUses["tal vez"] == 2)
    }

    // MARK: French

    @Test func frenchElisionsAndNegation() throws {
        let c = try checker("fr", known: ["homme", "voir", "là"])
        let report = c.check(story: "L'homme qu'il a vu n'est pas là.")
        #expect(report.unknownLemmas == [])
        #expect(report.coverage == 1)
    }

    @Test func frenchReflexiveContractionsAndApostropheWords() throws {
        let c = try checker("fr", known: ["se lever", "tôt", "manger", "pain", "olive", "aujourd'hui", "demain"])
        let report = c.check(story: "Aujourd'hui, Dr Tusk s'est levé tôt. J'ai mangé du pain aux olives jusqu'à demain.")
        #expect(report.unknownLemmas == [])
    }

    @Test func frenchHyphenatedInversionAndCurlyApostrophe() throws {
        let c = try checker("fr", known: ["aller", "plage", "homme"])
        let report = c.check(story: "Où va-t-il ? L’homme va à la plage.")
        #expect(report.unknownLemmas == [])
    }

    @Test func frenchFlagsUnknownWord() throws {
        let c = try checker("fr", known: ["manger"])
        let report = c.check(story: "Dr Tusk mange une pomme.")
        #expect(report.unknownLemmas == ["pomme"])
    }

    // MARK: German

    @Test func germanSeparableVerbIsRejoined() throws {
        let c = try checker("de", known: ["aufstehen", "früh"])
        let report = c.check(story: "Dr Tusk steht früh auf.")
        #expect(report.unknownLemmas == [])
        #expect(report.coverage == 1)
    }

    @Test func germanUnknownSeparableVerbIsReportedWhole() throws {
        let c = try checker("de", known: ["morgen"])
        let report = c.check(story: "Ich rufe dich morgen an.")
        #expect(report.unknownLemmas == ["anrufen"])
    }

    @Test func germanSeparableNewWordCountsInBothPositions() throws {
        let c = try checker("de", known: ["früh", "Uhr"], new: ["aufstehen"])
        let report = c.check(story: "Dr Tusk steht um 7 Uhr auf. Er ist früh aufgestanden.")
        #expect(report.newWordUses["aufstehen"] == 2)
        #expect(report.unknownLemmas == [])
    }

    @Test func germanZuInfinitiveAndModals() throws {
        let c = try checker("de", known: ["einkaufen", "Markt", "gehen", "können"])
        let report = c.check(story: "Dr Tusk kann zum Markt gehen, um einzukaufen.")
        #expect(report.unknownLemmas == [])
    }

    @Test func germanCompoundSplitsIntoKnownParts() throws {
        let known = try checker("de", known: ["Bahnhof", "Uhr", "kaputt"])
        #expect(known.check(story: "Die Bahnhofsuhr war kaputt.").unknownLemmas == [])

        let missingHead = try checker("de", known: ["Uhr", "kaputt"])
        #expect(missingHead.check(story: "Die Bahnhofsuhr war kaputt.").unknownLemmas == ["Bahnhofsuhr"])
    }

    @Test func germanTaggerQuirksAreAliased() throws {
        // kostet → "kosen", Laden → "Lade" in NLTagger.
        let c = try checker("de", known: ["Fisch", "kosten", "Laden", "viel"])
        let report = c.check(story: "Der Fisch im Laden kostet viel.")
        #expect(report.unknownLemmas == [])
    }

    @Test func germanNumbersAndNamesAreIgnored() throws {
        let c = try checker("de", known: ["kaufen", "Fisch"])
        let report = c.check(story: "Dr Tusk kauft 7 Fische.")
        #expect(report.unknownLemmas == [])
        #expect(report.contentTokenCount == 2)
    }

    // MARK: Italian

    @Test func italianArticulatedPrepositionsAndElision() throws {
        let c = try checker("it", known: ["andare", "mercato", "città", "uomo", "isola", "mangiare", "pesce"])
        let report = c.check(story: "Dr Tusk è andato al mercato della città. L'uomo dell'isola mangiò due pesci.")
        #expect(report.unknownLemmas == [])
    }

    @Test func italianClitics() throws {
        let c = try checker("it", known: ["dare", "volere", "comprare", "andare"])
        let report = c.check(story: "Dammelo! Voglio comprarlo. Andiamocene.")
        #expect(report.unknownLemmas == [])
    }

    @Test func italianElidedArticleOnUnknownWordStillFlagsIt() throws {
        let c = try checker("it", known: ["gatto"])
        let report = c.check(story: "Nell'acqua c'è un gatto.")
        #expect(report.unknownLemmas == ["acqua"])
    }

    @Test func italianModalIsVocabularyNotFunctionWord() throws {
        // Modals are learnable vocabulary; only auxiliaries are function words.
        // (Reported as "volere" or "voglio" depending on the lemma model.)
        let c = try checker("it", known: ["comprare"])
        #expect(c.check(story: "Voglio comprarlo.").unknownLemmas.count == 1)
    }

    // MARK: Without a lemma model

    struct FallbackCase: CustomTestStringConvertible, Sendable {
        let code: String
        let known: [String]
        let story: String
        var testDescription: String { code }
    }

    static let fallbackCases: [FallbackCase] = [
        FallbackCase(
            code: "es",
            known: ["comprar", "pez", "querer", "comer", "dar", "decir", "poder", "buscar", "levantarse", "playa"],
            story: "Dr Tusk compró peces y quiere comer. Dámelo, dijo. Puede buscarlo. Busqué en las playas. Se levanta."
        ),
        FallbackCase(
            code: "fr",
            known: ["manger", "pain", "homme", "voir", "là", "se lever", "tôt", "finir", "appeler"],
            story: "Dr Tusk a mangé du pain. L'homme qu'il a vu n'est pas là. Il s'est levé tôt. Il finissait. Il appelle."
        ),
        FallbackCase(
            code: "de",
            known: ["aufstehen", "früh", "einkaufen", "Laden", "fahren", "arbeiten"],
            story: "Dr Tusk steht früh auf. Er kauft im Laden ein und ist früh aufgestanden. Er fährt. Er hat gearbeitet."
        ),
        FallbackCase(
            code: "it",
            known: ["andare", "mercato", "mangiare", "pesce", "volere", "comprare", "cercare", "finire"],
            story: "Dr Tusk è andato al mercato e mangiò due pesci. Voglio comprarlo. Cerchi? Finisco."
        ),
    ]

    @Test(arguments: fallbackCases)
    func coreMorphologyHoldsWithoutLemmaModel(_ testCase: FallbackCase) throws {
        let c = try checker(testCase.code, known: testCase.known.map { StoryWord(lemma: $0) }, usesTaggerLemmas: false)
        let report = c.check(story: testCase.story)
        #expect(report.unknownLemmas == [])
    }

    @Test func fallbackStillFlagsUnknownWords() throws {
        let c = try checker("es", known: ["comer"], usesTaggerLemmas: false)
        #expect(c.check(story: "Dr Tusk come una manzana.").unknownLemmas == ["manzana"])
    }

    @Test func partOfSpeechStopsNounsBeingTreatedAsVerbs() throws {
        // "lugar" ends like an -ar verb; with noun POS it must not unlock "lugas".
        let noun = try checker("es", known: [StoryWord(lemma: "lugar", partOfSpeech: "noun (masc.)")], usesTaggerLemmas: false)
        #expect(noun.check(story: "Tú lugas.").unknownLemmas == ["lugas"])
        let inferred = try checker("es", known: ["lugar"], usesTaggerLemmas: false)
        #expect(inferred.check(story: "Tú lugas.").unknownLemmas == [])
    }

    // MARK: Policy

    @Test func passesWhenEveryRuleHolds() throws {
        let c = try checker("es", known: ["ir", "grande"], new: ["playa"], policy: .init(wordCount: 5...20))
        let report = c.check(story: "Dr Tusk va a la playa. La playa es grande.")
        #expect(report.passed)
        #expect(report.failures.isEmpty)
    }

    @Test func failsOnCoverageUnknownCountUnderuseAndLength() throws {
        let c = try checker("es", known: ["comer"], new: ["playa"], policy: .init(wordCount: 20...40))
        let report = c.check(story: "Dr Tusk come manzanas, peras, uvas y fresas en la playa.")
        #expect(report.failures.contains(.lowCoverage))
        #expect(report.failures.contains(.tooManyUnknownLemmas))
        #expect(report.failures.contains(.newWordsUnderused(["playa"])))
        #expect(report.failures.contains(.tooShort))
        #expect(report.underusedNewWords == ["playa"])
        #expect(!report.passed)
    }

    @Test func tooLongIsReported() throws {
        let c = try checker("es", known: ["comer"], policy: .init(wordCount: 1...3))
        #expect(c.check(story: "Dr Tusk come y come y come.").failures == [.tooLong])
    }

    @Test func questionsCountForCoverageButNotLengthOrNewWordUse() throws {
        let c = try checker("es", known: ["ir", "grande"], new: ["playa"], policy: .init(wordCount: 5...20))
        let report = c.check(
            story: "Dr Tusk va a la playa. La playa es grande.",
            questions: ["¿Adónde va Dr Tusk?", "A la playa", "Al castillo", "A casa"]
        )
        #expect(report.unknownLemmas == ["castillo", "casa"])
        #expect(report.newWordUses["playa"] == 2)
        #expect(report.wordCount == 10)   // "Dr" and "Tusk" are two words
    }

    @Test func reportRoundTripsThroughCodable() throws {
        let c = try checker("es", known: ["comer"], new: ["playa"])
        let report = c.check(story: "Dr Tusk come una manzana.")
        let decoded = try JSONDecoder().decode(StoryCoverageReport.self, from: JSONEncoder().encode(report))
        #expect(decoded == report)
    }

    // MARK: Folding

    @Test func foldingRules() {
        #expect(StoryVocabularyChecker.fold("Café", languageCode: "es") == "cafe")
        #expect(StoryVocabularyChecker.fold("Año", languageCode: "es") == "año")
        #expect(StoryVocabularyChecker.fold("Città", languageCode: "it") == "citta")
        #expect(StoryVocabularyChecker.fold("L’été", languageCode: "fr") == "l'ete")
        #expect(StoryVocabularyChecker.fold("Können", languageCode: "de") == "koennen")
        #expect(StoryVocabularyChecker.fold("Straße", languageCode: "de") == "strasse")
    }
}
