import SwiftUI
import SwiftData
#if canImport(UIKit)
import UIKit
#endif

enum DailySetConfig {
    static let defaultsKey = "dailySet.target"
    static let minSize = 5
    static let maxSize = 20
    static let defaultSize = 8

    static func clamp(_ value: Int) -> Int {
        min(maxSize, max(minSize, value))
    }
}

struct JamView: View {
    @Environment(\.modelContext) private var context
    @Query private var allProgress: [LearningProgress]
    @Query(sort: \VocabularyWord.rank) private var allWords: [VocabularyWord]
    @Query(sort: \Deck.sortOrder) private var decks: [Deck]

    @AppStorage(DeckConstants.selectedDeckDefaultsKey) private var selectedDeckSlug: String = DeckConstants.allSlug
    @AppStorage("jam.soundEnabled") private var soundEnabled: Bool = true
    @AppStorage(OnboardingDefaultsKey.targetLanguage) private var targetLanguageRaw: String = TargetLanguage.spanish.rawValue
    @AppStorage("dailySet.themeIndex") private var dailyThemeIndex: Int = 0
    @AppStorage("dailySet.lastCompletedDay") private var dailySetLastCompletedDay: String = ""
    /// Language the daily-set state above belongs to. The loop position, lock,
    /// and replay set are shared global keys; we reset them when the active
    /// language changes so a new language doesn't inherit the previous one's
    /// lock ("come back tomorrow" without ever practicing) or theme position.
    @AppStorage("dailySet.stateLanguage") private var dailySetStateLanguage: String = ""
    @AppStorage(DailySetConfig.defaultsKey) private var dailySetTarget: Int = DailySetConfig.defaultSize
    /// Word IDs of the most recently built set, comma-joined, so "Practice
    /// again" can replay the exact same words — even after an app relaunch.
    @AppStorage("dailySet.lastSetIDs") private var lastSetIDsRaw: String = ""

    @State private var queue: [VocabularyWord] = []
    @State private var dragOffset: CGSize = .zero
    @State private var isAnimatingOut: Bool = false
    @State private var releaseRating: ReviewRating? = nil
    @State private var releaseProgress: Double = 0
    @State private var isFilterSheetPresented: Bool = false
    @State private var pendingSpeakOnFilterDismiss: Bool = false
    @State private var isSetComplete: Bool = false
    @State private var setStarted: Bool = false
    /// True while replaying a finished set via "Practice again" — finishing a
    /// replay returns to the completion screen instead of advancing the theme.
    @State private var isReplaying: Bool = false
    @State private var entitlements = Entitlements.shared
    /// Surfaced when a free user taps "Tomorrow's topic" — jumping ahead of
    /// the daily unlock is a Pro perk (content-breadth gate).
    @State private var isShowingPaywall: Bool = false
    @State private var isShowingWidgetSheet: Bool = false

    /// First-run nudge to install the Home Screen widget, shown above the card
    /// stack until the user taps it or dismisses it. Persists once dismissed.
    @AppStorage("widgetBanner.dismissed") private var widgetBannerDismissed: Bool = false

    private let swipeThreshold: CGFloat = 110

