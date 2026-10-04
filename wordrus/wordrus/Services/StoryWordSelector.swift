import Foundation
import SwiftData

/// Picks the words a daily story is built from.
///
/// - Known words (what the story may use): every learning word first, most
///   recently reviewed first, then words the learner knows — today's topic
///   first, then by corpus frequency. Capped at `knownWordCap` so the prompt
///   stays small.
/// - New words (what the story teaches, 2–3): shaky words from today's card
///   stack first, then other words the learner keeps missing, then unseen
///   words from today's topic.
/// - Topic: the theme of today's card stack.
///
/// A "learning word" uses the card stack's definition (`JamView.learningWords`):
/// it has lapses or is in the learning/review state.
///
/// Beginners know too few words to write anything with, so the known list is
/// topped up to `coreVocabularyFloor` with the most frequent seed words at or
/// below the learner's level — the words they meet first.
@MainActor
enum StoryWordSelector {
    static let knownWordCap = 400
    static let coreVocabularyFloor = 250
    static let newWordCount = 3
    static let fallbackTopic = "Everyday life"

    struct Selection: Equatable {
        var knownWords: [StoryWord]
        var newWords: [StoryWord]
        var topic: String
    }

    static func selection(context: ModelContext, language: TargetLanguage, now: Date = .now) -> Selection {
        let words = ((try? context.fetch(FetchDescriptor<VocabularyWord>())) ?? []).scoped(to: language.languageCode)
        let progress = (try? context.fetch(FetchDescriptor<LearningProgress>())) ?? []
        let decks = (try? context.fetch(FetchDescriptor<Deck>())) ?? []
        return select(
            words: words,
            progressByID: Dictionary(progress.map { ($0.wordID, $0) }) { first, _ in first },
            knownIDs: DailyWordService.knownWordIDs(context: context, now: now),
            frequencyRanks: StoryLexicon.load(for: language)?.frequencyRanks() ?? [:],
            decks: decks,
            level: OnboardingStore.cefrLevel,
            todaysSetIDs: DailyWordSet.load()?.words.map(\.wordID) ?? [],
            recentNewLemmas: Set(
                DailyStoryService.history(context: context, language: language)
                    .prefix(recentNewWordWindow)
                    .flatMap(\.newWords)
            )
        )
    }

    /// Stories whose new words aren't taught again while others are available.
    static let recentNewWordWindow = 5

    static func select(
        words: [VocabularyWord],
        progressByID: [String: LearningProgress],
        knownIDs: Set<String>,
        frequencyRanks: [String: Int],
        decks: [Deck],
        level: CEFRLevel,
        todaysSetIDs: [String],
        recentNewLemmas: Set<String> = []
    ) -> Selection {
        let byID = Dictionary(words.map { ($0.id, $0) }) { first, _ in first }
        let todaysSet = todaysSetIDs.compactMap { byID[$0] }

        func isLearning(_ word: VocabularyWord) -> Bool {
            guard let p = progressByID[word.id] else { return false }
            return p.lapses > 0 || p.state == .learning || p.state == .review
        }
        func lastReviewed(_ word: VocabularyWord) -> Date {
            progressByID[word.id]?.lastReviewedAt ?? .distantPast
        }
        func frequencyRank(_ word: VocabularyWord) -> Int {
            // Custom and unranked words sort after every ranked seed word.
            frequencyRanks[word.lemma] ?? (100_000 + word.rank)
        }

        // Topic: the dominant visible deck of today's stack (themed sets are
        // drawn from a single deck), else of the learning words.
        let learning = words.filter(isLearning).sorted { lastReviewed($0) > lastReviewed($1) }
        let topicSlug = dominantDeck(in: todaysSet) ?? dominantDeck(in: learning)
        let topic = topicSlug.flatMap { slug in decks.first { $0.slug == slug }?.displayName } ?? fallbackTopic

        // New words: shaky words from today's stack, then other lapsed words,
        // then unseen words from the topic deck (level-anchored, by rank).
        // Words a recent story already taught are skipped while anything
        // else qualifies — otherwise a day without a new Deck set would get
        // yesterday's new words (and so yesterday's story) again.
        var newWords: [VocabularyWord] = []
        let lapses = { (word: VocabularyWord) in progressByID[word.id]?.lapses ?? 0 }
        var candidateLists: [[VocabularyWord]] = [
            todaysSet.filter { isLearning($0) && !knownIDs.contains($0.id) }.sorted { lapses($0) > lapses($1) },
            learning.filter { lapses($0) > 0 && !knownIDs.contains($0.id) }.sorted { lapses($0) > lapses($1) },
        ]
        if let topicSlug {
            candidateLists.append(LevelAnchor.anchored(
                words.filter { progressByID[$0.id] == nil && $0.deckSlugs.contains(topicSlug) }.sorted { $0.rank < $1.rank },
                to: level
            ))
        }
        candidateLists.append(todaysSet.filter { !knownIDs.contains($0.id) })
        for allowRecent in [false, true] {
            for candidates in candidateLists {
                for word in candidates where newWords.count < newWordCount
                    && !newWords.contains(where: { $0.lemma == word.lemma })
                    && (allowRecent || !recentNewLemmas.contains(word.lemma)) {
                    newWords.append(word)
                }
            }
        }

        // Known words: learning first, then known (topic first, then frequency).
        let newIDs = Set(newWords.map(\.id))
        let newLemmas = Set(newWords.map(\.lemma))
        let learningIDs = Set(learning.map(\.id))
        let known = words
            .filter { knownIDs.contains($0.id) && !learningIDs.contains($0.id) }
            .sorted { lhs, rhs in
                let lhsTopic = topicSlug.map(lhs.deckSlugs.contains) ?? false
                let rhsTopic = topicSlug.map(rhs.deckSlugs.contains) ?? false
                if lhsTopic != rhsTopic { return lhsTopic }
                return frequencyRank(lhs) < frequencyRank(rhs)
            }
        var seenLemmas = newLemmas
        var knownWords: [StoryWord] = []
        for word in learning + known where !newIDs.contains(word.id) && knownWords.count < knownWordCap {
            guard seenLemmas.insert(word.lemma).inserted else { continue }
            knownWords.append(StoryWord(lemma: word.lemma, partOfSpeech: word.partOfSpeech))
        }

        if knownWords.count < coreVocabularyFloor {
            let core = words
                .filter { word in
                    guard !word.id.hasPrefix("custom-"), !newIDs.contains(word.id),
                          let raw = word.cefrLevel, let wordLevel = CEFRLevel(rawValue: raw) else { return false }
                    return wordLevel <= level
                }
                .sorted { frequencyRank($0) < frequencyRank($1) }
            for word in core where knownWords.count < coreVocabularyFloor {
                guard seenLemmas.insert(word.lemma).inserted else { continue }
                knownWords.append(StoryWord(lemma: word.lemma, partOfSpeech: word.partOfSpeech))
            }
        }

        return Selection(
            knownWords: knownWords,
            newWords: newWords.map { StoryWord(lemma: $0.lemma, partOfSpeech: $0.partOfSpeech) },
            topic: topic
        )
    }

    private static func dominantDeck(in words: [VocabularyWord]) -> String? {
        var counts: [String: Int] = [:]
        for word in words {
            for slug in word.deckSlugs where slug != DeckConstants.commonSlug {
                counts[slug, default: 0] += 1
            }
        }
        return counts.max { lhs, rhs in lhs.value == rhs.value ? lhs.key > rhs.key : lhs.value < rhs.value }?.key
    }
}
