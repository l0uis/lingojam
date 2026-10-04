import SwiftUI
import SwiftData
import StoreKit

private enum AppTab: Hashable { case myWords, jam, phone }

struct RootView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.requestReview) private var requestReview
    @Query private var allWords: [VocabularyWord]
    @Query private var allProgress: [LearningProgress]
    @Query private var allStories: [DailyStory]
    @AppStorage(OnboardingDefaultsKey.targetLanguage) private var targetLanguageRaw: String = TargetLanguage.spanish.rawValue
    @State private var entitlements = Entitlements.shared

    @State private var selection: AppTab = .jam
    /// Mirrors JamView's completion lock so the Deck tab icon can switch
    /// between a full and empty tray as the day's set is finished.
    @AppStorage(DailySetConfig.lastCompletedDayKey) private var dailySetLastCompletedDay: String = ""
    @AppStorage(OnboardingDefaultsKey.hasCompleted) private var hasCompletedOnboarding: Bool = false
    @State private var isShowingOnboarding: Bool = false
    @State private var coordinator = IncomingCallCoordinator.shared
    @State private var deepLink = DeepLinkCoordinator.shared
    /// The word to show in an overlapping sheet after the user taps a widget,
    /// Live Activity, or reminder notification. Presented over whatever tab
    /// they land on.
    @State private var deepLinkedWord: VocabularyWord?
    /// A story opened from its "new story" notification.
    @State private var deepLinkedStory: DailyStory?
    @State private var chatTargetWords: [VocabularyWord] = []
    /// Set when the current call retells a story (`CallSeed`).
    @State private var chatStoryContext: String?
    @State private var isPresentingChat: Bool = false
    @State private var chatIsIncoming: Bool = false
    @State private var isPresentingOutgoingRinger: Bool = false
    @State private var pendingResult: ChatEvaluation?
    /// Bumped whenever the user re-taps the Vocabulary tab while already
    /// on it — `MyWordsView` reads this to scroll its list back to the top.
    @State private var vocabularyScrollToTopSignal: Int = 0

    /// Custom binding around `selection` that detects when the user taps
    /// the already-selected tab and bumps the matching scroll-to-top signal.
    private var tabSelection: Binding<AppTab> {
        Binding(
            get: { selection },
            set: { newValue in
                if newValue == selection {
                    if newValue == .myWords { vocabularyScrollToTopSignal &+= 1 }
                }
                selection = newValue
            }
        )
    }

    var body: some View {
        ZStack {
            TabView(selection: tabSelection) {
                // Top bar per tab: flag (leading) is supplied by each view's
                // own deckLanguageToolbar. Trailing differs by tab — add on
                // Vocabulary, streak on Jam, settings on Phone — so each tab
                // shows exactly one trailing action.
                Tab("Words", systemImage: "text.book.closed", value: AppTab.myWords) {
                    NavigationStack {
                        // Trailing + (add a word) lives in MyWordsView.
                        MyWordsView(scrollToTopSignal: vocabularyScrollToTopSignal)
                    }
                }
                Tab("Deck", systemImage: deckTabIcon, value: AppTab.jam) {
                    NavigationStack {
                        JamView()
                            .streakToolbar()
                    }
                }
                Tab("Phone", systemImage: "phone.fill", value: AppTab.phone) {
                    NavigationStack {
                        PhoneView()
                            .settingsToolbar(placement: .topBarTrailing, onRestartOnboarding: presentOnboarding)
                    }
                }
                // New stories from Dr Tusk wait here like unread messages.
                .badge(StoryBadge.unreadCount(stories: allStories, languageRaw: targetLanguageRaw, isPro: entitlements.isPro))
            }
            .tabViewStyle(.sidebarAdaptable)
            .tint(DS.Color.ink)

            // Call screens presented as overlays (not sheets) so we can
            // animate them with an iOS-call-style scale + opacity rather
            // than the default sheet slide-up. `CallBackdrop` provides
            // its own ultra-thin-material layer to blur whatever app UI
            // is sitting behind.
            if coordinator.isPresentingIncoming {
                CallIncomingView(
                    onAnswer: {
                        chatTargetWords = pickTargetWords()
                        chatStoryContext = nil
                        chatIsIncoming = true
                        withAnimation(Self.callTransitionAnimation) {
                            coordinator.isPresentingIncoming = false
                        }
                        isPresentingChat = true
                    },
                    onDecline: {
                        ChatStore.recordTerminalSession(
                            context: context,
                            status: .declined,
                            wasIncoming: true
                        )
                        withAnimation(Self.callTransitionAnimation) {
                            coordinator.isPresentingIncoming = false
                        }
                    }
                )
                .transition(Self.callTransition)
                .zIndex(100)
            }

            if isPresentingOutgoingRinger {
                CallOutgoingView(
                    onAnswered: {
                        withAnimation(Self.callTransitionAnimation) {
                            isPresentingOutgoingRinger = false
                        }
                        isPresentingChat = true
                    },
                    onCancel: {
                        withAnimation(Self.callTransitionAnimation) {
                            isPresentingOutgoingRinger = false
                        }
                    }
                )
                .transition(Self.callTransition)
                .zIndex(101)
            }
        }
        .animation(Self.callTransitionAnimation, value: coordinator.isPresentingIncoming)
        .animation(Self.callTransitionAnimation, value: isPresentingOutgoingRinger)
        .onAppear {
            if !hasCompletedOnboarding { isShowingOnboarding = true }
        }
        .task {
            // Restore any user-added words backed up to the proxy — recovers
            // them after an app delete/reinstall.
            await CustomWordSync.restore(context: context)
        }
        .onChange(of: scenePhase) { _, phase in
            // On the way to the background, snapshot custom words (with the
            // session's review changes) to the backup so Known/Learning state
            // is preserved across a reinstall.
            if phase == .background {
                Task { await CustomWordSync.pushAll(context: context) }
                // Queue the next on-device rotation while we're backgrounded.
                LiveActivityService.scheduleNextRefresh()
                // And tomorrow's story.
                StoryScheduler.scheduleNextRefresh()
            } else if phase == .active {
                // Snap the Live Activity to the word for the current time.
                LiveActivityService.refresh()
                // A new day may have started while we were away.
                Task { await StoryScheduler.prepareTodayStory(context: context) }
            }
        }
        .fullScreenCover(isPresented: $isShowingOnboarding, onDismiss: {
            // Ask for the rating once onboarding is behind them, so the
            // system prompt lands over the deck rather than on a screen of
            // its own. Delayed a beat to let the cover finish dismissing.
            Analytics.capture(.onboardingCompleted)
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(900))
                Analytics.reviewPromptRequested(.afterOnboarding)
                requestReview()
            }
        }) {
            OnboardingFlow()
                .interactiveDismissDisabled()
        }
        .onChange(of: coordinator.isPresentingOutgoing) { _, isOn in
            // Outgoing calls show a brief ringing screen, then auto-answer.
            guard isOn else { return }
            if let seed = coordinator.pendingSeed {
                let ids = Set(seed.wordIDs)
                chatTargetWords = allWords.filter { ids.contains($0.id) }
                chatStoryContext = seed.storyContext
                coordinator.pendingSeed = nil
            } else {
                chatTargetWords = pickTargetWords()
                chatStoryContext = nil
            }
            chatIsIncoming = false
            coordinator.isPresentingOutgoing = false
            withAnimation(Self.callTransitionAnimation) {
                isPresentingOutgoingRinger = true
            }
        }
        .fullScreenCover(isPresented: $isPresentingChat, onDismiss: {
            // After the chat closes, surface the result sheet if the call
            // produced an evaluation (skipped when the user dismisses
            // before any evaluation is set).
            if pendingResult != nil {
                // SwiftUI needs a tick to settle the dismissal before we
                // can present a new sheet; nudging via a 0-second task is
                // enough.
                Task { @MainActor in
                    // No-op: the `.sheet(item:)` below already reacts to
                    // `pendingResult` becoming non-nil.
                }
            }
        }) {
            VoiceCallView(
                level: OnboardingStore.cefrLevel,
                targetWords: chatTargetWords,
                context: context,
                wasIncoming: chatIsIncoming,
                storyContext: chatStoryContext,
                onFinished: { eval in
                    pendingResult = eval
                    isPresentingChat = false
                }
            )
        }
        .sheet(item: $pendingResult) { eval in
            CallResultSheet(
                evaluation: eval,
                // The words actually set for this call. It used to read
                // `promptTurnCount`, which is Walter's *turn* budget — so a
                // call with 2 target words reported "2 of 5 words used" and
                // credited the learner with missing three that never existed.
                targetWordCount: chatTargetWords.count,
                onDismiss: { pendingResult = nil }
            )
        }
        .sheet(item: $deepLinkedWord) { word in
            DeepLinkWordSheet(word: word)
        }
        .sheet(item: $deepLinkedStory) { story in
            StoryView(story: story)
        }
        .onChange(of: deepLink.pendingStoryID, initial: true) { _, id in
            guard let id else { return }
            deepLink.pendingStoryID = nil
            // Stories are Pro; a lapsed subscriber tapping an old notification
            // lands on the Phone tab's locked row instead.
            guard Entitlements.shared.isPro else { return }
            deepLinkedStory = DailyStoryService.story(context: context, id: id)
        }
        // `initial: true` covers a cold launch where the deep link is already
        // armed before the first render; later changes cover taps while the
        // app is backgrounded or foreground.
        .onChange(of: deepLink.pendingWordID, initial: true) { _, _ in
            presentDeepLinkedWordIfNeeded()
        }
    }

    /// Consume a pending word deep link and present it as an overlapping
    /// sheet. Clears the request immediately so the same tap never
    /// re-presents; silently drops ids that no longer resolve to a word.
    private func presentDeepLinkedWordIfNeeded() {
        guard let id = deepLink.pendingWordID else { return }
        deepLink.pendingWordID = nil
        // The Deck is already showing this exact card, so the tap has nothing
        // left to reveal — a sheet on top would just duplicate the word the
        // user is looking at. Both conditions matter: the card can only be on
        // screen while the Deck tab is the selected one.
        if selection == .jam, id == deepLink.visibleWordID { return }
        let descriptor = FetchDescriptor<VocabularyWord>(
            predicate: #Predicate { $0.id == id }
        )
        guard let word = try? context.fetch(descriptor).first else { return }
        // Replace any word already showing so a fresh tap always wins.
        deepLinkedWord = word
    }

    /// Full tray while today's set still has words to review, empty tray once
    /// it's been finished for the day.
    private var deckTabIcon: String {
        DailySetConfig.isDoneToday(lastCompletedDay: dailySetLastCompletedDay) ? "tray" : "tray.full"
    }

    private func pickTargetWords() -> [VocabularyWord] {
        // Scope to the active language: custom words from other languages
        // persist across switches and must not become call targets.
        let languageCode = (OnboardingStore.targetLanguage ?? .spanish).languageCode
        return ChatStore.pickTargetWords(
            from: allWords.scoped(to: languageCode),
            progress: allProgress,
            level: OnboardingStore.cefrLevel
        )
    }

    private func presentOnboarding() {
        OnboardingStore.reset()
        isShowingOnboarding = true
    }

    /// Pure cross-fade for the call screens — mimics the iOS incoming
    /// call effect where the existing UI blurs out smoothly. Earlier
    /// versions used a scale transition, but the safe-area insets
    /// briefly flashed white at mid-scale because the backdrop hadn't
    /// fully extended yet. Opacity-only avoids that entirely.
    private static let callTransition: AnyTransition = .opacity
    private static let callTransitionAnimation: Animation = .easeInOut(duration: 0.38)
}

#Preview {
    RootView()
        .modelContainer(for: [VocabularyWord.self, LearningProgress.self, ReviewLog.self], inMemory: true)
}
