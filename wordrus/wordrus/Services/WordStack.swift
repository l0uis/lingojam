import Foundation
import SwiftData

/// Putting words into the learner's stack, shared by the Words tab composer
/// and the story screen's word sheet.
@MainActor
enum WordStack {
    enum Status: Equatable {
        case notInStack
        case learning
        case known
    }

    static func status(of word: VocabularyWord, context: ModelContext) -> Status {
        if DailyWordService.knownWordIDs(context: context).contains(word.id) { return .known }
        guard let progress = progress(for: word, context: context), progress.state != .new else { return .notInStack }
        return .learning
    }

    /// Seeds an existing word into Learning, due now — the same state a
    /// freshly added custom word starts in. A known word goes back to
    /// Learning (the learner asked to practise it again).
    static func add(_ word: VocabularyWord, context: ModelContext) {
        if let existing = progress(for: word, context: context) {
            existing.state = .learning
            existing.dueDate = .now
            existing.lastReviewedAt = .now
        } else {
            context.insert(LearningProgress(wordID: word.id, state: .learning, lastReviewedAt: .now))
        }
        try? context.save()
        // A word leaving "Know" must reach the widget, Live Activity and
        // reminders again.
        DailyWordService.refresh(context: context)
    }

    /// Persists an enriched word and seeds it into the Learning tab. The
    /// definition and example translation are stored under the user's
    /// definition locale so `LocaleService` reads them straight back; a fresh
    /// `LearningProgress` in the `.learning` state makes the word show up
    /// immediately at the top of Learning instead of falling into the
    /// unreviewed limbo that `MyWordsView.bucket(for:)` leaves seeded words in.
    @discardableResult
    static func persistCustomWord(
        _ enrichment: WordEnrichmentService.Enrichment,
        language: TargetLanguage,
        context: ModelContext
    ) -> VocabularyWord {
        let localeKey = LocaleService.preferredDefinitionLocale
        let encoder = JSONEncoder()
        func encode(_ map: [String: String]) -> String {
            (try? encoder.encode(map))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        }

        let id = "custom-\(language.languageCode)-\(UUID().uuidString)"
        var highestRank = FetchDescriptor<VocabularyWord>(sortBy: [SortDescriptor(\.rank, order: .reverse)])
        highestRank.fetchLimit = 1
        let nextRank = ((try? context.fetch(highestRank).first?.rank) ?? 1000) + 1

        let word = VocabularyWord(
            id: id,
            rank: nextRank,
            lemma: enrichment.lemma,
            partOfSpeech: enrichment.partOfSpeech,
            definitionsJSON: encode([localeKey: enrichment.definition]),
            exampleSentence: enrichment.exampleSentence,
            exampleTranslationsJSON: enrichment.exampleTranslation.isEmpty
                ? "{}"
                : encode([localeKey: enrichment.exampleTranslation])
        )
        word.setDeckSlugs([DeckConstants.myWordsSlug])
        context.insert(word)

        let p = LearningProgress(wordID: id, state: .learning, lastReviewedAt: .now)
        context.insert(p)
        try? context.save()
        return word
    }

    private static func progress(for word: VocabularyWord, context: ModelContext) -> LearningProgress? {
        let id = word.id
        var descriptor = FetchDescriptor<LearningProgress>(predicate: #Predicate { $0.wordID == id })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }
}
