import Foundation
import SwiftData
import Testing
@testable import wordrus

@MainActor
struct StoryReadingTests {
    // MARK: Narration timing

    @Test func progressAdvancesClipByClip() {
        // Title + 3 sentences = 4 clips.
        #expect(StoryNarrationTiming.progress(clip: 0, fraction: 0, clipCount: 4) == 0)
        #expect(StoryNarrationTiming.progress(clip: 1, fraction: 0.5, clipCount: 4) == 0.375)
        #expect(StoryNarrationTiming.progress(clip: 4, fraction: 0, clipCount: 4) == 1)
        #expect(StoryNarrationTiming.progress(clip: 3, fraction: 2, clipCount: 4) == 1)
        #expect(StoryNarrationTiming.progress(clip: 0, fraction: 0.5, clipCount: 0) == 0)
    }

    @Test func sentencesArePausedBetween() {
        #expect(StoryNarrationTiming.sentencePause >= .milliseconds(500))
        #expect(StoryNarrationTiming.titlePause >= StoryNarrationTiming.sentencePause)
    }

    @Test func sentenceRangesSplitTheStory() {
        let text = "Dr Tusk va a la playa. ¡Hay un pez! ¿Y ahora?"
        let ranges = StoryNarrationTiming.sentenceRanges(in: text, languageCode: "es")
        #expect(ranges.count == 3)
        #expect(text[ranges[1]].hasPrefix("¡Hay un pez!"))
    }

    // MARK: Annotation

    private func checker(_ code: String, known: [StoryWord], new: [StoryWord] = []) throws -> StoryVocabularyChecker {
        let lexicon = try #require(StoryLexicon.load(languageCode: code))
        return StoryVocabularyChecker(lexicon: lexicon, known: known, new: new, policy: .init(wordCount: 0...1000))
    }

    @Test func annotatedRangesPointIntoTheOriginalTextEvenWithCurlyApostrophes() throws {
        let text = "L’homme va à la plage. Dr Tusk rit."
        let tokens = try checker("fr", known: ["homme", "aller", "plage", "rire"]).annotate(text)
        // Ranges cover the original characters; `surface` is the
        // apostrophe-normalised form the checker works with.
        for token in tokens {
            #expect(String(text[token.range]).replacingOccurrences(of: "’", with: "'") == token.surface)
        }
        #expect(tokens.first.map { String(text[$0.range]) } == "L’")
        let roles = Dictionary(tokens.map { ($0.surface, $0.role) }, uniquingKeysWith: { first, _ in first })
        #expect(roles["homme"] == .known)
        #expect(roles["Tusk"] == .name)
        #expect(roles["la"] == .function)
    }

    @Test func inflectedFormsOfNewWordsAreMarked() throws {
        let tokens = try checker("es", known: ["ir"], new: ["playa", "salir"]).annotate("Las playas son bonitas. El pez sale del agua.")
        let marked = tokens.filter { $0.newWord != nil }.map(\.surface)
        #expect(marked == ["playas", "sale"])
        #expect(tokens.first { $0.surface == "playas" }?.newWord == "playa")
    }

    @Test func trailingPunctuationIsNotPartOfTheToken() throws {
        let text = "Dr Tusk come pescado."
        let tokens = try checker("es", known: ["comer", "pescado"]).annotate(text)
        let last = try #require(tokens.last)
        #expect(last.surface == "pescado")
        #expect(text[last.range] == "pescado")
    }

    // MARK: Comprehension

    private func token(_ surface: String, _ role: StoryVocabularyChecker.AnnotatedToken.Role, keys: Set<String>, newWord: String? = nil) -> StoryVocabularyChecker.AnnotatedToken {
        StoryVocabularyChecker.AnnotatedToken(
            range: surface.startIndex..<surface.endIndex, surface: surface, role: role, keys: keys, lemma: nil, newWord: newWord
        )
    }

    @Test func understoodCountsKnownWordsThatWerentLookedUp() {
        let tokens = [
            token("perro", .known, keys: ["perro"]),
            token("come", .known, keys: ["come", "comer"]),
            token("playa", .known, keys: ["playa"], newWord: "playa"),
            token("botella", .known, keys: ["botella"]),
            token("roca", .unknown, keys: ["roca"]),
            token("el", .function, keys: ["el"]),
            token("Tusk", .name, keys: ["tusk"]),
        ]
        // 5 content words: roca never placed, botella flagged unknown by the
        // check, comer looked up → perro + playa (taught) understood.
        let understood = StoryComprehension.understood(tokens: tokens, unknownKeys: ["botella"], lookedUpKeys: ["comer", "playa"])
        #expect(abs(understood - 2.0 / 5.0) < 1e-9)
        #expect(StoryComprehension.understood(tokens: [token("el", .function, keys: ["el"])], unknownKeys: [], lookedUpKeys: []) == 1)
    }

