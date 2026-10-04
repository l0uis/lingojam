import Foundation
import SwiftData
#if canImport(WidgetKit)
import WidgetKit
#endif

enum DailyWordService {
    @MainActor
    static func refresh(context: ModelContext, now: Date = .now) {
        let pruned = pruneKnownFromSet(context: context, now: now)
        guard let snapshot = makeSnapshot(context: context, now: now) else {
            // Nothing left to learn or review — never leave a stale (possibly
            // already-known) word on the widget. Drop the single snapshot so
            // the widget falls back to its empty state instead. The daily-set
            // stack, when present, still drives the widget on its own.
            if DailyWordSet.load() == nil, DailyWordSnapshot.load() != nil {
                DailyWordSnapshot.clear()
                reloadWidgets()
            }
            // Reminders bake the word into their content at schedule time, so
            // pending ones for a word that just became known have to go.
            if pruned { NotificationService.cancelAllReminders() }
            return
        }
        publish(snapshot, force: pruned)
    }

    /// Drop words the user has since marked as known from the published set.
    /// The set is frozen for the day, so a word marked known outside the deck
    /// (the words list, onboarding's "I know these") would otherwise keep
    /// rotating through the widget, the Live Activity and the reminders.
    /// Returns whether anything was removed.
    @MainActor
    @discardableResult
    private static func pruneKnownFromSet(context: ModelContext, now: Date) -> Bool {
        guard let set = DailyWordSet.load(), !set.words.isEmpty else { return false }
        let known = knownWordIDs(context: context, now: now)
        guard !known.isEmpty else { return false }
        let remaining = pruning(set.words, known: known)
        guard remaining.count != set.words.count else { return false }

        if remaining.isEmpty {
            DailyWordSet.clear()
        } else {
            // Keep `computedAt` so the rotation doesn't jump back to the start.
            DailyWordSet(words: remaining, computedAt: set.computedAt).save()
        }
        reloadWidgets()
        LiveActivityService.refresh(now: now)
        return true
    }

    /// Snapshots minus the ones the user has since marked as known. Exposed as
    /// `internal` for unit testing.
    static func pruning(_ words: [DailyWordSnapshot], known: Set<String>) -> [DailyWordSnapshot] {
        words.filter { !known.contains($0.wordID) }
    }

    /// Words that may leave the app — anything not currently sitting in the
    /// user's "Know" list. Exposed as `internal` for unit testing.
    @MainActor
    static func publishable(
        _ words: [VocabularyWord],
        known: Set<String>
    ) -> [VocabularyWord] {
        words.filter { !known.contains($0.id) }
    }

    /// Words the user counts as known, using the same rule as the Know /
    /// Learning tabs (`MyWordsView.bucket`): the most recent swipe wins.
    ///
    /// A word only counts while it isn't due — swiping Know sets an SRS
    /// interval, and when that elapses the word is genuinely up for review
    /// again, so it becomes eligible for the widget and reminders once more.
    /// First-encounter "I know it" retires a word outright (`state == .known`,
    /// distant-future due date), so it never comes back around.
    ///
    /// Exposed as `internal` for unit testing.
    static func knownIDs(
        latestRating: [String: ReviewRating],
        progressByID: [String: LearningProgress],
        now: Date
    ) -> Set<String> {
        var ids = Set(progressByID.values.filter { $0.state == .known }.map(\.wordID))
        for (wordID, rating) in latestRating where rating == .good || rating == .easy {
            // No progress row means nothing schedules the word back in, so
            // treat it as known rather than due.
            if (progressByID[wordID]?.dueDate ?? .distantFuture) > now {
                ids.insert(wordID)
            }
        }
        return ids
    }

