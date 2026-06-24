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
        publish(snapshot(for: word, progress: progress, now: now))
    }

    /// Publish today's ordered word list (the card stack) so the widget can
    /// rotate through it over the day. `words[0]` is the current front card.
    /// Passing an empty list clears the set and falls back to the single
    /// snapshot. No-op (no widget reload) when the word IDs are unchanged.
    @MainActor
    static func publishSet(
        _ words: [VocabularyWord],
        progressByID: [String: LearningProgress],
        now: Date = .now
    ) {
        guard !words.isEmpty else {
            if DailyWordSet.load() != nil {
                DailyWordSet.clear()
                reloadWidgets()
            }
            return
        }

        let snapshots = words.map { snapshot(for: $0, progress: progressByID[$0.id], now: now) }
        let existing = DailyWordSet.load()
        let unchanged = existing?.words.map(\.wordID) == snapshots.map(\.wordID)

        DailyWordSet(words: snapshots, computedAt: now).save()
        // Keep the single snapshot + notification aligned with the front card.
        if let front = snapshots.first {
            front.save()
            NotificationService.scheduleDailyReminder(using: front)
        }
        if !unchanged { reloadWidgets() }
    }

    private static func snapshot(
        for word: VocabularyWord,
        progress: LearningProgress?,
        now: Date
    ) -> DailyWordSnapshot {
        DailyWordSnapshot(
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

    private static func publish(_ snapshot: DailyWordSnapshot) {
        let existing = DailyWordSnapshot.load()
        if existing?.wordID == snapshot.wordID { return }
        snapshot.save()
        reloadWidgets()
        NotificationService.scheduleDailyReminder(using: snapshot)
    }

    private static func reloadWidgets() {
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadAllTimelines()
        #endif
    }

    @MainActor
    private static func makeSnapshot(context: ModelContext, now: Date) -> DailyWordSnapshot? {
        guard let pick = pickWord(context: context, now: now) else { return nil }
        return snapshot(for: pick.0, progress: pick.1, now: now)
    }

    @MainActor
    private static func pickWord(context: ModelContext, now: Date) -> (VocabularyWord, LearningProgress?)? {
        let fetched = (try? context.fetch(
            FetchDescriptor<VocabularyWord>(sortBy: [SortDescriptor(\.rank)])
        )) ?? []
        // Scope to the active language — custom words from other languages
        // persist in the store across switches and must not surface here.
        let languageCode = (OnboardingStore.targetLanguage ?? .spanish).languageCode
        let allWords = fetched.scoped(to: languageCode)
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
        return words.filter { slug == DeckConstants.allSlug || $0.deckSlugs.contains(slug) }
    }
}