    // MARK: Word stack & lookup

    private func makeContext() throws -> ModelContext {
        let schema = Schema([VocabularyWord.self, LearningProgress.self, ReviewLog.self, Deck.self, ChatSession.self, ChatMessage.self, DailyStory.self])
        return ModelContext(try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)))
    }

    private func seedWord(_ id: String, _ lemma: String, pos: String) -> VocabularyWord {
        VocabularyWord(id: id, rank: 1, lemma: lemma, partOfSpeech: pos, definitionsJSON: #"{"en":"x"}"#,
                       exampleSentence: "", exampleTranslationsJSON: "{}")
    }

    @Test func addingAWordPutsItInLearningAndKnownWordsCanComeBack() throws {
        let context = try makeContext()
        let word = seedWord("es-9001", "botella", pos: "noun")
        context.insert(word)
        #expect(WordStack.status(of: word, context: context) == .notInStack)

        WordStack.add(word, context: context)
        #expect(WordStack.status(of: word, context: context) == .learning)

        let known = seedWord("es-9002", "perro", pos: "noun")
        context.insert(known)
        context.insert(LearningProgress(wordID: known.id, state: .known, dueDate: .distantFuture))
        #expect(WordStack.status(of: known, context: context) == .known)
        WordStack.add(known, context: context)
        #expect(WordStack.status(of: known, context: context) == .learning)
    }

    @Test func storyWordsResolveToTheirVocabularyEntries() async throws {
        let context = try makeContext()
        for (index, entry) in [("despertarse", "verb"), ("salir", "verb"), ("pez", "noun"), ("playa", "noun")].enumerated() {
            context.insert(seedWord("es-80\(index)", entry.0, pos: entry.1))
        }
        let story = DailyStory(
            dayKey: "d", language: .spanish, level: .a1, topic: "Animals",
            story: GeneratedStory(title: "T", story: "Dr Tusk se despierta. Un pez sale de la playa.", newWordSentences: [], questions: [], episodeSummary: ""),
            newWords: ["salir"], extraWords: [],
            report: StoryCoverageReport(coverage: 1, contentTokenCount: 0, unknownTokenCount: 0, unknownLemmas: [], newWordUses: [:], wordCount: 0, failures: []),
            brain: "mock", attempts: 1
        )
        context.insert(story)
        let reading = try #require(await StoryReading.make(story: story, context: context))
        func lemma(for surface: String) -> String? {
            reading.tokens.first { $0.surface == surface }.flatMap { reading.word(for: $0)?.lemma }
        }
        #expect(lemma(for: "despierta") == "despertarse")
        #expect(lemma(for: "sale") == "salir")
        #expect(lemma(for: "pez") == "pez")
        #expect(reading.words(forLemmas: ["salir"]).map(\.id) == ["es-801"])
        #expect(reading.sentences.count == 2)
    }

    // MARK: Retell

    @Test func retellSeedReachesTheCloudBrain() throws {
        let brain = try #require(WalrusBrainFactory.makeCurrent(storyContext: "Retell the story.") as? ClaudeWalrusBrain)
        #expect(brain.storyContext == "Retell the story.")
        let plain = try #require(WalrusBrainFactory.makeCurrent() as? ClaudeWalrusBrain)
        #expect(plain.storyContext == nil)
    }

    @Test func retellContextNamesTheStoryAndItsWords() {
        let story = DailyStory(
            dayKey: "d", language: .spanish, level: .a1, topic: "Animals",
            story: GeneratedStory(title: "La nota", story: "…", newWordSentences: [], questions: [], episodeSummary: "Dr Tusk encontró una nota."),
            newWords: ["llegar", "salir"], extraWords: ["roca"],
            report: StoryCoverageReport(coverage: 1, contentTokenCount: 0, unknownTokenCount: 0, unknownLemmas: [], newWordUses: [:], wordCount: 0, failures: []),
            brain: "mock", attempts: 1
        )
        let context = StoryRetell.context(for: story)
        #expect(context.contains("\"La nota\""))
        #expect(context.contains("Dr Tusk encontró una nota."))
        #expect(context.contains("llegar, salir, roca"))
    }
}
