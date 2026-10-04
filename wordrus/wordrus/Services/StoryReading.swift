import Foundation
import SwiftData

/// What the story screen knows about a story's text: every word with its
/// lemma candidates (for tap-to-translate and new-word highlighting), the
/// sentences (for narration highlighting), and which vocabulary entry a
/// tapped word belongs to.
///
/// Built with the whole language vocabulary as "known" so any seed word can
/// be resolved from an inflected form (despierta → despertar).
@MainActor
struct StoryReading {
    typealias Token = StoryVocabularyChecker.AnnotatedToken

    let tokens: [Token]
    let sentences: [Range<String.Index>]
    let languageCode: String
    private let wordsByKey: [String: VocabularyWord]

    static func make(story: DailyStory, context: ModelContext) async -> StoryReading? {
        guard let language = story.language,
              let lexicon = StoryLexicon.load(for: language) else { return nil }
        let code = language.languageCode
        let words = ((try? context.fetch(FetchDescriptor<VocabularyWord>(sortBy: [SortDescriptor(\.rank)]))) ?? [])
            .scoped(to: code)
        let known = words.map { StoryWord(lemma: $0.lemma, partOfSpeech: $0.partOfSpeech) }
        let highlighted = story.highlightedWords.map { StoryWord(lemma: $0) }
        let text = story.text

        // Indexing ~6.5K words takes a moment — keep it off the main thread.
        let (tokens, sentences) = await Task.detached(priority: .userInitiated) {
            let checker = StoryVocabularyChecker(
                lexicon: lexicon, known: known, new: highlighted, policy: .init(wordCount: 0...Int.max)
            )
            return (checker.annotate(text), StoryNarrationTiming.sentenceRanges(in: text, languageCode: code))
        }.value

        var wordsByKey: [String: VocabularyWord] = [:]
        for word in words {
            for key in StoryVocabularyChecker.variantKeys(of: word.lemma, languageCode: code, functionKeys: [])
            where wordsByKey[key] == nil {
                wordsByKey[key] = word
            }
        }
        return StoryReading(tokens: tokens, sentences: sentences, languageCode: code, wordsByKey: wordsByKey)
    }

    /// The vocabulary entry a word in the story is a form of, if any.
    func word(for token: Token) -> VocabularyWord? {
        token.lookupKeys(languageCode: languageCode).lazy.compactMap { wordsByKey[$0] }.first
    }

    /// Vocabulary entries for lemmas (the story's new words), in order.
    func words(forLemmas lemmas: [String]) -> [VocabularyWord] {
        lemmas.compactMap { wordsByKey[StoryVocabularyChecker.fold($0, languageCode: languageCode)] }
    }

    func sentenceIndex(of token: Token) -> Int? {
        sentences.firstIndex { $0.contains(token.range.lowerBound) }
    }
}

nonisolated enum StoryComprehension {
    /// Share of the story's content words the learner understood.
    ///
    /// - Words the vocabulary check couldn't place (`unknownKeys`) count as
    ///   not understood, and so do words the learner had to look up.
    /// - New words count as understood: they're what the story teaches, and
    ///   looking them up is the point.
    /// - Function words, names and numbers don't count either way.
    static func understood(
        tokens: [StoryVocabularyChecker.AnnotatedToken],
        unknownKeys: Set<String>,
        lookedUpKeys: Set<String>
    ) -> Double {
        let content = tokens.filter { $0.role == .known || $0.role == .unknown }
        guard !content.isEmpty else { return 1 }
        let missed = content.filter { token in
            guard token.newWord == nil else { return false }
            return token.role == .unknown || !token.keys.isDisjoint(with: unknownKeys) || !token.keys.isDisjoint(with: lookedUpKeys)
        }
        return Double(content.count - missed.count) / Double(content.count)
    }
}
