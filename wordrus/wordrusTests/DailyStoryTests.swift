import Foundation
import SwiftData
import Testing
@testable import wordrus

/// A brain that returns queued drafts, so each pipeline branch can be driven
/// deterministically.
@MainActor
private final class ScriptedStoryBrain: StoryGenerating {
    let brainName: String
    let isLastResort: Bool
    var drafts: [GeneratedStory?]
    var repairs: [GeneratedStory?]
    private(set) var generateCalls = 0
    private(set) var repairRequests: [(unknown: [String], missing: [String])] = []

    init(_ name: String, drafts: [GeneratedStory?], repairs: [GeneratedStory?] = [], isLastResort: Bool = false) {
        self.brainName = name
        self.drafts = drafts
        self.repairs = repairs
        self.isLastResort = isLastResort
    }

    func generateStory(_ request: StoryRequest) async throws -> GeneratedStory {
        generateCalls += 1
        guard !drafts.isEmpty, let draft = drafts.removeFirst() else { throw StoryGenerationError.unavailable }
        return draft
    }

    func repairStory(_ story: GeneratedStory, request: StoryRequest, unknownLemmas: [String], missingNewWords: [String]) async throws -> GeneratedStory {
        repairRequests.append((unknownLemmas, missingNewWords))
        guard !repairs.isEmpty, let repaired = repairs.removeFirst() else { throw StoryGenerationError.unavailable }
        return repaired
    }
}

@MainActor
struct DailyStoryTests {
    // MARK: Fixtures

    private let request = StoryRequest(
        language: .spanish,
        nativeLanguageCode: "en",
        level: .a1,
        knownWords: ["ir", "playa", "comer", "grande"],
        newWords: ["pez"],
        topic: "Animals",
        previousEpisodeSummary: nil
    )

    /// 80 words, all known, "pez" used 8 times — inside the A1 range.
    private func story(_ sentence: String = "Dr Tusk va a la playa y come un pez grande.", questions: [StoryQuestion]? = nil) -> GeneratedStory {
        GeneratedStory(
            title: "Dr Tusk en la playa",
            story: String(repeating: sentence + " ", count: 8),
            newWordSentences: [StoryWordSentence(word: "pez", sentence: sentence)],
            questions: questions ?? [StoryQuestion(question: "¿Quién come un pez?", options: ["Dr Tusk", "Un pez", "La playa"], answerIndex: 0)],
            episodeSummary: "Dr Tusk come un pez en la playa."
        )
    }

    private var passing: GeneratedStory { story() }
    /// One unknown word: fails coverage but is close enough to accept.
    private var nearMiss: GeneratedStory { story("Dr Tusk va a la playa y come una manzana grande.") }
    /// Three unknown words: never acceptable.
    private var farOff: GeneratedStory { story("Dr Tusk compra peras, uvas y manzanas en la playa grande.") }

