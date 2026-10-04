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

    /// AppStorage key holding the `dayKey` of the last completed daily set.
    /// Shared so both `JamView` and the tab bar can read completion state.
    static let lastCompletedDayKey = "dailySet.lastCompletedDay"

    /// Stable per-day identifier used to lock the daily set to one set per day.
    static func dayKey(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return "\(c.year ?? 0)-\(c.month ?? 0)-\(c.day ?? 0)"
    }

    /// Whether today's daily set has already been finished. Drives the tray
    /// tab icon (full = words waiting, empty = done for the day).
    static func isDoneToday(lastCompletedDay: String, now: Date = .now) -> Bool {
        lastCompletedDay == dayKey(now)
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
    @AppStorage(OnboardingDefaultsKey.cefrLevel) private var cefrLevelRaw: String = CEFRLevel.a1.rawValue
    /// Word IDs of the most recently built set, comma-joined, so "Practice
    /// again" can replay the exact same words — even after an app relaunch.
    @AppStorage("dailySet.lastSetIDs") private var lastSetIDsRaw: String = ""
    /// Whether the set built for today is a revision set (a random shuffle of
    /// words the user is still learning) rather than a themed set. Persisted so
    /// the intro/completion copy and theme-advance logic stay correct across a
    /// relaunch — including a relaunch on an already-completed day, where the
    /// set is never rebuilt.
    @AppStorage("dailySet.lastWasRevision") private var lastSetWasRevision: Bool = false

    @State private var queue: [VocabularyWord] = []
    @State private var dragOffset: CGSize = .zero
    @State private var isAnimatingOut: Bool = false
    @State private var releaseRating: ReviewRating? = nil
    @State private var releaseProgress: Double = 0
    @State private var isFilterSheetPresented: Bool = false
    @State private var pendingSpeakOnFilterDismiss: Bool = false
    @State private var isSetComplete: Bool = false
    @State private var setStarted: Bool = false
    /// Walrus image aspect (height / width) and the scale it shrinks to on the
    /// completion screen. Used to reserve its slot and size the badge.
    private static let walrusAspect: CGFloat = 990.0 / 543.0
    private static let completionWalrusScale: CGFloat = 0.78
    /// The walrus's on-screen height once shrunk for the completion screen —
    /// the completion copy reserves exactly this much so it sits clear below.
    private static let reservedWalrusHeight: CGFloat = 180 * completionWalrusScale * walrusAspect
    /// True while replaying a finished set via "Practice again" — finishing a
    /// replay returns to the completion screen instead of advancing the theme.
    @State private var isReplaying: Bool = false
    @State private var entitlements = Entitlements.shared
    /// Surfaced when a free user taps "Tomorrow's topic" — jumping ahead of
    /// the daily unlock is a Pro perk (content-breadth gate).
    @State private var isShowingPaywall: Bool = false
    @State private var isShowingWidgetSheet: Bool = false

    /// Whether the user has touched the front card since the current set began.
    /// Gates the swipe-hint nudge so it stops the instant they start swiping.
    @State private var didInteractWithCard: Bool = false
    /// How many times the swipe hint has nudged the current set's first card,
    /// capped so an idle user isn't nagged indefinitely.
    @State private var swipeHintsShown: Int = 0
    private let maxSwipeHints = 3

    /// First-run nudge to install the Home Screen widget, shown above the card
    /// stack until the user taps it or dismisses it. Persists once dismissed.
    @AppStorage("widgetBanner.dismissed") private var widgetBannerDismissed: Bool = false

    private let swipeThreshold: CGFloat = 110

    /// The themed daily-set loop runs for any language that ships a deck
    /// taxonomy (all four bundled languages do). New words come from the
    /// learner's level-anchored pool (see `LevelAnchor`), ordered by frequency
    /// `rank` within it for an easy→hard gradient. Falls back to the endless
    /// deck only if a language somehow has no decks seeded.
    private var dailySetActive: Bool {
        !decks.isEmpty
    }

    /// Shown during the card stack and completion screen; hidden on the intro
    /// and empty states (which supply their own art or none).
    private var walrusIsVisible: Bool {
        if dailySetActive && isSetComplete { return true }              // completion
        if dailySetActive && !setStarted && !queue.isEmpty { return false } // intro
        if queue.isEmpty && !isSetComplete { return false }            // empty
        return true                                                     // cards
    }

    /// Vertical offset from the top of the screen. Sits just under the top on
    /// the card stack; drops to roughly a third down on completion so it reads
    /// as centered above the "Set complete!" copy.
    private func walrusOffset(in geo: GeometryProxy) -> CGFloat {
        isSetComplete ? geo.size.height * 0.12 : 8
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                DS.Color.paper.ignoresSafeArea()

                // The walrus sits behind the content so it can glide from the
                // top of the card stack down to the centre exactly as the last
                // card is swiped away — see `walrusOffset(in:)`.
                if walrusIsVisible {
                    Image("walrus")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 180)
                        .scaleEffect(isSetComplete ? Self.completionWalrusScale : 1, anchor: .top)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .offset(y: walrusOffset(in: geo))
                        .allowsHitTesting(false)
                }

                // Content layer (no walrus). The completion copy waits for the
                // final card to finish flying off (`!isAnimatingOut`) so the
                // card and the walrus animate at the same time, not in sequence.
                if dailySetActive && isSetComplete && !isAnimatingOut {
                    completionState(in: geo)
                        .transition(.opacity)
                } else if dailySetActive && !setStarted && !queue.isEmpty {
                    introCard
                } else if queue.isEmpty && !isSetComplete {
                    emptyState
                } else {
                    cardStack(in: geo.size)
                        .padding(.top, 130)
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
        .onChange(of: cefrLevelRaw) { _, _ in
            // Level change re-anchors the new-word pool (see LevelAnchor).
            // A daily set in progress stays frozen; anything unstarted rebuilds.
            DailyWordService.refresh(context: context)
            if dailySetActive {
                guard !setStarted, !isSetComplete else { return }
            }
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
            PaywallView(onSubscribed: { advanceToTomorrowTopic() }, source: .jamTopic)
        }
        .sheet(isPresented: $isShowingWidgetSheet) {
            InstallWidgetSheet()
        }

        .onChange(of: visibleCardWordID, initial: true) { _, wordID in
            DeepLinkCoordinator.shared.visibleWordID = wordID
        }
        .onDisappear {
            DeepLinkCoordinator.shared.visibleWordID = nil
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

            HStack(spacing: 20) {
                Spacer()

                // Replay the example on demand. Independent of the mute toggle
                // below — an explicit tap always speaks, even when auto-play is
                // off — and unmutes so the user isn't left wondering why nothing
                // played after they asked for it.
                Button {
                    playLightHaptic()
                    if !soundEnabled { soundEnabled = true }
                    SpeechService.shared.speak(word.exampleSentence)
                } label: {
                    Image(systemName: "play.fill")
                        .font(.sniglet(.title3))
                        .foregroundStyle(DS.Color.ink)
                        .frame(width: 56, height: 56)
                        .background(Circle().fill(DS.Color.ink.opacity(0.15)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Replay sentence")

                // Mute toggle — controls whether each new card auto-speaks.
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
                didInteractWithCard = true
                dragOffset = CGSize(width: value.translation.width, height: 0)
            }
            .onEnded { value in
                guard !isAnimatingOut else { return }
                // Project where the swipe would land if the finger kept its
                // release velocity, so a quick flick commits even when the
                // finger itself didn't cross the threshold.
                let translation = value.translation.width
                let projected = value.predictedEndTranslation.width
                let flickSpeed = abs(projected - translation)
                if translation < -swipeThreshold || projected < -swipeThreshold * 1.5 {
                    commit(rating: .good, direction: -1, cardWidth: cardWidth, flickSpeed: flickSpeed)
                } else if translation > swipeThreshold || projected > swipeThreshold * 1.5 {
                    commit(rating: .again, direction: 1, cardWidth: cardWidth, flickSpeed: flickSpeed)
                } else {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
                        dragOffset = .zero
                    }
                }
            }
    }

    private func commit(rating: ReviewRating, direction: CGFloat, cardWidth: CGFloat, flickSpeed: CGFloat) {
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

        // Fly the card off in the swipe direction, continuing the finger's
        // motion. Target just past the screen edge (rather than far off) and
        // use a longer easeOut so the exit reads as a smooth glide instead of
        // vanishing. A hard flick shaves the duration so fast swipes feel snappy.
        let exitDuration = flickSpeed > 320 ? 0.30 : 0.44
        let exitX = direction * (cardWidth * 1.15 + 80)
        withAnimation(.easeOut(duration: exitDuration)) {
            dragOffset = CGSize(width: exitX, height: 0)
        }

        // Last card: start the walrus gliding down to centre right now, so it
        // moves in lockstep with the card flying off. The completion copy only
        // appears once the card is gone (gated on `isAnimatingOut`).
        if dailySetActive && queue.count == 1 {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) {
                isSetComplete = true
            }
        }

        // Icon pops slightly bigger then shrinks out.
        withAnimation(.spring(response: 0.18, dampingFraction: 0.55)) {
            releaseProgress = 1.3
        }
        withAnimation(.easeIn(duration: 0.28).delay(0.08)) {
            releaseProgress = 0
        }

        record(rating: rating, for: word)

        // Swap in the next card only once the current one has cleared the
        // screen, so the flown-off card is offscreen when it's removed.
        DispatchQueue.main.asyncAfter(deadline: .now() + exitDuration + 0.02) {
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
            // Fade the completion copy in now that the card has cleared.
            withAnimation(.easeOut(duration: 0.25)) { isAnimatingOut = false }
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
        Analytics.capture(.cardReviewed, ["rating": "\(rating)", "source": "jam"])
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

    /// The word the card stack is currently showing, or nil when no readable
    /// card is on screen. Mirrors the branch chain in `body`: the completion,
    /// intro and empty states all render instead of the stack, so none of them
    /// count as showing a word. Published to `DeepLinkCoordinator` so a widget
    /// tap on this exact word doesn't open a sheet duplicating the card the
    /// user is already looking at.
    private var visibleCardWordID: String? {
        guard !queue.isEmpty else { return nil }
        if dailySetActive, isSetComplete || !setStarted { return nil }
        return queue.first?.id
    }

    /// Push the current stack (front card first, then upcoming) to the App
    /// Group so the widget can rotate through today's words over the day and
    /// re-sync whenever the user swipes.
    private func publishWidgetSet() {
        let progressByID = Dictionary(allProgress.map { ($0.wordID, $0) }) { first, _ in first }
        DailyWordService.publishSet(queue, progressByID: progressByID, context: context)
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
            setStarted = false
            lastSetIDsRaw = queue.map(\.id).joined(separator: ",")
        } else {
            refillQueue()
        }
        // Publish directly here too: the `queue.first?.id` change handler misses
        // a same-day relaunch that rebuilds a set starting on the same word, so
        // the widget would otherwise never get this session's list.
        publishWidgetSet()
    }

    // MARK: - Themed daily set

    private var hasCustomWords: Bool {
        currentWords.contains { $0.id.hasPrefix("custom-") }
    }

    private var themedDecks: [Deck] {
        var result = decks.sorted { $0.sortOrder < $1.sortOrder }
        // Append a synthetic "My Words" theme so the user's own added words get
        // their own day in the rotation — only when they have some, so the
        // theme never comes up empty.
        if hasCustomWords {
            result.append(Deck(
                slug: DeckConstants.myWordsSlug,
                displayName: "My Words",
                deckDescription: "Words you added yourself.",
                iconSystemName: "star.fill",
                sortOrder: 9999
            ))
        }
        return result
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

    /// Build the frozen daily set. On a revision day it's a random shuffle of
    /// words the user is still learning (any theme); otherwise it's a themed
    /// set drawn *only* from today's theme — due reviews first, then new words
    /// by frequency rank. Capped at `dailySetTarget`.
    private func buildDailySet() {
        if shouldBuildRevisionToday() {
            lastSetWasRevision = true
            buildRevisionSet()
            return
        }
        lastSetWasRevision = false

        guard let theme = currentTheme else { queue = []; return }
        let now = Date.now
        let progressByID = Dictionary(uniqueKeysWithValues: allProgress.map { ($0.wordID, $0) })

        // "My Words" theme: a stable daily-random pick of the user's own added
        // words. Ordered by a day-seeded hash so the set is the same all day
        // (survives relaunch/rebuild) but rotates which words appear day to day.
        if theme.slug == DeckConstants.myWordsSlug {
            let dayKey = Self.dayKey(now)
            queue = Array(
                currentWords
                    .filter { $0.id.hasPrefix("custom-") }
                    .sorted { Self.stableHash("\(dayKey)|\($0.id)") < Self.stableHash("\(dayKey)|\($1.id)") }
                    .prefix(DailySetConfig.clamp(dailySetTarget))
            )
            return
        }

        // Every other theme is seeded vocabulary only — custom words are
        // excluded so they don't flood the front of the themed set. Due reviews
        // are scoped to this theme too: a themed set holds words from its own
        // category only (revision of other themes' due words happens on a
        // dedicated revision day instead).
        let dueReviews = currentWords
            .filter { !$0.id.hasPrefix("custom-") && $0.deckSlugs.contains(theme.slug) }
            .compactMap { word -> (VocabularyWord, Date)? in
                guard let progress = progressByID[word.id], progress.dueDate <= now else { return nil }
                return (word, progress.dueDate)
            }
            .sorted { $0.1 < $1.1 }
            .map(\.0)

        let level = OnboardingStore.cefrLevel
        let themeNew = LevelAnchor.anchored(
            currentWords
                .filter { !$0.id.hasPrefix("custom-") && $0.deckSlugs.contains(theme.slug) && progressByID[$0.id] == nil }
                .sorted { $0.rank < $1.rank },
            to: level
        )

        let target = DailySetConfig.clamp(dailySetTarget)
        var set: [VocabularyWord] = []
        var seen = Set<String>()
        for word in dueReviews + themeNew {
            guard seen.insert(word.id).inserted else { continue }
            set.append(word)
            if set.count >= target { break }
        }

        // Backfill when new + due can't fill the set on its own — without this
        // a set could dead-end short of the climax call. Stays *within the
        // theme* (category-only), relaxing only the level anchor as a last
        // resort: any remaining theme word by frequency rank, including ones
        // the user has already seen. If the theme is too small to reach the
        // target the set is simply shorter — it still ends with Walter's call.
        if set.count < target {
            let backfill = currentWords
                .filter { !$0.id.hasPrefix("custom-") && $0.deckSlugs.contains(theme.slug) }
                .sorted { $0.rank < $1.rank }
            for word in backfill {
                guard seen.insert(word.id).inserted else { continue }
                set.append(word)
                if set.count >= target { break }
            }
        }
        queue = set
    }

    /// The user's "learning list": seeded words they've started but not yet
    /// mastered — anything lapsed or still in the `learning`/`review` state.
    /// Custom words are excluded so revision stays focused on core vocabulary.
    private func learningWords() -> [VocabularyWord] {
        let progressByID = Dictionary(uniqueKeysWithValues: allProgress.map { ($0.wordID, $0) })
        return currentWords.filter { word in
            guard !word.id.hasPrefix("custom-"), let p = progressByID[word.id] else { return false }
            return p.lapses > 0 || p.state == .learning || p.state == .review
        }
    }

    /// Minimum learning-list size before a revision day can occur — below this
    /// there isn't a meaningful pool to revise, so we stay on themed sets.
    private static let revisionMinPool = 5

    /// Whether today's set should be a revision set. Deterministic per day and
    /// language (so it survives relaunch/rebuild), firing on roughly one day in
    /// four — but only once the learning list is big enough to be worth it.
    private func shouldBuildRevisionToday() -> Bool {
        let key = "revision|\(targetLanguageRaw)|\(Self.dayKey(.now))"
        guard Self.stableHash(key) % 4 == 0 else { return false }
        return learningWords().count >= Self.revisionMinPool
    }

    /// Build a revision set: a stable-per-day random shuffle of the learning
    /// list. Day-seeded (like the "My Words" theme) so it's identical all day
    /// but picks a fresh mix on the next revision day.
    private func buildRevisionSet() {
        let dayKey = Self.dayKey(.now)
        queue = Array(
            learningWords()
                .sorted { Self.stableHash("\(dayKey)|rev|\($0.id)") < Self.stableHash("\(dayKey)|rev|\($1.id)") }
                .prefix(DailySetConfig.clamp(dailySetTarget))
        )
    }

    /// Deterministic FNV-1a hash — stable across launches (unlike
    /// `String.hashValue`, which is randomized per process), so the day-seeded
    /// "My Words" ordering is identical every time the set rebuilds in a day.
    private static func stableHash(_ string: String) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in string.utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x00000100000001B3
        }
        return hash
    }

    private func completeSet() {
        dailySetLastCompletedDay = Self.dayKey(.now)
        // A revision day is a detour, not a theme — don't advance the rotation,
        // so the theme it interrupted still comes up next.
        if !lastSetWasRevision {
            dailyThemeIndex += 1
        }
        isSetComplete = true
    }

    /// Begin today's set: reveal the cards and speak the first example.
    private func startSet() {
        setStarted = true
        // Arm the swipe hint so an idle user gets a teased nudge showing the
        // card can be swiped.
        didInteractWithCard = false
        swipeHintsShown = 0
        scheduleSwipeHint(after: 3.5)
        guard soundEnabled, let word = queue.first else { return }
        SpeechService.shared.speak(word.exampleSentence)
    }

    /// Nudge the front card slightly to the right and back to hint that it's
    /// swipeable. Fires a beat after the set starts and repeats while the user
    /// stays idle, stopping the moment they touch the card or the cap is hit.
    private func scheduleSwipeHint(after delay: Double) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            guard !didInteractWithCard,
                  !isAnimatingOut,
                  dragOffset == .zero,
                  swipeHintsShown < maxSwipeHints,
                  !isSetComplete,
                  queue.first != nil,
                  !(dailySetActive && !setStarted)
            else { return }
            swipeHintsShown += 1
            withAnimation(.spring(response: 0.3, dampingFraction: 0.5)) {
                dragOffset = CGSize(width: 46, height: 0)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.34) {
                guard !didInteractWithCard, !isAnimatingOut else { return }
                withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
                    dragOffset = .zero
                }
                scheduleSwipeHint(after: 3.2)
            }
        }
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
        DailySetConfig.dayKey(date)
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
                    Image(systemName: lastSetWasRevision ? "arrow.triangle.2.circlepath" : (currentTheme?.iconSystemName ?? "square.stack"))
                    Text(lastSetWasRevision ? "Revision" : (currentTheme?.displayName ?? "Today's Set"))
                }
                .font(.gochiHand(size: 30))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .foregroundStyle(Color.whiteboardInk)

                if lastSetWasRevision {
                    Text("A mix of words you're still learning.")
                        .font(.sniglet(.callout))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                } else if let desc = currentTheme?.deckDescription, !desc.isEmpty {
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

    private func completionState(in geo: GeometryProxy) -> some View {
        VStack(spacing: 18) {
            // Reserve the walrus's slot (it's drawn in the body overlay so it can
            // glide down from the card stack), plus a little breathing room, so
            // the copy and its badge sit clear below it.
            Color.clear
                .frame(height: Self.reservedWalrusHeight + 12)
            Text("Set complete!")
                .font(.sniglet(.title, weight: .bold))
            if lastSetWasRevision {
                Text("You finished today's revision set.")
                    .font(.sniglet(.callout))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else if let done = justCompletedTheme {
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
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.horizontal, 28)
        .padding(.top, walrusOffset(in: geo))
    }

    private func refillQueue() {
        let targetSize = 5
        var working = queue
        let presentIDs = Set(working.map(\.id))
        let candidates = nextWords(excluding: presentIDs, limit: targetSize - working.count)
        working.append(contentsOf: candidates)
        queue = working
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

        // New pool: shuffle so frequency-adjacent lemmas don't cluster, then
        // anchor to the learner's level (shuffle survives within each band).
        let newWords = LevelAnchor.anchored(
            pool
                .filter { !excluded.contains($0.id) && progressByID[$0.id] == nil }
                .shuffled(),
            to: OnboardingStore.cefrLevel
        )

        return Array((dueWords + newWords).prefix(limit))
    }

    private func wordsInSelectedDeck() -> [VocabularyWord] {
        let deckSlug = selectedDeckSlug
        if deckSlug == DeckConstants.myWordsSlug {
            return currentWords.filter { $0.id.hasPrefix("custom-") }
        }
        return currentWords.filter { word in
            // Custom words live only under "My Words", never in seeded decks.
            guard !word.id.hasPrefix("custom-") else { return false }
            return deckSlug == DeckConstants.allSlug || word.deckSlugs.contains(deckSlug)
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