    /// The themed daily-set loop runs for any language that ships a deck
    /// taxonomy (all four bundled languages do). It orders by frequency `rank`,
    /// which gives an easy→hard gradient without relying on CEFR tags (sparse
    /// for FR/DE/IT). Falls back to the endless deck only if a language somehow
    /// has no decks seeded.
    private var dailySetActive: Bool {
        !decks.isEmpty
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                DS.Color.paper.ignoresSafeArea()

                if dailySetActive && isSetComplete {
                    completionState
                } else if dailySetActive && !setStarted && !queue.isEmpty {
                    introCard
                } else if queue.isEmpty {
                    emptyState
                } else {
                    ZStack(alignment: .top) {
                        Image("walrus")
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 180)
                            .padding(.top, 8)
                            .allowsHitTesting(false)

                        cardStack(in: geo.size)
                            .padding(.top, 130)
                    }
                }
            }
            .safeAreaInset(edge: .top) {
                // First-run widget nudge, pinned above whichever learning
                // screen is showing (intro card or card stack). Hidden on the
                // completion / empty / loading states.
                if !widgetBannerDismissed && !isSetComplete && !queue.isEmpty {
                    widgetBanner
                        .padding(.horizontal, 24)
                        .padding(.top, 8)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
        }
        .gochiHandNavigationTitle("Deck")
        .deckLanguageToolbar(isPresented: $isFilterSheetPresented)
        .onAppear {
            // A set completed in a prior session unlocks once the day rolls over.
            if dailySetActive, isSetComplete, dailySetLastCompletedDay != Self.dayKey(.now) {
                isSetComplete = false
                queue = []
            }
            rebuildQueueIfNeeded()
            applyPendingDeepLink()
        }
        .onChange(of: allWords.count) { _, _ in
            // Reseed / language switch: drop set state and rebuild the daily set
            // for the now-current language.
            isSetComplete = false
            queue = []
            rebuildQueueIfNeeded()
        }
        .onChange(of: targetLanguageRaw) { _, _ in
            // Language switch: `syncDailySetLanguage` (in rebuild) resets the
            // per-language loop state; clear the queue so it rebuilds fresh.
            isSetComplete = false
            queue = []
            rebuildQueueIfNeeded()
        }
        .onChange(of: selectedDeckSlug) { _, _ in
            // In themed-daily mode the path picks the deck, not the filter.
            guard !dailySetActive else { DailyWordService.refresh(context: context); return }
            queue = []
            rebuildQueueIfNeeded()
            DailyWordService.refresh(context: context)
        }
        .onChange(of: dailySetTarget) { _, _ in
            // Resize only a set that hasn't been started yet; a set in progress
            // stays frozen so the count doesn't shift under the user.
            guard dailySetActive, !setStarted, !isSetComplete else { return }
            queue = []
            rebuildQueueIfNeeded()
        }
        .onChange(of: queue.first?.id) { _, newID in
            guard let id = newID, let word = queue.first, word.id == id else {
                DailyWordService.refresh(context: context)
                return
            }
            // Suppress the next card's example-sentence audio when Walter
            // is calling — otherwise the 10th swipe plays its sentence
            // right under the ringer. Also skip while the filter sheet is
            // up (changing level rebuilds the queue under the sheet); the
            // dismissal handler below speaks the resulting front card.
            let coordinator = IncomingCallCoordinator.shared
            let inCall = coordinator.isPresentingIncoming || coordinator.isPresentingOutgoing
            // Don't speak while the intro card is up — the set hasn't started.
            // `startSet()` speaks the front card once the user taps Start.
            let onIntro = dailySetActive && !setStarted
            if isFilterSheetPresented {
                pendingSpeakOnFilterDismiss = true
            } else if soundEnabled, !inCall, !onIntro {
                SpeechService.shared.speak(word.exampleSentence)
            }
            publishWidgetSet()
        }
        .onChange(of: isFilterSheetPresented) { wasPresented, isPresented in
            // When the filter sheet closes after rebuilding the queue, speak
            // the now-front card so the user hears the example for whatever
            // level/deck they just chose. Nothing to play if they dismissed
            // without changing anything.
            guard wasPresented, !isPresented, pendingSpeakOnFilterDismiss else { return }
            pendingSpeakOnFilterDismiss = false
            guard soundEnabled, let word = queue.first else { return }
            let coordinator = IncomingCallCoordinator.shared
            let inCall = coordinator.isPresentingIncoming || coordinator.isPresentingOutgoing
            guard !inCall else { return }
            SpeechService.shared.speak(word.exampleSentence)
        }
        .sheet(isPresented: $isShowingPaywall) {
            // Once subscribed, jump straight into the next theme the user
            // tapped — no waiting for the daily unlock.
            PaywallView(onSubscribed: { advanceToTomorrowTopic() })
        }
        .sheet(isPresented: $isShowingWidgetSheet) {
            InstallWidgetSheet()
        }
    }

    private var dragProgress: CGFloat {
        min(1, abs(dragOffset.width) / swipeThreshold)
    }

    /// First-run widget nudge. Tapping the banner opens the same install sheet
    /// as Settings; the trailing ✕ dismisses it for good.
    private var widgetBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "square.grid.2x2.fill")
                .font(.sniglet(.title3))
                .foregroundStyle(DS.Color.ink)

            VStack(alignment: .leading, spacing: 2) {
                Text("Add the wordrus widget")
                    .font(.sniglet(.subheadline, weight: .bold))
                    .foregroundStyle(Color.whiteboardInk)
                Text("Keep today's word on your Home Screen.")
                    .font(.sniglet(.caption))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            Button {
                playLightHaptic()
                withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                    widgetBannerDismissed = true
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.sniglet(.caption, weight: .bold))
                    .foregroundStyle(.secondary)
                    .padding(8)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss widget tip")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.background)
                .shadow(color: .black.opacity(0.08), radius: 8, y: 3)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            isShowingWidgetSheet = true
        }
    }

    @ViewBuilder
    private func cardStack(in size: CGSize) -> some View {
        ZStack {
            if queue.count > 2 {
                upcomingCardView(word: queue[2], depth: 2)
            }
            if queue.count > 1 {
                upcomingCardView(word: queue[1], depth: 1)
            }

            HStack {
                dontKnowOverlay
                Spacer()
                knowOverlay
            }
            .padding(.horizontal, 32)
            .allowsHitTesting(false)

            if let current = queue.first {
                cardView(word: current)
                    .offset(dragOffset)
                    .rotationEffect(.degrees(Double(dragOffset.width / 20)))
                    .gesture(dragGesture(cardWidth: size.width))
                    .id(current.id)
                    .transition(.identity)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 28)
    }

    private func upcomingCardView(word: VocabularyWord, depth: Int) -> some View {
        let effectiveDepth = CGFloat(depth) - dragProgress
        return cardView(word: word)
            .scaleEffect(1.0 - 0.05 * effectiveDepth)
            .offset(y: 18 * effectiveDepth)
            .allowsHitTesting(false)
            .id(word.id)
            .transition(
                .asymmetric(
                    insertion: .opacity.combined(with: .scale(scale: 0.88, anchor: .bottom)),
                    removal: .identity
                )
            )
    }

    private func cardView(word: VocabularyWord) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text(word.lemma.capitalizedFirst)
                    .font(.gochiHand(size: 30))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .foregroundStyle(Color.whiteboardInk)
                Text(word.partOfSpeech)
                    .font(.sniglet(.subheadline))
                    .foregroundStyle(.secondary)
                Text(LocaleService.definition(for: word))
                    .font(.sniglet(.title3))
                    .padding(.top, 2)
            }

            InkDivider()

            VStack(alignment: .leading, spacing: 6) {
                Text(word.exampleSentence)
                    .font(.sniglet(.title3))
                    .italic()
                if let translation = LocaleService.exampleTranslation(for: word) {
                    Text(translation)
                        .font(.sniglet(.title3))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            HStack {
                Spacer()
                Button {
                    soundEnabled.toggle()
                    playSoundToggleHaptic()
                    if soundEnabled {
                        SpeechService.shared.speak(word.exampleSentence)
                    } else {
                        SpeechService.shared.stop()
                    }
                } label: {
                    Image(systemName: soundEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill")
                        .font(.sniglet(.title3))
                        .foregroundStyle(soundEnabled ? DS.Color.ink : Color.gray)
                        .frame(width: 56, height: 56)
                        .background(
                            Circle().fill(
                                soundEnabled
                                    ? DS.Color.ink.opacity(0.15)
                                    : Color.gray.opacity(0.15)
                            )
                        )
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(soundEnabled ? "Mute audio" : "Unmute audio")
                Spacer()
            }
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: 520, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(.background)
                .shadow(color: .black.opacity(0.12), radius: 16, y: 6)
        )
    }

    private var knowOverlay: some View {
        let progress: Double = {
            if releaseRating == .good { return releaseProgress }
            return dragOffset.width < 0 ? min(1, Double(-dragOffset.width) / Double(swipeThreshold)) : 0
        }()
        return overlayBadge(systemImage: "checkmark.circle.fill", tint: .green, progress: progress)
    }

    private var dontKnowOverlay: some View {
        let progress: Double = {
            if releaseRating == .again { return releaseProgress }
            return dragOffset.width > 0 ? min(1, Double(dragOffset.width) / Double(swipeThreshold)) : 0
        }()
        return overlayBadge(systemImage: "questionmark.circle.fill", tint: DS.Color.ink, progress: progress)
    }

    private func overlayBadge(systemImage: String, tint: Color, progress: Double) -> some View {
        Image(systemName: systemImage)
            .font(.sniglet(size: 84, weight: .bold))
            .foregroundStyle(tint)
            .padding(10)
            .background(Circle().fill(.white))
            .scaleEffect(0.5 + 0.5 * progress)
            .opacity(min(1, progress))
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.seal.fill")
                .font(.sniglet(size: 48))
                .foregroundStyle(.green)
            Text("All caught up")
                .font(.sniglet(.title2, weight: .bold))
            if let next = nextDueAfterToday() {
                Text("Next review \(next, style: .relative)")
                    .font(.sniglet(.callout))
                    .foregroundStyle(.secondary)
            } else {
                Text("Come back tomorrow for more practice.")
                    .font(.sniglet(.callout))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(24)
    }

    private func dragGesture(cardWidth: CGFloat) -> some Gesture {
        DragGesture()
            .onChanged { value in
                guard !isAnimatingOut else { return }
                dragOffset = CGSize(width: value.translation.width, height: 0)
            }
            .onEnded { value in
                guard !isAnimatingOut else { return }
                if value.translation.width < -swipeThreshold {
                    commit(rating: .good, toLeftBy: cardWidth)
                } else if value.translation.width > swipeThreshold {
                    commit(rating: .again, toLeftBy: -cardWidth)
                } else {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
                        dragOffset = .zero
                    }
                }
            }
    }

    private func commit(rating: ReviewRating, toLeftBy travel: CGFloat) {
        guard let word = queue.first else { return }
        isAnimatingOut = true

        // Snapshot the icon at full intensity so we can animate it out
        // independently of the card's dragOffset.
        var snapshot = Transaction()
        snapshot.disablesAnimations = true
        withTransaction(snapshot) {
            releaseRating = rating
            releaseProgress = 1.0
        }

        // Card flies off.
        withAnimation(.easeOut(duration: 0.25)) {
            dragOffset = CGSize(width: -travel * 1.6, height: 0)
        }

        // Icon pops slightly bigger then shrinks out.
        withAnimation(.spring(response: 0.18, dampingFraction: 0.55)) {
            releaseProgress = 1.3
        }
        withAnimation(.easeIn(duration: 0.28).delay(0.08)) {
            releaseProgress = 0
        }

        record(rating: rating, for: word)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.36) {
            var instant = Transaction()
            instant.disablesAnimations = true
            withTransaction(instant) {
                dragOffset = .zero
                releaseRating = nil
                releaseProgress = 0
            }
            var shouldCall = false
            withAnimation(.spring(response: 0.5, dampingFraction: 0.82)) {
                _ = queue.removeFirst()
                if dailySetActive {
                    if queue.isEmpty {
                        if isReplaying {
                            isReplaying = false
                            isSetComplete = true
                        } else {
                            completeSet()
                            shouldCall = true
                        }
                    }
                } else {
                    refillQueue()
                }
            }
            if shouldCall { triggerSetCompleteCall() }
            isAnimatingOut = false
            playLightHaptic()
        }
    }

    private func playLightHaptic() {
        #if os(iOS)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        #endif
    }

    private func playSoundToggleHaptic() {
        #if os(iOS)
        UISelectionFeedbackGenerator().selectionChanged()
        #endif
    }

    private func record(rating: ReviewRating, for word: VocabularyWord) {
        let existing = allProgress.first { $0.wordID == word.id }
        let progress = existing ?? LearningProgress(wordID: word.id)
        if existing == nil { context.insert(progress) }
        let intervalBefore = progress.intervalDays
        let result = SRSScheduler.next(progress: progress, rating: rating)
        progress.state = result.state
        progress.easeFactor = result.easeFactor
        progress.intervalDays = result.intervalDays
        progress.repetitions = result.repetitions
        progress.lapses = result.lapses
        progress.dueDate = result.dueDate
        progress.lastReviewedAt = result.lastReviewedAt
        let log = ReviewLog(
            wordID: word.id,
            reviewedAt: result.lastReviewedAt,
            rating: rating,
            intervalBeforeDays: intervalBefore,
            intervalAfterDays: result.intervalDays
        )
        context.insert(log)
        try? context.save()
        // In daily-set mode the end-of-stack call (`triggerSetCompleteCall`) is
        // the single call trigger; skip the engagement counter so a set of ≥10
        // words doesn't ring Walter mid-stack before the user finishes.
        if !dailySetActive {
            EngagementTracker.shared.recordCardReview()
        }
    }

    /// Reset the daily-set loop when the active language changes so each
    /// language starts (and locks) independently rather than sharing the global
    /// state keys. No-op while staying on the same language.
    private func syncDailySetLanguage() {
        guard dailySetStateLanguage != targetLanguageRaw else { return }
        dailySetStateLanguage = targetLanguageRaw
        dailyThemeIndex = 0
        dailySetLastCompletedDay = ""
        lastSetIDsRaw = ""
        isSetComplete = false
    }

    /// Push the current stack (front card first, then upcoming) to the App
    /// Group so the widget can rotate through today's words over the day and
    /// re-sync whenever the user swipes.
    private func publishWidgetSet() {
        let progressByID = Dictionary(allProgress.map { ($0.wordID, $0) }) { first, _ in first }
        DailyWordService.publishSet(queue, progressByID: progressByID)
    }

    private func rebuildQueueIfNeeded() {
        syncDailySetLanguage()
        guard queue.isEmpty, !isSetComplete else { return }
        if dailySetActive {
            if dailySetLastCompletedDay == Self.dayKey(.now) {
                isSetComplete = true
                return
            }
            buildDailySet()
            applyPendingDeepLink()
            setStarted = false
            lastSetIDsRaw = queue.map(\.id).joined(separator: ",")
        } else {
            refillQueue()
            applyPendingDeepLink()
        }
        // Publish directly here too: the `queue.first?.id` change handler misses
        // a same-day relaunch that rebuilds a set starting on the same word, so
        // the widget would otherwise never get this session's list.
        publishWidgetSet()
    }

    // MARK: - Themed daily set

    private var themedDecks: [Deck] {
        decks.sorted { $0.sortOrder < $1.sortOrder }
    }

    /// Theme whose set the user is on today (or will start next).
    private var currentTheme: Deck? {
        let d = themedDecks
        guard !d.isEmpty else { return nil }
        return d[((dailyThemeIndex % d.count) + d.count) % d.count]
    }

    /// Theme the user just finished — `dailyThemeIndex` already points past it
    /// once a set completes, so the completed one is the previous index.
    private var justCompletedTheme: Deck? {
        let d = themedDecks
        guard !d.isEmpty else { return nil }
        return d[(((dailyThemeIndex - 1) % d.count) + d.count) % d.count]
    }

    /// `allWords` scoped to the active language. Custom words from other
    /// languages survive language switches, so the raw query is no longer
    /// single-language — every word-pool read goes through this.
    private var currentWords: [VocabularyWord] {
        allWords.scoped(to: (TargetLanguage(rawValue: targetLanguageRaw) ?? .spanish).languageCode)
    }

    /// Build the frozen daily set: due reviews (any theme — the hybrid pool)
    /// first, then new words from today's theme by frequency rank. Capped at
    /// `dailySetTarget`.
    private func buildDailySet() {
        guard let theme = currentTheme else { queue = []; return }
        let now = Date.now
        let progressByID = Dictionary(uniqueKeysWithValues: allProgress.map { ($0.wordID, $0) })

        let dueReviews = currentWords
            .compactMap { word -> (VocabularyWord, Date)? in
                guard let progress = progressByID[word.id], progress.dueDate <= now else { return nil }
                return (word, progress.dueDate)
            }
            .sorted { $0.1 < $1.1 }
            .map(\.0)

        let themeNew = currentWords
            .filter { $0.deckSlugs.contains(theme.slug) && progressByID[$0.id] == nil }
            .sorted { $0.rank < $1.rank }

        let target = DailySetConfig.clamp(dailySetTarget)
        var set: [VocabularyWord] = []
        var seen = Set<String>()
        for word in dueReviews + themeNew {
            guard seen.insert(word.id).inserted else { continue }
            set.append(word)
            if set.count >= target { break }
        }

        // Backfill when the theme can't fill the set on its own. Sparse
        // languages (FR/DE/IT) have only ~16–45 words per theme, so a theme
        // exhausts in a few days; without this the set would dead-end empty and
        // never reach the climax call. Pulls any remaining unlearned word by
        // frequency rank (including untagged `common` words, which otherwise
        // never surface in a themed set). `allWords` is already rank-sorted.
        if set.count < target {
            for word in currentWords where progressByID[word.id] == nil {
                guard seen.insert(word.id).inserted else { continue }
                set.append(word)
                if set.count >= target { break }
            }
        }
        queue = set
    }

    private func completeSet() {
        dailySetLastCompletedDay = Self.dayKey(.now)
        dailyThemeIndex += 1
        isSetComplete = true
    }

    /// Begin today's set: reveal the cards and speak the first example.
    private func startSet() {
        setStarted = true
        guard soundEnabled, let word = queue.first else { return }
        SpeechService.shared.speak(word.exampleSentence)
    }

    /// Words to replay. Prefers the exact most-recently-built set; falls back
    /// to the finished theme's top words by rank when the stored IDs are
    /// missing (e.g. set completed before this feature, or a relaunch on an
    /// already-completed day where the build path is skipped).
    private func lastSetWords() -> [VocabularyWord] {
        let ids = lastSetIDsRaw.split(separator: ",").map(String.init)
        if !ids.isEmpty {
            let byID = Dictionary(uniqueKeysWithValues: currentWords.map { ($0.id, $0) })
            let words = ids.compactMap { byID[$0] }
            if !words.isEmpty { return words }
        }
        guard let theme = justCompletedTheme else { return [] }
        let target = DailySetConfig.clamp(dailySetTarget)
        return Array(
            currentWords
                .filter { $0.deckSlugs.contains(theme.slug) }
                .sorted { $0.rank < $1.rank }
                .prefix(target)
        )
    }

    /// Replay the finished set without advancing the theme or ringing Walter.
    /// Goes straight to the cards (intro already seen).
    private func replaySet() {
        let words = lastSetWords()
        guard !words.isEmpty else { return }
        isReplaying = true
        isSetComplete = false
        setStarted = true
        // Setting `queue` fires the `queue.first` change handler, which speaks
        // the front card (setStarted is already true) — no explicit speak here.
        withAnimation { queue = words }
    }

    /// "Tomorrow's topic" tapped on the completion screen. Jumping ahead of the
    /// daily unlock is a Pro perk — free users see the paywall first.
    private func tomorrowTopicTapped() {
        if entitlements.isPro {
            playLightHaptic()
            advanceToTomorrowTopic()
        } else {
            isShowingPaywall = true
        }
    }

    /// Start the next theme's set immediately, without waiting for the day to
    /// roll over. `dailyThemeIndex` already points at the next theme (advanced
    /// in `completeSet`), so clearing the lock and rebuilding lands on it and
    /// shows its intro card.
    private func advanceToTomorrowTopic() {
        dailySetLastCompletedDay = ""
        isReplaying = false
        isSetComplete = false
        setStarted = false
        queue = []
        rebuildQueueIfNeeded()
    }

    /// Walter rings as the set's climax. Mirrors the engagement-call haptic so
    /// the call feels earned. The chat screen is presented by `RootView`.
    private func triggerSetCompleteCall() {
        #if os(iOS)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        UIImpactFeedbackGenerator(style: .heavy).impactOccurred(intensity: 1.0)
        #endif
        IncomingCallCoordinator.shared.requestIncoming()
    }

    private static func dayKey(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return "\(c.year ?? 0)-\(c.month ?? 0)-\(c.day ?? 0)"
    }

    private var introCard: some View {
        let count = queue.count
        let minutes = max(2, Int((Double(count) * 0.5).rounded()))
        return VStack(spacing: 22) {
            Image("walrus")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 140)

            VStack(spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: currentTheme?.iconSystemName ?? "square.stack")
                    Text(currentTheme?.displayName ?? "Today's Set")
                }
                .font(.gochiHand(size: 30))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .foregroundStyle(Color.whiteboardInk)

                if let desc = currentTheme?.deckDescription, !desc.isEmpty {
                    Text(desc)
                        .font(.sniglet(.callout))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                Text("\(count) words · ~\(minutes) min · ends with a call from Walter")
                    .font(.sniglet(.subheadline, weight: .medium))
                    .foregroundStyle(Color.whiteboardInk)
                    .multilineTextAlignment(.center)
            }

            Button {
                playLightHaptic()
                withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                    startSet()
                }
            } label: {
                Text("Start")
            }
            .buttonStyle(.primary)
            .padding(.top, 4)
        }
        .padding(28)
        .frame(maxWidth: 360)
        .background(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(.background)
                .shadow(color: .black.opacity(0.12), radius: 16, y: 6)
        )
        .padding(.horizontal, 24)
    }

    private var completionState: some View {
        VStack(spacing: 18) {
            Image(systemName: "checkmark.seal.fill")
                .font(.sniglet(size: 56))
                .foregroundStyle(.green)
            Text("Set complete!")
                .font(.sniglet(.title, weight: .bold))
            if let done = justCompletedTheme {
                Text("You finished today's \(done.displayName) set.")
                    .font(.sniglet(.callout))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            if let next = currentTheme {
                Button {
                    tomorrowTopicTapped()
                } label: {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("TOMORROW'S TOPIC")
                                .font(.sniglet(.caption2, weight: .bold))
                                .foregroundStyle(.secondary)
                            HStack(spacing: 8) {
                                Image(systemName: next.iconSystemName)
                                Text(next.displayName)
                            }
                            .font(.sniglet(.title3, weight: .bold))
                            .foregroundStyle(Color.whiteboardInk)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: entitlements.isPro ? "arrow.right.circle.fill" : "lock.fill")
                            .font(.sniglet(.title3, weight: .bold))
                            .foregroundStyle(DS.Color.ink)
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 16)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(.background)
                            .shadow(color: .black.opacity(0.08), radius: 10, y: 4)
                    )
                }
                .buttonStyle(.plain)
            }
            Button {
                playLightHaptic()
                replaySet()
            } label: {
                Label("Practice again", systemImage: "arrow.counterclockwise")
                    .font(.sniglet(.body, weight: .bold))
                    .foregroundStyle(DS.Color.ink)
                    .padding(.vertical, 12)
                    .padding(.horizontal, 22)
                    .background(
                        Capsule().fill(DS.Color.ink.opacity(0.12))
                    )
            }
            .buttonStyle(.plain)
            .padding(.top, 4)

            if !entitlements.isPro {
                Label("Unlock tomorrow's topic today with Pro", systemImage: "lock.fill")
                    .font(.sniglet(.footnote))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(28)
    }

    private func refillQueue() {
        let targetSize = 5
        var working = queue
        let presentIDs = Set(working.map(\.id))
        let candidates = nextWords(excluding: presentIDs, limit: targetSize - working.count)
        working.append(contentsOf: candidates)
        queue = working
    }

    private func applyPendingDeepLink() {
        guard let pendingID = DeepLink.consumePendingWordID() else { return }
        if queue.first?.id == pendingID { return }
        if let index = queue.firstIndex(where: { $0.id == pendingID }) {
            let word = queue.remove(at: index)
            queue.insert(word, at: 0)
        } else if let word = currentWords.first(where: { $0.id == pendingID }) {
            queue.insert(word, at: 0)
        }
    }

    private func nextWords(excluding excluded: Set<String>, limit: Int) -> [VocabularyWord] {
        guard limit > 0 else { return [] }
        let now = Date.now
        let progressByID = Dictionary(uniqueKeysWithValues: allProgress.map { ($0.wordID, $0) })
        let pool = wordsInSelectedDeck()

        // Due pool: bucket by day so the most overdue still come first, but
        // shuffle within each day to avoid showing frequency-adjacent or
        // topic-adjacent reviews back-to-back.
        let dueWithDates = pool.compactMap { word -> (VocabularyWord, Date)? in
            guard !excluded.contains(word.id),
                  let progress = progressByID[word.id],
                  progress.dueDate <= now
            else { return nil }
            return (word, progress.dueDate)
        }
        let cal = Calendar.current
        let byDay = Dictionary(grouping: dueWithDates) { cal.startOfDay(for: $0.1) }
        let dueWords = byDay.keys.sorted().flatMap { day in
            (byDay[day] ?? []).map(\.0).shuffled()
        }

        // New pool: shuffle so frequency-adjacent lemmas don't cluster.
        let newWords = pool
            .filter { !excluded.contains($0.id) && progressByID[$0.id] == nil }
            .shuffled()

        return Array((dueWords + newWords).prefix(limit))
    }

    private func wordsInSelectedDeck() -> [VocabularyWord] {
        let deckSlug = selectedDeckSlug
        return currentWords.filter { word in
            deckSlug == DeckConstants.allSlug || word.deckSlugs.contains(deckSlug)
        }
    }

    private func nextDueAfterToday() -> Date? {
        let now = Date.now
        // Restrict to progress for words in the current language — orphan
        // progress from a previously-selected language persists in the store
        // (so learned/known state is preserved across switches) but must not
        // surface here as a misleading "next review" date.
        let currentWordIDs = Set(currentWords.map(\.id))
        return allProgress
            .filter { currentWordIDs.contains($0.wordID) && $0.dueDate > now }
            .min { $0.dueDate < $1.dueDate }?
            .dueDate
    }

}

#Preview {
    NavigationStack { JamView() }
        .modelContainer(for: [VocabularyWord.self, LearningProgress.self, ReviewLog.self, Deck.self], inMemory: true)
}
