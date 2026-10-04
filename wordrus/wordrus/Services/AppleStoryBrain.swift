import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// The story prompt, shared by the on-device brain. The Claude brain's copy
/// lives in the worker (`storySystemPrompt` in tools/walrus-proxy); keep the
/// two saying the same thing.
enum StoryPrompt {
    static func instructions(for request: StoryRequest, knownWordLimit: Int) -> String {
        let native = Locale(identifier: "en").localizedString(forLanguageCode: request.nativeLanguageCode) ?? "English"
        let previous = request.previousEpisodeSummary?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".!?"))
        let length = request.length
        return """
        You are writing a short daily story for a language learner in the app Wordrus.
        The narrator is Dr Tusk the walrus: curious, a bit clumsy, warm and funny. He tells the story himself, in the first person.
        Language: \(request.language.englishName). Learner's native language: \(native). Level: \(request.level.rawValue).

        STRICT VOCABULARY RULES
        - Use ONLY words from ALLOWED_WORDS, in any grammatical form.
        - You may also use articles, pronouns, prepositions, conjunctions, numbers, names.
        - Use EVERY word in NEW_WORDS at least twice, in context that hints at its meaning.
        - If you need a word that isn't allowed, rephrase. Never add other words.

        STYLE
        - \(length.words.lowerBound)-\(length.words.upperBound) words, sentences max \(length.maxSentenceWords) words, simple tenses for \(request.level.rawValue).
        - One small funny moment, end with a light cliffhanger.
        - Topic: \(request.topic).
        \(series(request, previous: previous))

        ALLOWED_WORDS: \(request.knownWords.prefix(knownWordLimit).map(\.lemma).joined(separator: ", "))
        NEW_WORDS: \(request.newWords.map(\.lemma).joined(separator: ", "))
        Questions must be in \(request.language.englishName) and use only allowed words.
        """
    }

    /// Mirrors the worker's `continuitySection`: the story so far is already
    /// told, so today's episode must move on rather than retell it.
    private static func series(_ request: StoryRequest, previous: String?) -> String {
        guard let previous, !previous.isEmpty else {
            return "SERIES\n- This is the first episode of an ongoing series: introduce Dr Tusk and start a small adventure."
        }
        let titles = request.recentTitles.isEmpty
            ? ""
            : "\n- Recent titles (give today's a different one): " + request.recentTitles.map { "\"\($0)\"" }.joined(separator: ", ") + "."
        return """
        SERIES
        - This is episode \(request.episodeNumber) of an ongoing series. The story so far (already told — do NOT retell it): \(previous).
        - Start where that left off: resolve the cliffhanger in the first sentence or two, then something NEW happens — a new place, problem or discovery.
        - Never repeat earlier events, openings or jokes.\(titles)
        """
    }

    static func repair(unknownLemmas: [String], missingNewWords: [String]) -> String {
        let unknown = unknownLemmas.isEmpty
            ? "Your story breaks the rules."
            : "Your story uses words that are not allowed: \(unknownLemmas.joined(separator: ", "))."
        let missing = missingNewWords.isEmpty
            ? ""
            : " You also need to use each of these new words at least twice: \(missingNewWords.joined(separator: ", "))."
        return """
        \(unknown)\(missing)
        Rewrite it with the same plot, replacing only those words or rephrasing those sentences.
        Same format.
        """
    }
}

/// Writes stories on device with Apple Foundation Models — the fallback when
/// the proxy is unreachable. Its vocabulary control is weaker than Claude's
/// (and its context far smaller, hence the shorter word list); the pipeline's
/// check-and-repair loop makes up for it.
@available(iOS 26.0, macOS 26.0, *)
struct AppleStoryBrain: StoryGenerating {
    let brainName = "apple"

    /// The on-device context is ~4K tokens, shared by prompt and story.
    static let knownWordLimit = 150

    static var isAvailable: Bool { AppleWalrusBrain.isAvailable }

    func generateStory(_ request: StoryRequest) async throws -> GeneratedStory {
        #if canImport(FoundationModels)
        let session = LanguageModelSession(instructions: StoryPrompt.instructions(for: request, knownWordLimit: Self.knownWordLimit))
        let response = try await session.respond(to: Prompt("Write today's episode."), generating: GenerableStory.self)
        return response.content.story
        #else
        throw StoryGenerationError.unavailable
        #endif
    }

    func repairStory(
        _ story: GeneratedStory,
        request: StoryRequest,
        unknownLemmas: [String],
        missingNewWords: [String]
    ) async throws -> GeneratedStory {
        #if canImport(FoundationModels)
        let session = LanguageModelSession(instructions: StoryPrompt.instructions(for: request, knownWordLimit: Self.knownWordLimit))
        let draft = "Your previous story:\n\(story.title)\n\n\(story.story)\n\n"
        let response = try await session.respond(
            to: Prompt(draft + StoryPrompt.repair(unknownLemmas: unknownLemmas, missingNewWords: missingNewWords)),
            generating: GenerableStory.self
        )
        return response.content.story
        #else
        throw StoryGenerationError.unavailable
        #endif
    }
}

#if canImport(FoundationModels)
/// On-device mirror of the `submit_story` schema.
@available(iOS 26.0, macOS 26.0, *)
@Generable
struct GenerableStory {
    @Guide(description: "A short, fun title in the story language, using only allowed words.")
    var title: String
    @Guide(description: "The story text in the story language. Plain prose.")
    var text: String
    @Guide(description: "For each new word, one sentence copied from the story that uses it.")
    var newWordSentences: [GenerableWordSentence]
    @Guide(description: "Multiple-choice comprehension questions in the story language.", .count(1...2))
    var questions: [GenerableQuestion]
    @Guide(description: "One or two sentences in English summing up what happened, for tomorrow's episode.")
    var episodeSummary: String

    var story: GeneratedStory {
        GeneratedStory(
            title: title,
            story: text,
            newWordSentences: newWordSentences.map { StoryWordSentence(word: $0.word, sentence: $0.sentence) },
            questions: questions.map { StoryQuestion(question: $0.question, options: $0.options, answerIndex: $0.answerIndex) },
            episodeSummary: episodeSummary
        )
    }
}

@available(iOS 26.0, macOS 26.0, *)
@Generable
struct GenerableWordSentence {
    var word: String
    var sentence: String
}

@available(iOS 26.0, macOS 26.0, *)
@Generable
struct GenerableQuestion {
    var question: String
    @Guide(description: "Exactly three answer options.", .count(3))
    var options: [String]
    @Guide(description: "Index of the correct option.", .range(0...2))
    var answerIndex: Int
}
#endif
