import Foundation
import SwiftData
#if canImport(WidgetKit)
import WidgetKit
#endif

enum DailyWordService {
    @MainActor
    static func refresh(context: ModelContext, now: Date = .now) {
        guard let snapshot = makeSnapshot(context: context, now: now) else { return }
        publish(snapshot)
    }

    @MainActor
    static func setActiveWord(_ word: VocabularyWord, progress: LearningProgress?, now: Date = .now) {
        let snapshot = DailyWordSnapshot(
            wordID: word.id,
            lemma: word.lemma,
            partOfSpeech: word.partOfSpeech,
            definition: LocaleService.definition(for: word),
            exampleSentence: word.exampleSentence,
            exampleTranslation: LocaleService.exampleTranslation(for: word),
            isDueNow: (progress?.dueDate ?? .distantPast) <= now,
            dueDate: progress?.dueDate,
            computedAt: now
        )
        publish(snapshot)
    }

    private static func publish(_ snapshot: DailyWordSnapshot) {
        let existing = DailyWordSnapshot.load()
        if existing?.wordID == snapshot.wordID { return }
        snapshot.save()
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadAllTimelines()
        #endif
        NotificationService.scheduleDailyReminder(using: snapshot)
    }

    @MainActor
    private static func makeSnapshot(context: ModelContext, now: Date) -> DailyWordSnapshot? {
        guard let pick = pickWord(context: context, now: now) else { return nil }
        let (word, progress) = pick

        return DailyWordSnapshot(
            wordID: word.id,
            lemma: word.lemma,
            partOfSpeech: word.partOfSpeech,
            definition: LocaleService.definition(for: word),
            exampleSentence: word.exampleSentence,
            exampleTranslation: LocaleService.exampleTranslation(for: word),
            isDueNow: (progress?.dueDate ?? .distantPast) <= now,
            dueDate: progress?.dueDate,
            computedAt: now
        )
    }

    @MainActor
    private static func pickWord(context: ModelContext, now: Date) -> (VocabularyWord, LearningProgress?)? {
        let allWords = (try? context.fetch(
            FetchDescriptor<VocabularyWord>(sortBy: [SortDescriptor(\.rank)])
        )) ?? []
        let words = filterBySelectedDeck(allWords)
        guard !words.isEmpty else { return nil }

        let allProgress = (try? context.fetch(FetchDescriptor<LearningProgress>())) ?? []
        let progressByID = Dictionary(uniqueKeysWithValues: allProgress.map { ($0.wordID, $0) })

        let dueCandidate = words
            .compactMap { word -> (VocabularyWord, LearningProgress)? in
                guard let progress = progressByID[word.id], progress.dueDate <= now else { return nil }
                return (word, progress)
            }
            .min { $0.1.dueDate < $1.1.dueDate }

        if let dueCandidate { return (dueCandidate.0, dueCandidate.1) }

        if let firstNew = words.first(where: { progressByID[$0.id] == nil }) {
            return (firstNew, nil)
        }

        let upcoming = words
            .compactMap { word -> (VocabularyWord, LearningProgress)? in
                guard let progress = progressByID[word.id], progress.state != .known else { return nil }
                return (word, progress)
            }
            .min { $0.1.dueDate < $1.1.dueDate }

        if let upcoming { return (upcoming.0, upcoming.1) }
        return (words[0], nil)
    }

    private static func filterBySelectedDeck(_ words: [VocabularyWord]) -> [VocabularyWord] {
        let slug = UserDefaults.standard.string(forKey: DeckConstants.selectedDeckDefaultsKey) ?? DeckConstants.allSlug
        let level = UserDefaults.standard.string(forKey: DeckConstants.selectedCEFRLevelDefaultsKey) ?? DeckConstants.allLevelsValue
        let deckFiltered = words.filter { slug == DeckConstants.allSlug || $0.deckSlugs.contains(slug) }
        guard level != DeckConstants.allLevelsValue else { return deckFiltered }
        let levelFiltered = deckFiltered.filter { $0.cefrLevel == level }
        // Sparse languages (FR/DE/IT) have no words above A2; if the selected
        // level matches nothing, fall back to the deck pool rather than leaving
        // the daily word / widget blank.
        return levelFiltered.isEmpty ? deckFiltered : levelFiltered
    }
}
