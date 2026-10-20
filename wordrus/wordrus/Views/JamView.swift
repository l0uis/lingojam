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

/// The daily-set loop state — today's lock, theme position, revision flag —
/// lives in global keys that the Deck and Words tabs bind to directly. Each
/// language keeps its own copy: switching away stashes the outgoing
/// language's under suffixed keys and loads the incoming one's, so a round
/// trip neither loses your place in the theme rotation nor unlocks a set you
/// already finished today.
enum DailySetState {
    static let stateLanguageKey = "dailySet.stateLanguage"

    private static var defaults: UserDefaults { .standard }

    /// Make `languageRaw` the language the global keys describe. No-op when
    /// they already do. A language seen for the first time starts at theme 1
    /// with nothing done today.
    static func activate(_ languageRaw: String) {
        let outgoing = defaults.string(forKey: stateLanguageKey) ?? ""
        guard outgoing != languageRaw else { return }
        if !outgoing.isEmpty {
            defaults.set(defaults.string(forKey: DailySetConfig.lastCompletedDayKey) ?? "",
                         forKey: key(DailySetConfig.lastCompletedDayKey, outgoing))
            defaults.set(defaults.integer(forKey: DailyThemePath.themeIndexKey),
                         forKey: key(DailyThemePath.themeIndexKey, outgoing))
            defaults.set(defaults.bool(forKey: DailyThemePath.lastWasRevisionKey),
                         forKey: key(DailyThemePath.lastWasRevisionKey, outgoing))
        }
        defaults.set(defaults.string(forKey: key(DailySetConfig.lastCompletedDayKey, languageRaw)) ?? "",
                     forKey: DailySetConfig.lastCompletedDayKey)
        defaults.set(defaults.integer(forKey: key(DailyThemePath.themeIndexKey, languageRaw)),
                     forKey: DailyThemePath.themeIndexKey)
        defaults.set(defaults.bool(forKey: key(DailyThemePath.lastWasRevisionKey, languageRaw)),
                     forKey: DailyThemePath.lastWasRevisionKey)
        defaults.set(languageRaw, forKey: stateLanguageKey)
    }

    private static func key(_ base: String, _ languageRaw: String) -> String {
        "\(base).\(languageRaw)"
    }
}

/// The order the daily set walks through themes — shared by the Deck tab,
/// which builds each day's set, and the Words tab, which names it.
enum DailyThemePath {
    static let themeIndexKey = "dailySet.themeIndex"
    static let lastWasRevisionKey = "dailySet.lastWasRevision"

    /// Decks in rotation order, plus a synthetic "My Words" theme so the
    /// user's own added words get their own day — only when they have some,
    /// so the theme never comes up empty.
    static func themes(_ decks: [Deck], includeMyWords: Bool) -> [Deck] {
        var result = decks.sorted { $0.sortOrder < $1.sortOrder }
        if includeMyWords {
            result.append(Deck(
                slug: DeckConstants.myWordsSlug,
                displayName: "My Words",
                deckDescription: String(localized: "Words you added yourself."),
                iconSystemName: "star.fill",
                sortOrder: 9999
            ))
        }
        return result
    }

    /// The theme at a (possibly out-of-range) rotation index, wrapping both ways.
    static func theme(_ themes: [Deck], at index: Int) -> Deck? {
        guard !themes.isEmpty else { return nil }
        return themes[((index % themes.count) + themes.count) % themes.count]
    }
}

