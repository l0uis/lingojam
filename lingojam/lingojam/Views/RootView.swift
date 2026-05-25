import SwiftUI
import SwiftData

private enum AppTab: Hashable { case myWords, jam, phone }

struct RootView: View {
    @Environment(\.modelContext) private var context
    @Query private var allWords: [VocabularyWord]
    @Query private var allProgress: [LearningProgress]

    @State private var selection: AppTab = .jam
    @AppStorage(OnboardingDefaultsKey.hasCompleted) private var hasCompletedOnboarding: Bool = false
    @State private var isShowingOnboarding: Bool = false
    @State private var coordinator = IncomingCallCoordinator.shared
    @State private var chatTargetWords: [VocabularyWord] = []
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
        TabView(selection: tabSelection) {
            Tab("Vocabulary", systemImage: "text.book.closed", value: AppTab.myWords) {
                NavigationStack {
                    MyWordsView(scrollToTopSignal: vocabularyScrollToTopSignal)
                        .settingsToolbar(onRestartOnboarding: presentOnboarding)
                        .streakToolbar()
                }
            }
            Tab("Jam", systemImage: "waveform", value: AppTab.jam) {
                NavigationStack {
                    JamView()
                        .settingsToolbar(onRestartOnboarding: presentOnboarding)
                        .streakToolbar()
                }
            }
            Tab("Phone", systemImage: "phone.fill", value: AppTab.phone) {
                NavigationStack {
                    PhoneView()
                        .settingsToolbar(onRestartOnboarding: presentOnboarding)
                        .streakToolbar()
                }
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        .tint(DS.Color.ink)
        .onAppear {
            if !hasCompletedOnboarding { isShowingOnboarding = true }
        }
        .fullScreenCover(isPresented: $isShowingOnboarding) {
            OnboardingFlow()
                .interactiveDismissDisabled()
        }
        .fullScreenCover(isPresented: $coordinator.isPresentingIncoming) {
            CallIncomingView(
                onAnswer: {
                    chatTargetWords = pickTargetWords()
                    chatIsIncoming = true
                    coordinator.isPresentingIncoming = false
                    isPresentingChat = true
                },
                onDecline: {
                    ChatStore.recordTerminalSession(
                        context: context,
                        status: .declined,
                        wasIncoming: true
                    )
                    coordinator.isPresentingIncoming = false
                }
            )
            .presentationBackground(.ultraThinMaterial)
        }
        .onChange(of: coordinator.isPresentingOutgoing) { _, isOn in
            // Outgoing calls show a brief ringing screen, then auto-answer.
            guard isOn else { return }
            chatTargetWords = pickTargetWords()
            chatIsIncoming = false
            coordinator.isPresentingOutgoing = false
            isPresentingOutgoingRinger = true
        }
        .fullScreenCover(isPresented: $isPresentingOutgoingRinger) {
            CallOutgoingView(
                onAnswered: {
                    isPresentingOutgoingRinger = false
                    isPresentingChat = true
                },
                onCancel: {
                    isPresentingOutgoingRinger = false
                }
            )
            .presentationBackground(.ultraThinMaterial)
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
            NavigationStack {
                ChatView(
                    level: OnboardingStore.cefrLevel,
                    targetWords: chatTargetWords,
                    context: context,
                    wasIncoming: chatIsIncoming,
                    onFinished: { eval in
                        pendingResult = eval
                        isPresentingChat = false
                    }
                )
                .navigationBarHidden(true)
            }
        }
        .sheet(item: $pendingResult) { eval in
            CallResultSheet(
                evaluation: eval,
                targetWordCount: max(eval.elicitedWordIDs.count, MockWalrusBrain.promptTurnCount),
                onDismiss: { pendingResult = nil }
            )
        }
    }

    private func pickTargetWords() -> [VocabularyWord] {
        ChatStore.pickTargetWords(
            from: allWords,
            progress: allProgress,
            level: OnboardingStore.cefrLevel
        )
    }

    private func presentOnboarding() {
        OnboardingStore.reset()
        isShowingOnboarding = true
    }
}

#Preview {
    RootView()
        .modelContainer(for: [VocabularyWord.self, LearningProgress.self, ReviewLog.self], inMemory: true)
}
