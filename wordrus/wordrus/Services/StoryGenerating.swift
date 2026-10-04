import Foundation

/// A story as a brain returns it. Field names match the `submit_story` tool
/// schema shared with the proxy and the Apple `@Generable` mirror.
nonisolated struct GeneratedStory: Codable, Equatable, Sendable {
    var title: String
    var story: String
    var newWordSentences: [StoryWordSentence]
    var questions: [StoryQuestion]
    var episodeSummary: String

    enum CodingKeys: String, CodingKey {
        case title, story, questions
        case newWordSentences = "new_word_sentences"
        case episodeSummary = "episode_summary"
    }

    /// Every question and option, flattened for the vocabulary check.
    var questionTexts: [String] {
        questions.flatMap { [$0.question] + $0.options }
    }
}

nonisolated struct StoryWordSentence: Codable, Equatable, Sendable {
    var word: String
    var sentence: String
}

nonisolated struct StoryQuestion: Codable, Equatable, Sendable {
    var question: String
    /// Exactly three options.
    var options: [String]
    var answerIndex: Int

    enum CodingKeys: String, CodingKey {
        case question, options
        case answerIndex = "answer_index"
    }

    var isWellFormed: Bool {
        options.count == 3 && options.indices.contains(answerIndex)
    }
}

/// Everything a brain needs to write today's story.
struct StoryRequest: Equatable {
    var language: TargetLanguage
    /// ISO 639-1 code of the learner's native language ("en").
    var nativeLanguageCode: String
    var level: CEFRLevel
    /// Words the story may use: learning words first, then known words by
    /// frequency rank (capped — see `StoryWordSelector`).
    var knownWords: [StoryWord]
    /// 2–3 new or shaky words the story should teach.
    var newWords: [StoryWord]
    /// Today's theme, in English (a deck name like "Food & Drink").
    var topic: String
    /// Yesterday's `episodeSummary`, so the series continues. nil for episode one.
    var previousEpisodeSummary: String?

    var length: StoryLength { StoryLength.for(level) }
}

/// Target story length per level. Feeds both the prompt and the checker policy.
struct StoryLength: Equatable {
    let words: ClosedRange<Int>
    let maxSentenceWords: Int

    static func `for`(_ level: CEFRLevel) -> StoryLength {
        switch level {
        case .a1: StoryLength(words: 70...120, maxSentenceWords: 8)
        case .a2: StoryLength(words: 90...150, maxSentenceWords: 10)
        case .b1: StoryLength(words: 120...190, maxSentenceWords: 14)
        case .b2: StoryLength(words: 150...230, maxSentenceWords: 18)
        case .c1: StoryLength(words: 180...280, maxSentenceWords: 22)
        case .c2: StoryLength(words: 200...320, maxSentenceWords: 25)
        }
    }
}

enum StoryGenerationError: Error, Equatable {
    /// The brain couldn't produce anything (network, model unavailable, bad output).
    case unavailable
    /// Every brain was tried and no story passed or was close enough to accept.
    case noAcceptableStory
    /// The learner has used up their stories for the week (`StoryQuota`).
    case quotaReached
}

/// Pluggable story writer — the story counterpart of `WalrusBrain`. Brains
/// only generate; `StoryPipeline` runs the vocabulary check and decides
/// whether to repair, retry, or fall back to the next brain.
@MainActor
protocol StoryGenerating {
    /// Short identifier stored with the story and sent with analytics
    /// ("claude", "apple", "mock").
    var brainName: String { get }

    /// A last-resort brain's story is accepted even when it fails the check
    /// (it can't do better on a retry). Only the mock is one.
    var isLastResort: Bool { get }

    func generateStory(_ request: StoryRequest) async throws -> GeneratedStory

    /// Same plot, with `unknownLemmas` replaced and `missingNewWords` used
    /// (at least twice each).
    func repairStory(
        _ story: GeneratedStory,
        request: StoryRequest,
        unknownLemmas: [String],
        missingNewWords: [String]
    ) async throws -> GeneratedStory
}

extension StoryGenerating {
    var isLastResort: Bool { false }
}

@MainActor
enum StoryBrainFactory {
    /// Brains in the order `StoryPipeline` tries them — the same preference
    /// as `WalrusBrainFactory`: Claude, then Apple Foundation Models.
    ///
    /// The mock is DEBUG-only here: a canned story that ignores the learner's
    /// vocabulary is fine for the simulator and previews, but in a release
    /// build no story beats a nonsense one. The story is generated on demand
    /// again when the learner opens it.
    static func makeChain() -> [StoryGenerating] {
        var chain: [StoryGenerating] = []
        if FeatureFlags.useRealWalrus {
            chain.append(ClaudeStoryBrain())
        }
        if #available(iOS 26.0, macOS 26.0, *), AppleStoryBrain.isAvailable {
            chain.append(AppleStoryBrain())
        }
        #if DEBUG
        chain.append(MockStoryBrain())
        #endif
        return chain
    }
}