    private func pipeline(_ brains: [StoryGenerating]) throws -> StoryPipeline {
        StoryPipeline(brains: brains, lexicon: try #require(StoryLexicon.load(languageCode: "es")))
    }

    // MARK: Mock brain

    @Test(arguments: TargetLanguage.allCases)
    func mockStoryIsDeterministicAndUsesEveryNewWordTwice(language: TargetLanguage) throws {
        var request = request
        request.language = language
        request.newWords = ["uno", "dos", "tres"]
        let first = MockStoryBrain.story(for: request)
        #expect(first == MockStoryBrain.story(for: request))
        #expect(first.questions.count == 2)
        #expect(first.questions.allSatisfy { $0.isWellFormed })
        #expect(first.story.contains("Dr Tusk"))
        for word in ["uno", "dos", "tres"] {
            #expect(first.story.components(separatedBy: word).count - 1 >= 2, "\(word) in \(language)")
        }
        #expect(first.newWordSentences.map(\.word) == ["uno", "dos", "tres"])
    }

    @Test func mockFillsInWhenThereAreNoNewWords() {
        var request = request
        request.newWords = []
        let story = MockStoryBrain.story(for: request)
        #expect(!story.story.contains("{N"))
        #expect(story.newWordSentences.isEmpty)
    }

    // MARK: Pipeline

    @Test func passingDraftIsAcceptedFirstTime() async throws {
        let brain = ScriptedStoryBrain("claude", drafts: [passing])
        let outcome = try await pipeline([brain]).run(request)
        #expect(outcome.brainName == "claude")
        #expect(outcome.attempts == 1)
        #expect(outcome.report.passed)
        #expect(outcome.extraWords.isEmpty)
        #expect(brain.repairRequests.isEmpty)
    }

    @Test func failingDraftIsRepairedOnceWithTheUnknownWords() async throws {
        let brain = ScriptedStoryBrain("claude", drafts: [farOff], repairs: [passing])
        let outcome = try await pipeline([brain]).run(request)
        #expect(outcome.report.passed)
        #expect(outcome.attempts == 2)
        #expect(brain.repairRequests.count == 1)
        // compra, peras, uvas, manzanas (lemma or surface, depending on the
        // device's lemma model) — and "pez" never appeared.
        #expect(brain.repairRequests[0].unknown.count >= 3)
        #expect(brain.repairRequests[0].missing == ["pez"])
    }

    @Test func nearMissIsAcceptedWithItsUnknownWordHighlighted() async throws {
        let brain = ScriptedStoryBrain("claude", drafts: [nearMiss], repairs: [nearMiss])
        let outcome = try await pipeline([brain]).run(request)
        #expect(!outcome.report.passed)
        #expect(outcome.extraWords == ["manzana"])
        #expect(brain.generateCalls == 1)
    }

    @Test func worseRepairDoesNotReplaceTheOriginal() async throws {
        let brain = ScriptedStoryBrain("claude", drafts: [nearMiss], repairs: [farOff])
        let outcome = try await pipeline([brain]).run(request)
        #expect(outcome.extraWords == ["manzana"])
    }

    @Test func farOffDraftsAreRetriedThenTheNextBrainIsUsed() async throws {
        let claude = ScriptedStoryBrain("claude", drafts: [farOff, farOff], repairs: [farOff, farOff])
        let apple = ScriptedStoryBrain("apple", drafts: [passing])
        let outcome = try await pipeline([claude, apple]).run(request)
        #expect(claude.generateCalls == 2)
        #expect(outcome.brainName == "apple")
        #expect(outcome.attempts == 5)   // 2 × (generate + repair) + 1
    }

    @Test func throwingBrainFallsThroughImmediately() async throws {
        let claude = ScriptedStoryBrain("claude", drafts: [nil])
        let apple = ScriptedStoryBrain("apple", drafts: [passing])
        let outcome = try await pipeline([claude, apple]).run(request)
        #expect(claude.generateCalls == 1)
        #expect(outcome.brainName == "apple")
    }

    @Test func lastResortDraftIsAcceptedEvenWhenItFails() async throws {
        let mock = ScriptedStoryBrain("mock", drafts: [farOff], isLastResort: true)
        let outcome = try await pipeline([mock]).run(request)
        #expect(outcome.brainName == "mock")
        #expect(!outcome.report.passed)
        #expect(outcome.extraWords.isEmpty)   // too many unknowns to highlight
        #expect(mock.repairRequests.isEmpty)
    }

    @Test func noAcceptableStoryThrows() async throws {
        let claude = ScriptedStoryBrain("claude", drafts: [farOff, farOff], repairs: [farOff, farOff])
        await #expect(throws: StoryGenerationError.noAcceptableStory) {
            try await pipeline([claude]).run(request)
        }
    }

    @Test func malformedQuestionsAreDropped() async throws {
        let questions = [
            StoryQuestion(question: "¿Quién come un pez?", options: ["Dr Tusk", "Un pez"], answerIndex: 0),
            StoryQuestion(question: "¿Dónde come?", options: ["En la playa", "Un pez", "Dr Tusk"], answerIndex: 3),
            StoryQuestion(question: "¿Qué come Dr Tusk?", options: ["Un pez", "La playa", "Dr Tusk"], answerIndex: 0),
        ]
        let outcome = try await pipeline([ScriptedStoryBrain("claude", drafts: [story(questions: questions)])]).run(request)
        #expect(outcome.story.questions.map(\.question) == ["¿Qué come Dr Tusk?"])
    }