    @MainActor
    static func knownWordIDs(context: ModelContext, now: Date = .now) -> Set<String> {
        let logs = (try? context.fetch(
            FetchDescriptor<ReviewLog>(sortBy: [SortDescriptor(\.reviewedAt, order: .reverse)])
        )) ?? []
        var latestRating: [String: ReviewRating] = [:]
        for log in logs where latestRating[log.wordID] == nil {
            latestRating[log.wordID] = log.rating
        }
        let progress = (try? context.fetch(FetchDescriptor<LearningProgress>())) ?? []
        let progressByID = Dictionary(progress.map { ($0.wordID, $0) }) { first, _ in first }
        return knownIDs(latestRating: latestRating, progressByID: progressByID, now: now)
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
        context: ModelContext,
        now: Date = .now
    ) {
        // Words in the user's "Know" list never belong on the widget, the Live
        // Activity or a reminder — even though the in-app stack keeps them,
        // since it backfills with already-seen theme words (and rotates
        // through "My Words") to reach today's target length.
        let known = knownWordIDs(context: context, now: now)
        let unknown = publishable(words, known: known)

        guard !unknown.isEmpty else {
            var needsReload = false
            if DailyWordSet.load() != nil {
                DailyWordSet.clear()
                needsReload = true
            }
            // The single snapshot is the widget's fallback and the reminder
            // stack's last resort — drop it too when it's one of the words
            // that just became known, along with its pending reminders.
            if let fallback = DailyWordSnapshot.load(), known.contains(fallback.wordID) {
                DailyWordSnapshot.clear()
                NotificationService.cancelAllReminders()
                needsReload = true
            }
            if needsReload { reloadWidgets() }
            return
        }

        let snapshots = unknown.map { snapshot(for: $0, progress: progressByID[$0.id], now: now) }
        let existing = DailyWordSet.load()
        let unchanged = existing?.words.map(\.wordID) == snapshots.map(\.wordID)

        DailyWordSet(words: snapshots, computedAt: now).save()
        // Keep the single snapshot + notification aligned with the front card.
        if let front = snapshots.first {
            front.save()
            NotificationService.scheduleDailyReminder(using: front)
        }
        if !unchanged { reloadWidgets() }
        // Re-point a running Live Activity at the new front word (no-op if the
        // user hasn't switched it on / none is running).
        LiveActivityService.refresh(now: now)
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

    /// `force` re-schedules the reminders even when the word is unchanged —
    /// needed after a prune, since the pending notifications were built from
    /// the old stack.
    private static func publish(_ snapshot: DailyWordSnapshot, force: Bool = false) {
        let existing = DailyWordSnapshot.load()
        if !force, existing?.wordID == snapshot.wordID { return }
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
        let known = knownWordIDs(context: context, now: now)

        // Due reviews the user is still learning — never surface a word they've
        // already marked as known (those carry a distant-future due date, but
        // exclude them explicitly so the widget can't ever show a known word).
        let dueCandidate = words
            .compactMap { word -> (VocabularyWord, LearningProgress)? in
                guard let progress = progressByID[word.id],
                      progress.state != .known,
                      progress.dueDate <= now else { return nil }
                return (word, progress)
            }
            .min { $0.1.dueDate < $1.1.dueDate }

        if let dueCandidate { return (dueCandidate.0, dueCandidate.1) }

        let newCandidates = LevelAnchor.anchored(
            words.filter { progressByID[$0.id] == nil },
            to: OnboardingStore.cefrLevel
        )
        if let firstNew = newCandidates.first {
            return (firstNew, nil)
        }

        // Nothing due and nothing new left: fall forward to the soonest word
        // the user is still learning. Words sitting in their "Know" list are
        // excluded — waiting out an SRS interval isn't a reason to put a word
        // they've told us they know back on the widget.
        let upcoming = words
            .compactMap { word -> (VocabularyWord, LearningProgress)? in
                guard let progress = progressByID[word.id], !known.contains(word.id) else { return nil }
                return (word, progress)
            }
            .min { $0.1.dueDate < $1.1.dueDate }

        if let upcoming { return (upcoming.0, upcoming.1) }

        // Everything remaining is already known. Don't fall back to a known
        // word on the widget — show nothing rather than something the user
        // has already mastered.
        return nil
    }

    private static func filterBySelectedDeck(_ words: [VocabularyWord]) -> [VocabularyWord] {
        let slug = UserDefaults.standard.string(forKey: DeckConstants.selectedDeckDefaultsKey) ?? DeckConstants.allSlug
        return words.filter { slug == DeckConstants.allSlug || $0.deckSlugs.contains(slug) }
    }
}