struct JamView: View {
    @Environment(\.modelContext) private var context
    @Query private var allProgress: [LearningProgress]
    @Query(sort: \VocabularyWord.rank) private var allWords: [VocabularyWord]
    /// User-added words only, so `hasCustomWords` doesn't scan the whole
    /// vocabulary — the end-of-day card reads it on every drag frame.
    @Query(filter: #Predicate<VocabularyWord> { $0.id.starts(with: "custom-") })
    private var customWords: [VocabularyWord]
    @Query(sort: \Deck.sortOrder) private var decks: [Deck]

    @AppStorage(DeckConstants.selectedDeckDefaultsKey) private var selectedDeckSlug: String = DeckConstants.allSlug
    @AppStorage("jam.soundEnabled") private var soundEnabled: Bool = true
    @AppStorage(OnboardingDefaultsKey.targetLanguage) private var targetLanguageRaw: String = TargetLanguage.spanish.rawValue
    @AppStorage(DailyThemePath.themeIndexKey) private var dailyThemeIndex: Int = 0
    @AppStorage("dailySet.lastCompletedDay") private var dailySetLastCompletedDay: String = ""
    /// Language the daily-set state above belongs to. The loop position, lock,
    /// and replay set are shared global keys; we reset them when the active
    /// language changes so a new language doesn't inherit the previous one's
    /// lock ("come back tomorrow" without ever practicing) or theme position.
    @AppStorage(DailySetState.stateLanguageKey) private var dailySetStateLanguage: String = ""
    @AppStorage(DailySetConfig.defaultsKey) private var dailySetTarget: Int = DailySetConfig.defaultSize
    @AppStorage(OnboardingDefaultsKey.cefrLevel) private var cefrLevelRaw: String = CEFRLevel.a1.rawValue
    /// Hides "Leave a Review" on the end-of-day card once the user has opened
    /// the App Store review page (from here or Settings).
    @AppStorage(AppStoreLinks.didOpenWriteReviewKey) private var didOpenWriteReview: Bool = false
    @Environment(\.openURL) private var openURL
    /// Whether the set built for today is a revision set (a random shuffle of
    /// words the user is still learning) rather than a themed set. Persisted so
    /// the intro/completion copy and theme-advance logic stay correct across a
    /// relaunch — including a relaunch on an already-completed day, where the
    /// set is never rebuilt.
    @AppStorage(DailyThemePath.lastWasRevisionKey) private var lastSetWasRevision: Bool = false

    @State private var queue: [VocabularyWord] = []
    @State private var dragOffset: CGSize = .zero
    @State private var isAnimatingOut: Bool = false
    @State private var releaseRating: ReviewRating? = nil
    @State private var releaseProgress: Double = 0
    @State private var isFilterSheetPresented: Bool = false
    @State private var pendingSpeakOnFilterDismiss: Bool = false
    @State private var isSetComplete: Bool = false
    @State private var setStarted: Bool = false
    /// Theme of the extra stack a Pro user started from the end-of-day card,
    /// or nil for the daily set. Kept after the stack finishes so the done
    /// card can name it. Bonus stacks never move the theme rotation or the
    /// daily lock, and don't ring Walter.
    @State private var bonusTheme: Deck?
    @State private var isShowingAnotherStack: Bool = false
    /// Free users tapping "Start another stack" go straight to the paywall;
    /// the deck list opens once it closes with Pro.
    @State private var isShowingStackPaywall: Bool = false
    @State private var isShowingSpeedPaywall: Bool = false
    @State private var entitlements = Entitlements.shared
    /// Rubber-banded horizontal offset of the end-of-day card. It tugs a little
    /// under the finger, then springs back — the day's last card can't be
    /// swiped away.
    @State private var doneCardDrag: CGFloat = 0
    @State private var isShowingWidgetSheet: Bool = false
    /// Every few days a bonus curiosity card is dealt in as the daily set's
    /// last card (see `CuriosityService`). Swiped away like a word, but
    /// unrated; the set completes once it's gone.
    @State private var curiosity: Curiosity?
    @State private var curiosityDrag: CGFloat = 0

    /// Whether the user has touched the front card since the current set began.
    /// Gates the swipe-hint nudge so it stops the instant they start swiping.
    @State private var didInteractWithCard: Bool = false
    /// How many times the swipe hint has nudged the current set's first card,
    /// capped so an idle user isn't nagged indefinitely.
    @State private var swipeHintsShown: Int = 0
    private let maxSwipeHints = 3
    /// Which way the hint is currently nudging the card, so the card can say
    /// what that direction means. Nil whenever the hint isn't running.
    @State private var swipeHintDirection: ReviewRating? = nil
    private let swipeHintDistance: CGFloat = 60

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

    /// Shown during the card stack; hidden on the intro, end-of-day and empty
    /// states (the first two carry Dr Tusk inside the card).
    private var walrusIsVisible: Bool {
        if showsDoneCardAlone { return false }                          // done card
        if dailySetActive && !setStarted && !queue.isEmpty { return false } // intro
        if queue.isEmpty && !isSetComplete && curiosity == nil { return false } // empty
        return true                                                     // cards
    }

    /// Whether today's curiosity is in the stack: daily set only (not a bonus
    /// stack), from when it's among the last cards until it's swiped away.
    private var curiosityInStack: Bool {
        dailySetActive && !isSetComplete && bonusTheme == nil && curiosity != nil && queue.count <= 2
    }

    /// The end-of-day card is the only thing on screen: no walrus above it,
    /// so it takes the full height.
    private var showsDoneCardAlone: Bool {
        dailySetActive && isSetComplete
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                DS.Color.paper.ignoresSafeArea()

                // The walrus peeks out from behind the card stack. He leaves
                // once the set is done — the end-of-day card has him inside.
                if walrusIsVisible {
                    Image("walrus")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 180)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .offset(y: 8)
                        .allowsHitTesting(false)
                }

                // Content layer (no walrus). Once the set is done the stack is
                // just the end-of-day card, so it stays on `cardStack` too.
                if dailySetActive && !setStarted && !queue.isEmpty && !isSetComplete {
                    introCard
                } else if queue.isEmpty && !isSetComplete && curiosity == nil {
                    emptyState
                } else {
                    // Room for the peeking walrus; once the set is done he's
                    // gone and the end-of-day card rises into the space.
                    cardStack(in: geo.size)
                        .padding(.top, showsDoneCardAlone ? 0 : 130)
                }
            }
            .safeAreaInset(edge: .top) {
                // First-run widget nudge, pinned above whichever learning
                // screen is showing (intro card or card stack, including the
                // end-of-day card — so the stack doesn't jump when the last word
                // goes). Hidden on the empty / loading states.
                if !widgetBannerDismissed && (!queue.isEmpty || (dailySetActive && isSetComplete)) {
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
                bonusTheme = nil
                curiosity = nil
                queue = []
            }
            rebuildQueueIfNeeded()
        }
        .onChange(of: allWords.count) { _, _ in
            // Reseed / language switch: drop set state and rebuild the daily set
            // for the now-current language.
            isSetComplete = false
            bonusTheme = nil
            curiosity = nil
            queue = []
            rebuildQueueIfNeeded()
        }
        .onChange(of: targetLanguageRaw) { _, _ in
            // Language switch: `syncDailySetLanguage` (in rebuild) resets the
            // per-language loop state; clear the queue so it rebuilds fresh.
            isSetComplete = false
            bonusTheme = nil
            curiosity = nil
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
        .onChange(of: queue.count) { _, _ in
            dealCuriosityIfDue()
        }
        .onChange(of: queue.first?.id) { _, newID in
            guard let id = newID, let word = queue.first, word.id == id else {
                DailyWordService.refresh(context: context)
                // The curiosity card just came to the front: read the phrase,
                // as a word card reads its example.
                if curiosityInStack, soundEnabled, let curiosity,
                   !IncomingCallCoordinator.shared.isPresentingIncoming {
                    SpeechService.shared.speak(curiosity.phrase)
                }
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
        .sheet(isPresented: $isShowingWidgetSheet) {
            InstallWidgetSheet()
        }
        .sheet(isPresented: $isShowingAnotherStack) {
            AnotherStackSheet(
                themes: themedDecks,
                finishedSlug: lastSetWasRevision ? nil : justCompletedTheme?.slug,
                onPick: startBonusStack
            )
        }
        .sheet(isPresented: $isShowingStackPaywall, onDismiss: {
            if entitlements.isPro { isShowingAnotherStack = true }
        }) {
            PaywallView(source: .anotherStack)
        }
        .sheet(isPresented: $isShowingSpeedPaywall) {
            PaywallView(source: .voiceSpeed)
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
            // In the daily set the end-of-day card is the bottom of the deck:
            // it shows through as the stack runs down and becomes the front
            // card once the last word is swiped away.
            // Today's curiosity, if any, is the set's last card: it sits
            // between the final word and the end-of-day card.
            let curiositySlot = curiosityInStack ? 1 : 0
            if dailySetActive && queue.count + curiositySlot <= 2 {
                doneCard(depth: queue.count + curiositySlot)
            }
            if curiosityInStack, let curiosity {
                curiosityCard(curiosity, depth: queue.count, cardWidth: size.width)
            }
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
                    .overlay(alignment: .bottom) { swipeHintLabel }
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
                Text(PartOfSpeechLabel.localized(word.partOfSpeech))
                    .font(.sniglet(.subheadline))
                    .foregroundStyle(.secondary)
                Text(LocaleService.definition(for: word))
                    .font(.sniglet(.title3))
                    .padding(.top, 2)
            }

            InkDivider()

            // fixedSize so the sentence wraps instead of being squeezed to one
            // truncated line by the card's capped height — the Spacer below
            // gives way first.
            VStack(alignment: .leading, spacing: 6) {
                Text(word.exampleSentence)
                    .font(.sniglet(.title3))
                    .italic()
                    .fixedSize(horizontal: false, vertical: true)
                if let translation = LocaleService.exampleTranslation(for: word) {
                    Text(translation)
                        .font(.sniglet(.title3))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .layoutPriority(1)

            Spacer()

            HStack(spacing: 20) {
                Spacer()

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

                // Replay the example on demand. Independent of the mute toggle
                // beside it — an explicit tap always speaks, even when auto-play is
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

                // Voice speed (Pro; free learners get the paywall). A pick
                // replays the sentence at the new speed.
                VoiceSpeedMenu(source: "card", onChange: { _ in
                    if !soundEnabled { soundEnabled = true }
                    SpeechService.shared.speak(word.exampleSentence)
                }, onLocked: {
                    isShowingSpeedPaywall = true
                }) {
                    // Outline symbol: a heavier weight sits level with the
                    // filled play and speaker glyphs beside it.
                    Image(systemName: "speedometer")
                        .font(.system(.title3, weight: .semibold))
                        .foregroundStyle(DS.Color.ink)
                        .frame(width: 56, height: 56)
                        .background(Circle().fill(DS.Color.ink.opacity(0.15)))
                }

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
                swipeHintDirection = nil
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
        // use a short easeOut so the card leaves briskly but still visibly
        // glides. A hard flick shaves the duration so fast swipes feel snappy.
        let exitDuration = flickSpeed > 320 ? 0.18 : 0.26
        let exitX = direction * (cardWidth * 1.15 + 80)
        withAnimation(.easeOut(duration: exitDuration)) {
            dragOffset = CGSize(width: exitX, height: 0)
        }

        // Icon pops slightly bigger then shrinks out.
        withAnimation(.spring(response: 0.18, dampingFraction: 0.55)) {
            releaseProgress = 1.3
        }
        withAnimation(.easeIn(duration: 0.28).delay(0.08)) {
            releaseProgress = 0
        }

        // Swap in the next card only once the current one has cleared the
        // screen, so the flown-off card is offscreen when it's removed.
        DispatchQueue.main.asyncAfter(deadline: .now() + exitDuration + 0.02) {
            // Save the review only now: the save makes every @Query refetch
            // the whole vocabulary, and doing that as the card took off froze
            // it mid-flight. Here it lands before the next card starts moving.
            record(rating: rating, for: word)

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
                        if bonusTheme != nil {
                            completeBonusStack()
                        } else if curiosity == nil {
                            completeSet()
                            shouldCall = true
                        }
                        // Otherwise the curiosity card is now in front; the
                        // set completes once it's swiped away.
                    }
                } else {
                    refillQueue()
                }
            }
            if shouldCall { triggerSetCompleteCall() }
            // Bring the end-of-day card in now that the last card has cleared.
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
        ReviewPromptManager.noteCardReviewed()
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

    /// Swap in the active language's daily-set loop state if the global keys
    /// still describe another language. `SeedDataLoader.switchLanguage`
    /// normally does this first; this catches anything that changed the
    /// language without it. No-op while staying on the same language.
    private func syncDailySetLanguage() {
        guard dailySetStateLanguage != targetLanguageRaw else { return }
        DailySetState.activate(targetLanguageRaw)
        isSetComplete = false
        curiosity = nil
    }

    /// The word the card stack is currently showing, or nil when no readable
    /// card is on screen. Mirrors the branch chain in `body`: the end-of-day,
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
        let code = (TargetLanguage(rawValue: targetLanguageRaw) ?? .spanish).languageCode
        return customWords.contains { $0.languageCode == code }
    }

    private var themedDecks: [Deck] {
        DailyThemePath.themes(decks, includeMyWords: hasCustomWords)
    }

    /// Theme whose set the user is on today (or will start next).
    private var currentTheme: Deck? {
        DailyThemePath.theme(themedDecks, at: dailyThemeIndex)
    }

    /// Theme the user just finished — `dailyThemeIndex` already points past it
    /// once a set completes, so the completed one is the previous index.
    private var justCompletedTheme: Deck? {
        DailyThemePath.theme(themedDecks, at: dailyThemeIndex - 1)
    }

    /// `allWords` scoped to the active language. Custom words from other
    /// languages survive language switches, so the raw query is no longer
    /// single-language — every word-pool read goes through this.
    private var currentWords: [VocabularyWord] {
        allWords.scoped(to: (TargetLanguage(rawValue: targetLanguageRaw) ?? .spanish).languageCode)
    }

    /// Build the frozen daily set. On a revision day it's a random shuffle of
    /// words the user is still learning (any theme); otherwise it's a themed
    /// set drawn from today's theme — due reviews first, then new words by
    /// frequency rank — mixed with verbs, describers and building blocks
    /// (prepositions, connectors). Capped at `dailySetTarget`.
    private func buildDailySet() {
        if shouldBuildRevisionToday() {
            lastSetWasRevision = true
            buildRevisionSet()
            return
        }
        lastSetWasRevision = false

        guard let theme = currentTheme else { queue = []; return }
        buildThemedSet(theme)
    }

    /// A themed set drawn from `theme` — today's theme for the daily set, or
    /// the deck a Pro user picked for a bonus stack.
    private func buildThemedSet(_ theme: Deck) {
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
        // are scoped to this theme too (other themes' due words wait for their
        // own day or a revision day); the mixed slots below add the topic-less
        // ones, which have no theme day of their own.
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

        // Word-class mix. Topic decks are 60–90% nouns, and the most useful
        // verbs and adjectives (ser, tener, ir, bueno, grande) sit in no topic
        // at all — so a set drawn purely from the theme was a list of things.
        // Each set now reserves roughly a quarter each for building blocks,
        // verbs and describers (adjectives/adverbs). Verb and describer slots
        // split between the theme (cocinar on Food day) and the most frequent
        // topic-less words (tener, bueno), which have no theme day and would
        // otherwise never come up; either side tops up the other when short.
        // The rest stays on the theme, nouns first. An unfillable slot falls
        // back to the theme.
        let target = DailySetConfig.clamp(dailySetTarget)
        let slots = Self.mixSlots(for: target)
        let blocks = buildingBlocks(limit: slots, progressByID: progressByID, now: now, level: level)
        var seen = Set(blocks.map(\.id))

        let general = currentWords.filter { !$0.id.hasPrefix("custom-") && !$0.deckSlugs.contains(DeckConstants.buildingBlocksSlug) }
        func classSlot(_ wordClass: WordClass) -> [VocabularyWord] {
            let generalDue = general
                .filter { WordClass($0) == wordClass && !Self.hasTopic($0) }
                .compactMap { word -> (VocabularyWord, Date)? in
                    guard let progress = progressByID[word.id], progress.dueDate <= now else { return nil }
                    return (word, progress.dueDate)
                }
                .sorted { $0.1 < $1.1 }
                .map(\.0)
            // Topic-less words first: a themed word gets its own theme's day.
            let generalNew = LevelAnchor.anchored(
                general
                    .filter { WordClass($0) == wordClass && progressByID[$0.id] == nil }
                    .sorted { (Self.hasTopic($0) ? 1 : 0, $0.rank) < (Self.hasTopic($1) ? 1 : 0, $1.rank) },
                to: level
            )
            let themeSide = (dueReviews + themeNew).filter { WordClass($0) == wordClass }
            let generalSide = generalDue + generalNew
            var picked: [VocabularyWord] = []
            func take(from pool: [VocabularyWord], upTo limit: Int) {
                for word in pool {
                    guard picked.count < limit else { break }
                    guard seen.insert(word.id).inserted else { continue }
                    picked.append(word)
                }
            }
            // The general side gets the larger half: it's the gap.
            take(from: generalSide, upTo: (slots + 1) / 2)
            take(from: themeSide, upTo: slots)
            take(from: generalSide, upTo: slots)
            return picked
        }
        let verbs = classSlot(.verb)
        let describers = classSlot(.describer)

        let themeTarget = target - blocks.count - verbs.count - describers.count
        var themed: [VocabularyWord] = []
        let themePool = dueReviews + themeNew
        for word in themePool.filter({ WordClass($0) == .noun }) + themePool {
            guard themed.count < themeTarget else { break }
            guard seen.insert(word.id).inserted else { continue }
            themed.append(word)
        }

        // Backfill when new + due can't fill the set on its own — without this
        // a set could dead-end short of the climax call. Stays *within the
        // theme* (category-only), relaxing only the level anchor as a last
        // resort: any remaining theme word by frequency rank, including ones
        // the user has already seen. If the theme is too small to reach the
        // target the set is simply shorter — it still ends with Walter's call.
        if themed.count < themeTarget {
            let backfill = currentWords
                .filter { !$0.id.hasPrefix("custom-") && $0.deckSlugs.contains(theme.slug) }
                .sorted { $0.rank < $1.rank }
            for word in backfill {
                guard themed.count < themeTarget else { break }
                guard seen.insert(word.id).inserted else { continue }
                themed.append(word)
            }
        }
        queue = Self.weave([themed, verbs, describers, blocks])
    }

    /// Coarse word class for the set mix, from the seed's `partOfSpeech`
    /// ("noun (fem.)", "adverb/adjective", …) — the leading tag wins.
    private enum WordClass {
        case noun, verb, describer, other

        init(_ word: VocabularyWord) {
            let pos = word.partOfSpeech.lowercased()
            if pos.hasPrefix("verb") { self = .verb }
            else if pos.hasPrefix("adjective") || pos.hasPrefix("adverb") { self = .describer }
            else if pos.hasPrefix("noun") { self = .noun }
            else { self = .other }
        }
    }

    /// Whether a word belongs to any topic deck (beyond the hidden tags).
    private static func hasTopic(_ word: VocabularyWord) -> Bool {
        word.deckSlugs.contains { $0 != DeckConstants.commonSlug && $0 != DeckConstants.buildingBlocksSlug }
    }

    /// Slots per mixed class (building blocks, verbs, describers) in a themed
    /// set: roughly a quarter each — 2 apiece in the default set of 8.
    private static func mixSlots(for target: Int) -> Int {
        max(1, target / 4)
    }

    /// Prepositions, connectors and time/place/quantity words for today's set
    /// — the words that make a sentence out of a theme's nouns ("con", "hacia",
    /// "porque"), which no topic deck holds. Due reviews first, so they stay in
    /// rotation; then new ones in the hand-authored teaching order (con, para,
    /// porque before según), level-anchored like any new-word pick.
    private func buildingBlocks(limit: Int, progressByID: [String: LearningProgress], now: Date, level: CEFRLevel) -> [VocabularyWord] {
        let pool = currentWords.filter { $0.deckSlugs.contains(DeckConstants.buildingBlocksSlug) }
        let due = pool
            .compactMap { word -> (VocabularyWord, Date)? in
                guard let progress = progressByID[word.id], progress.dueDate <= now else { return nil }
                return (word, progress.dueDate)
            }
            .sorted { $0.1 < $1.1 }
            .map(\.0)
        let order = BuildingBlockOrder.positions(for: TargetLanguage(rawValue: targetLanguageRaw) ?? .spanish)
        let fresh = LevelAnchor.anchored(
            pool
                .filter { progressByID[$0.id] == nil }
                .sorted { (order[$0.id] ?? Int.max, $0.rank) < (order[$1.id] ?? Int.max, $1.rank) },
            to: level
        )
        return Array((due + fresh).prefix(limit))
    }

    /// Round-robin the set's groups (theme, verbs, describers, building
    /// blocks) so they alternate instead of arriving in clumps.
    private static func weave(_ groups: [[VocabularyWord]]) -> [VocabularyWord] {
        var result: [VocabularyWord] = []
        for i in 0..<(groups.map(\.count).max() ?? 0) {
            for group in groups where i < group.count {
                result.append(group[i])
            }
        }
        return result
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

    private var currentLanguage: TargetLanguage {
        TargetLanguage(rawValue: targetLanguageRaw) ?? .spanish
    }

    /// Start an extra stack from `deck` after the daily set is done (Pro). The
    /// daily set's lock and theme position are untouched, so tomorrow's theme
    /// still comes up as planned.
    private func startBonusStack(_ deck: Deck) {
        bonusTheme = deck
        buildThemedSet(deck)
        guard !queue.isEmpty else { return }   // nothing to draw: stay on the done card
        Analytics.capture(.bonusStackStarted, ["deck": deck.slug])
        // `setStarted` skips the intro card; with it set, the front-card
        // change speaks the first example, as mid-set.
        setStarted = true
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
            isSetComplete = false
        }
    }

    private func completeBonusStack() {
        if let deck = bonusTheme {
            Analytics.capture(.bonusStackCompleted, ["deck": deck.slug])
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
        dealCuriosityIfDue()
        guard soundEnabled, let word = queue.first else { return }
        SpeechService.shared.speak(word.exampleSentence)
    }

    /// Deal today's curiosity (if one is due) in under the last words, so it
    /// peeks out behind them before becoming the set's final card. Daily
    /// themed sets only: not revision days, not bonus stacks.
    private func dealCuriosityIfDue() {
        guard dailySetActive, setStarted, !isSetComplete, bonusTheme == nil,
              !lastSetWasRevision, curiosity == nil,
              !queue.isEmpty, queue.count <= 2
        else { return }
        let picked = CuriosityService.pickForToday(language: currentLanguage)
        withAnimation(.spring(response: 0.5, dampingFraction: 0.82)) {
            curiosity = picked
        }
    }

    /// Nudge the front card left, then right, naming each direction, to show
    /// it's swipeable and which way is which. Fires a beat after the set
    /// starts and repeats while the user stays idle, stopping the moment they
    /// touch the card or the cap is hit.
    ///
    /// "Know it" goes first and both sides are labelled: through 1.1.9 the
    /// hint only nudged right — the "still learning" side — and new users
    /// rated around 80% of cards "again".
    private func scheduleSwipeHint(after delay: Double) {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            guard isIdleForSwipeHint, swipeHintsShown < maxSwipeHints else { return }
            swipeHintsShown += 1
            guard await nudgeCard(.good) else { return }
            try? await Task.sleep(for: .seconds(0.3))
            guard await nudgeCard(.again) else { return }
            scheduleSwipeHint(after: 3.2)
        }
    }

    /// One half of the hint: slide the card toward `rating`'s side with its
    /// label showing, hold so the label can be read, then settle back.
    /// Returns false if the user took over or the set moved on.
    private func nudgeCard(_ rating: ReviewRating) async -> Bool {
        guard isIdleForSwipeHint else { return false }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
            swipeHintDirection = rating
            dragOffset = CGSize(width: rating == .good ? -swipeHintDistance : swipeHintDistance, height: 0)
        }
        try? await Task.sleep(for: .seconds(0.9))
        // A finger on the card owns `dragOffset` now — leave it alone.
        guard !didInteractWithCard, !isAnimatingOut else { return false }
        withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
            swipeHintDirection = nil
            dragOffset = .zero
        }
        try? await Task.sleep(for: .seconds(0.4))
        return true
    }

    private var isIdleForSwipeHint: Bool {
        !didInteractWithCard
            && !isAnimatingOut
            && dragOffset == .zero
            && !isSetComplete
            && queue.first != nil
            && !(dailySetActive && !setStarted)
    }

    /// Pill on the front card while the hint nudges it,
    /// pointing the way the card is moving.
    @ViewBuilder
    private var swipeHintLabel: some View {
        if let direction = swipeHintDirection {
            HStack(spacing: 6) {
                if direction == .good {
                    Image(systemName: "arrow.left")
                    Text("Know it")
                } else {
                    Text("Still learning")
                    Image(systemName: "arrow.right")
                }
            }
            .font(.sniglet(.headline, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Capsule().fill(direction == .good ? SwiftUI.Color.green : DS.Color.ink))
            // Clear of the play/mute row (24 card padding + 56 buttons) so it
            // sits in the gap under the example and never covers the word.
            .padding(.bottom, 96)
            .transition(.opacity.combined(with: .scale(scale: 0.9)))
            .allowsHitTesting(false)
        }
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
            // Dr Tusk holding a hand of cards. The art is square with
            // margin around him, hence the wider frame than the old cut-out.
            Image("cards")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 210)
                .accessibilityHidden(true)

            VStack(spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: lastSetWasRevision ? "arrow.triangle.2.circlepath" : (currentTheme?.iconSystemName ?? "square.stack"))
                    Text(lastSetWasRevision ? String(localized: "Revision") : (currentTheme?.localizedName ?? String(localized: "Today's Set")))
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
                } else if let desc = currentTheme?.localizedDescription, !desc.isEmpty {
                    Text(desc)
                        .font(.sniglet(.callout))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                Text("\(count) words · ~\(minutes) min · ends with a call from Dr Tusk")
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

    /// The day's last card, at `depth` in the stack (0 = front). Rides at the
    /// bottom of the deck while words remain; at the front it can't be swiped
    /// away — it tugs and springs back. Offers another stack, plus a review
    /// request until the user has opened the review page, then sharing.
    private func doneCard(depth: Int) -> some View {
        let effectiveDepth = max(0, CGFloat(depth) - dragProgress)
        let isFront = depth == 0
        // `dailyThemeIndex` advances when the set completes, so before that
        // the theme being finished is still `currentTheme`.
        let theme = bonusTheme ?? (isSetComplete ? justCompletedTheme : currentTheme)
        return VStack(alignment: .leading, spacing: 14) {
            // Dr Tusk with his hand of cards heads the card. On its own the
            // card hugs its content, like the intro card; under word cards it
            // fills the deck's height, so the image takes up the slack.
            Image("cards")
                .resizable()
                .scaledToFit()
                .frame(maxWidth: 190, maxHeight: showsDoneCardAlone ? 190 : .infinity)
                .frame(maxWidth: .infinity)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 6) {
                Text("Set complete!")
                    .font(.gochiHand(size: 30))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .foregroundStyle(Color.whiteboardInk)
                if let bonus = bonusTheme {
                    Text("You finished a bonus \(bonus.localizedName) stack.")
                        .font(.sniglet(.title3))
                } else if lastSetWasRevision {
                    Text("You finished today's revision set.")
                        .font(.sniglet(.title3))
                } else if let done = theme {
                    Text("You finished today's \(done.localizedName) set.")
                        .font(.sniglet(.title3))
                }
                Text("Tomorrow brings a new theme.")
                    .font(.sniglet(.callout))
                    .foregroundStyle(.secondary)
            }
            // Let the copy wrap at full height; the image gives way instead.
            .fixedSize(horizontal: false, vertical: true)

            InkDivider()

            if !didOpenWriteReview {
                Text("Enjoying Wordrus? A quick review helps other learners find it.")
                    .font(.sniglet(.callout))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 12) {
                // Keep swiping: free for Pro (and trial), the paywall otherwise.
                Button {
                    playLightHaptic()
                    if entitlements.isPro {
                        isShowingAnotherStack = true
                    } else {
                        isShowingStackPaywall = true
                    }
                } label: {
                    Label("Start another stack", systemImage: "square.stack.3d.up.fill")
                }
                .buttonStyle(.primary)

                // One secondary action: ask for a review until they've opened
                // the review page, then offer sharing instead.
                if !didOpenWriteReview {
                    Button {
                        playLightHaptic()
                        didOpenWriteReview = true
                        openURL(AppStoreLinks.writeReviewURL)
                    } label: {
                        secondaryCapsuleLabel("Leave a Review", systemImage: "star.fill")
                    }
                    .buttonStyle(.plain)
                } else {
                    ShareLink(item: AppStoreLinks.productURL,
                              message: Text("I've been learning words with Wordrus — thought you might like it too.")) {
                        secondaryCapsuleLabel("Share with a friend", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 30)
        .padding(.vertical, 24)
        .frame(maxWidth: .infinity, maxHeight: showsDoneCardAlone ? nil : 520, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(.background)
                .shadow(color: .black.opacity(0.12), radius: 16, y: 6)
        )
        .scaleEffect(1.0 - 0.05 * effectiveDepth)
        .offset(x: isFront ? doneCardDrag : 0, y: 18 * effectiveDepth)
        .rotationEffect(.degrees(isFront ? Double(doneCardDrag / 20) : 0))
        .gesture(
            DragGesture()
                .onChanged { value in
                    // Rubber band: follows the finger at first, then stiffens
                    // towards a ~60pt ceiling so it never looks swipeable.
                    let x = value.translation.width
                    doneCardDrag = x / (1 + abs(x) / 60)
                }
                .onEnded { _ in
                    playLightHaptic()
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.55)) {
                        doneCardDrag = 0
                    }
                }
        )
        .allowsHitTesting(isFront)
        .id("doneCard")
        .transition(
            .asymmetric(
                insertion: .opacity.combined(with: .scale(scale: 0.88, anchor: .bottom)),
                removal: .identity
            )
        )
    }

    /// The curiosity card at `depth` in the stack (0 = front). Behind the
    /// words it eases forward as they're dragged away, like the upcoming
    /// cards; at the front any swipe past the threshold flies it off —
    /// there's nothing to rate — and the set completes.
    private func curiosityCard(_ item: Curiosity, depth: Int, cardWidth: CGFloat) -> some View {
        let isFront = depth == 0
        let effectiveDepth = isFront ? 0 : CGFloat(depth) - dragProgress
        return CuriosityCard(curiosity: item, language: currentLanguage)
            .scaleEffect(1.0 - 0.05 * effectiveDepth)
            .offset(x: isFront ? curiosityDrag : 0, y: 18 * effectiveDepth)
            .rotationEffect(.degrees(isFront ? Double(curiosityDrag / 20) : 0))
            .gesture(
                DragGesture()
                    .onChanged { value in
                        curiosityDrag = value.translation.width
                    }
                    .onEnded { value in
                        let translation = value.translation.width
                        let projected = value.predictedEndTranslation.width
                        if abs(translation) > swipeThreshold || abs(projected) > swipeThreshold * 1.5 {
                            dismissCuriosity(direction: translation < 0 ? -1 : 1, cardWidth: cardWidth)
                        } else {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
                                curiosityDrag = 0
                            }
                        }
                    }
            )
            .allowsHitTesting(isFront)
            .id(item.id)
            .transition(
                .asymmetric(
                    insertion: .opacity.combined(with: .scale(scale: 0.88, anchor: .bottom)),
                    removal: .identity
                )
            )
    }

    /// Fly the curiosity card off, then finish the set exactly as the last
    /// word's swipe would have: complete it and let Dr Tusk ring.
    private func dismissCuriosity(direction: CGFloat, cardWidth: CGFloat) {
        guard let item = curiosity else { return }
        playLightHaptic()
        withAnimation(.easeOut(duration: 0.26)) {
            curiosityDrag = direction * (cardWidth * 1.15 + 80)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) {
            CuriosityService.dismiss(item)
            var instant = Transaction()
            instant.disablesAnimations = true
            withTransaction(instant) { curiosityDrag = 0 }
            withAnimation(.spring(response: 0.5, dampingFraction: 0.82)) {
                curiosity = nil
                completeSet()
            }
            triggerSetCompleteCall()
        }
    }

    private func secondaryCapsuleLabel(_ title: LocalizedStringKey, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.sniglet(.body, weight: .bold))
            .foregroundStyle(DS.Color.ink)
            .frame(maxWidth: .infinity, minHeight: DS.Size.buttonMinHeight)
            .background(Capsule(style: .continuous).fill(DS.Color.ink.opacity(0.12)))
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