    @Test func generatedStoryDecodesTheToolSchema() throws {
        let json = """
        {"title": "T", "story": "S", "new_word_sentences": [{"word": "pez", "sentence": "Un pez."}],
         "questions": [{"question": "Q?", "options": ["a", "b", "c"], "answer_index": 2}],
         "episode_summary": "E"}
        """
        let decoded = try JSONDecoder().decode(GeneratedStory.self, from: Data(json.utf8))
        #expect(decoded.questions.first?.answerIndex == 2)
        #expect(decoded.newWordSentences.first?.word == "pez")
        #expect(decoded.episodeSummary == "E")
    }

    // MARK: Word selection

    private func word(_ id: String, _ lemma: String, rank: Int, decks: [String] = ["common"], level: String = "A1") -> VocabularyWord {
        VocabularyWord(
            id: id, rank: rank, lemma: lemma, partOfSpeech: "noun",
            definitionsJSON: "{}", exampleSentence: "", exampleTranslationsJSON: "{}",
            deckSlugsJSON: String(decoding: try! JSONEncoder().encode(decks), as: UTF8.self),
            cefrLevel: level
        )
    }

    @Test func selectionPutsLearningWordsFirstThenKnownByTopicAndFrequency() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let words = [
            word("es-1", "casa", rank: 1, decks: ["common", "home"]),
            word("es-2", "perro", rank: 2, decks: ["common", "animals"]),
            word("es-3", "gato", rank: 3, decks: ["common", "animals"]),
            word("es-4", "mesa", rank: 4, decks: ["common", "home"]),
            word("es-5", "pez", rank: 5, decks: ["common", "animals"]),
            word("es-6", "vaca", rank: 6, decks: ["common", "animals"]),
            word("es-7", "silla", rank: 7, decks: ["common", "home"]),
        ]
        let progress = [
            LearningProgress(wordID: "es-4", state: .learning, lapses: 0, lastReviewedAt: now.addingTimeInterval(-60)),
            LearningProgress(wordID: "es-7", state: .review, lapses: 0, lastReviewedAt: now),
            LearningProgress(wordID: "es-5", state: .learning, lapses: 2, lastReviewedAt: now.addingTimeInterval(-30)),
            LearningProgress(wordID: "es-1", state: .known),
            LearningProgress(wordID: "es-2", state: .known),
            LearningProgress(wordID: "es-3", state: .known),
        ]
        let selection = StoryWordSelector.select(
            words: words,
            progressByID: Dictionary(uniqueKeysWithValues: progress.map { ($0.wordID, $0) }),
            knownIDs: ["es-1", "es-2", "es-3"],
            frequencyRanks: ["gato": 1, "perro": 2, "casa": 3],
            decks: [Deck(slug: "animals", displayName: "Animals"), Deck(slug: "home", displayName: "Home & Daily Life")],
            level: .a1,
            todaysSetIDs: ["es-5", "es-6"]
        )
        #expect(selection.topic == "Animals")
        // Shaky word from today's stack, then an unseen word from the topic.
        #expect(selection.newWords.map(\.lemma) == ["pez", "vaca"])
        // Learning (most recent first, new words excluded), then known: topic
        // words by frequency (gato before perro), then the rest.
        #expect(selection.knownWords.map(\.lemma) == ["silla", "mesa", "gato", "perro", "casa"])
    }

    @Test func beginnersGetTheirMostFrequentLevelWordsAsAFloor() {
        let words = (1...300).map { word("es-\($0)", "w\($0)", rank: $0, level: $0 % 2 == 0 ? "A1" : "B1") }
        let progress = LearningProgress(wordID: "es-2", state: .learning, lastReviewedAt: .now)
        let selection = StoryWordSelector.select(
            words: words,
            progressByID: ["es-2": progress],
            knownIDs: [],
            frequencyRanks: Dictionary(uniqueKeysWithValues: words.map { ($0.lemma, 1000 - $0.rank) }),
            decks: [],
            level: .a1,
            todaysSetIDs: []
        )
        let lemmas = selection.knownWords.map(\.lemma)
        // The learning word first, then A1 words only, most frequent first.
        #expect(lemmas.first == "w2")
        #expect(lemmas.count == 150)   // every A1 word: the floor can't invent more
        #expect(lemmas.dropFirst().first == "w300")
        #expect(Set(lemmas).isDisjoint(with: words.filter { $0.cefrLevel == "B1" }.map(\.lemma)))
    }

    @Test func selectionCapsKnownWordsAndFallsBackToAGenericTopic() {
        let words = (1...500).map { word("es-\($0)", "w\($0)", rank: $0) }
        let selection = StoryWordSelector.select(
            words: words,
            progressByID: [:],
            knownIDs: Set(words.map(\.id)),
            frequencyRanks: [:],
            decks: [],
            level: .a1,
            todaysSetIDs: []
        )
        #expect(selection.knownWords.count == StoryWordSelector.knownWordCap)
        #expect(selection.knownWords.first?.lemma == "w1")
        #expect(selection.topic == StoryWordSelector.fallbackTopic)
        #expect(selection.newWords.isEmpty)
    }

    // MARK: Storage

    private func makeContext() throws -> ModelContext {
        let schema = Schema([VocabularyWord.self, LearningProgress.self, ReviewLog.self, Deck.self, ChatSession.self, ChatMessage.self, DailyStory.self])
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true))
        return ModelContext(container)
    }

    @Test func generatedStoryIsSavedWithItsCheckResult() async throws {
        let context = try makeContext()
        let saved = try await DailyStoryService.generateAndSave(
            request: request, dayKey: "2026-10-3", context: context,
            brains: [ScriptedStoryBrain("claude", drafts: [nearMiss], repairs: [nil])], quota: .unlimited)
        #expect(saved.language == .spanish)
        #expect(saved.level == .a1)
        #expect(saved.topic == "Animals")
        #expect(saved.newWords == ["pez"])
        #expect(saved.extraWords == ["manzana"])
        #expect(saved.highlightedWords == ["pez", "manzana"])
        #expect(saved.questions.count == 1)
        #expect(saved.brainRaw == "claude")
        #expect(saved.attempts == 2)
        #expect(saved.coverage < 1)
        #expect(saved.coverageReport?.unknownLemmas == ["manzana"])
        #expect(!saved.isOpened)
        #expect(DailyStoryService.story(context: context, language: .spanish, dayKey: "2026-10-3")?.id == saved.id)
    }

    @Test func ensureTodayStoryBuildsARequestFromTheLearnersWords() async throws {
        let context = try makeContext()
        context.insert(word("es-1", "playa", rank: 1, decks: ["common", "traveling"]))
        context.insert(word("es-2", "pez", rank: 2, decks: ["common", "animals"]))
        context.insert(LearningProgress(wordID: "es-2", state: .learning, lapses: 1, lastReviewedAt: .now))
        let now = Date.now
        let story = try await DailyStoryService.ensureTodayStory(context: context, language: .spanish, now: now, brains: [MockStoryBrain()], quota: .unlimited)
        #expect(story.dayKey == DailySetConfig.dayKey(now))
        #expect(story.brainRaw == "mock")
        #expect(story.newWords == ["pez"])
        #expect(story.text.contains("«pez»"))
        let again = try await DailyStoryService.ensureTodayStory(context: context, language: .spanish, now: now, brains: [], quota: .unlimited)
        #expect(again.id == story.id)
    }

    @Test func concurrentRequestsForDifferentStoresStayApart() async throws {
        let first = try makeContext()
        let second = try makeContext()
        async let a = DailyStoryService.generateAndSave(
            request: request, dayKey: "shared-day", context: first, brains: [ScriptedStoryBrain("claude", drafts: [passing])], quota: .unlimited)
        async let b = DailyStoryService.generateAndSave(
            request: request, dayKey: "shared-day", context: second, brains: [ScriptedStoryBrain("apple", drafts: [passing])], quota: .unlimited)
        let (storyA, storyB) = try await (a, b)
        #expect(storyA.id != storyB.id)
        #expect(DailyStoryService.story(context: first, id: storyA.id) != nil)
        #expect(DailyStoryService.story(context: second, id: storyB.id) != nil)
    }

    @Test func secondRequestForTheSameDayReturnsTheSavedStory() async throws {
        let context = try makeContext()
        let first = try await DailyStoryService.generateAndSave(
            request: request, dayKey: "2026-10-3", context: context, brains: [ScriptedStoryBrain("claude", drafts: [passing])], quota: .unlimited)
        let brain = ScriptedStoryBrain("claude", drafts: [passing])
        let second = try await DailyStoryService.generateAndSave(request: request, dayKey: "2026-10-3", context: context, brains: [brain], quota: .unlimited)
        #expect(second.id == first.id)
        #expect(DailyStoryService.history(context: context, language: .spanish).count == 1)
    }

    @Test func previousEpisodeComesFromAnEarlierDay() async throws {
        let context = try makeContext()
        _ = try await DailyStoryService.generateAndSave(
            request: request, dayKey: "2026-10-2", context: context,
            brains: [ScriptedStoryBrain("claude", drafts: [passing])], quota: .unlimited, now: Date(timeIntervalSince1970: 1_000))
        #expect(DailyStoryService.previousEpisodeSummary(context: context, language: .spanish, before: "2026-10-3") == "Dr Tusk come un pez en la playa.")
        #expect(DailyStoryService.previousEpisodeSummary(context: context, language: .spanish, before: "2026-10-2") == nil)
        #expect(DailyStoryService.previousEpisodeSummary(context: context, language: .french, before: "2026-10-3") == nil)
    }

    @Test func historyIsPrunedToTheLimit() async throws {
        let context = try makeContext()
        for day in 1...(DailyStoryService.historyLimit + 3) {
            _ = try await DailyStoryService.generateAndSave(
                request: request, dayKey: "day-\(day)", context: context,
                brains: [ScriptedStoryBrain("claude", drafts: [passing])], quota: .unlimited,
                now: Date(timeIntervalSince1970: TimeInterval(day) * 86_400))
        }
        let history = DailyStoryService.history(context: context, language: .spanish)
        #expect(history.count == DailyStoryService.historyLimit)
        #expect(history.first?.dayKey == "day-\(DailyStoryService.historyLimit + 3)")
    }

    @Test func quotaBlocksGenerationBeforeAnyBrainIsCalled() async throws {
        let context = try makeContext()
        let now = Date(timeIntervalSince1970: 10 * 86_400)
        _ = try await DailyStoryService.generateAndSave(
            request: request, dayKey: "day-9", context: context,
            brains: [ScriptedStoryBrain("claude", drafts: [passing])], quota: .perWeek(1), now: now.addingTimeInterval(-86_400)
        )
        let brain = ScriptedStoryBrain("claude", drafts: [passing])
        await #expect(throws: StoryGenerationError.quotaReached) {
            try await DailyStoryService.generateAndSave(
                request: request, dayKey: "day-10", context: context, brains: [brain], quota: .perWeek(1), now: now
            )
        }
        #expect(brain.generateCalls == 0)
    }

    @Test func storiesArePro() {
        #expect(StoryQuota.forUser(isPro: true) == .unlimited)
        #expect(StoryQuota.forUser(isPro: false) == .perWeek(StoryQuota.freeStoriesPerWeek))
        #expect(!StoryQuota.forUser(isPro: false).allowsAnother(generatedInLastWeek: 0))
    }

    @Test func freeUsersNeverReachABrain() async throws {
        let context = try makeContext()
        let brain = ScriptedStoryBrain("claude", drafts: [passing])
        await #expect(throws: StoryGenerationError.quotaReached) {
            try await DailyStoryService.generateAndSave(
                request: request, dayKey: "day-1", context: context, brains: [brain],
                quota: StoryQuota.forUser(isPro: false)
            )
        }
        #expect(brain.generateCalls == 0)
    }
}
