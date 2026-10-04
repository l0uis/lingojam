import SwiftUI
import SwiftData

/// Phone tab — outgoing call entry point plus a recents-style list of
/// past chats, missed calls and Dr Tusk's stories.
struct PhoneView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \ChatSession.startedAt, order: .reverse) private var allSessions: [ChatSession]
    @AppStorage(OnboardingDefaultsKey.targetLanguage) private var targetLanguageRaw: String = TargetLanguage.spanish.rawValue
    @State private var selectedSession: ChatSession?
    @State private var entitlements = Entitlements.shared
    @State private var isShowingPaywall = false
    @Query(sort: \DailyStory.createdAt, order: .reverse) private var allStories: [DailyStory]
    @State private var openedStory: StoryDestination?
    @State private var isShowingStoryPaywall = false
    @AppStorage(OnboardingDefaultsKey.hasCompleted) private var hasCompletedOnboarding = false

    /// Calls practised in the currently selected language. Mirrors how the
    /// Vocabulary tab scopes to the active language.
    private var sessions: [ChatSession] {
        allSessions.filter { $0.languageRaw == targetLanguageRaw }
    }

    /// Stories are Pro: free users see `StoryLockedRow` instead.
    private var stories: [DailyStory] {
        guard entitlements.isPro else { return [] }
        return allStories.filter { $0.languageRaw == targetLanguageRaw }
    }

    private var recents: [RecentItem] {
        RecentItem.merged(calls: sessions, stories: stories)
    }

    /// Until today's story exists, a row that writes it on tap.
    private var showsTodayPlaceholder: Bool {
        let today = DailySetConfig.dayKey(.now)
        return entitlements.isPro && hasCompletedOnboarding && !stories.contains { $0.dayKey == today }
    }

    private var showsLockedStories: Bool {
        !entitlements.isPro && hasCompletedOnboarding
    }

    var body: some View {
        List {
            Section {
                callCard
                    .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }

            if recents.isEmpty && !showsTodayPlaceholder && !showsLockedStories {
                Section {
                    emptyHistory
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
            } else {
                Section {
                    if showsLockedStories {
                        Button { isShowingStoryPaywall = true } label: { StoryLockedRow() }
                            .buttonStyle(.plain)
                            .listRowSeparator(.hidden)
                    }
                    if showsTodayPlaceholder {
                        Button { openedStory = .today } label: { TodayStoryPlaceholderRow() }
                            .buttonStyle(.plain)
                            .listRowSeparator(.hidden)
                    }
                    ForEach(recents) { item in
                        switch item {
                        case .call(let session):
                            Button {
                                selectedSession = session
                            } label: {
                                CallHistoryRow(session: session)
                            }
                            .buttonStyle(.plain)
                            .listRowSeparator(.hidden)
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    delete(session)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        case .story(let story):
                            Button {
                                openedStory = .story(story)
                            } label: {
                                StoryRow(story: story)
                            }
                            .buttonStyle(.plain)
                            .listRowSeparator(.hidden)
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    delete(story)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                            #if DEBUG
                            .contextMenu {
                                Button(role: .destructive) { delete(story) } label: { Text(verbatim: "Regenerate (delete)") }
                                Button { story.openedAt = nil; story.completedAt = nil } label: { Text(verbatim: "Mark unread") }
                            }
                            #endif
                        }
                    }
                } header: {
                    Text("Recents").sectionHeaderStyle()
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(DS.Color.paper.ignoresSafeArea())
        .gochiHandNavigationTitle("Phone")
        .deckLanguageToolbar()
        .sheet(item: $selectedSession) { session in
            ConversationDetailSheet(
                session: session,
                onDelete: {
                    delete(session)
                    selectedSession = nil
                }
            )
        }
        .sheet(isPresented: $isShowingPaywall) {
            // Once subscribed, place the call the user originally tapped.
            PaywallView(onSubscribed: { IncomingCallCoordinator.shared.requestOutgoing() }, source: .call)
        }
        .sheet(isPresented: $isShowingStoryPaywall) {
            // Once subscribed, open today's story straight away.
            PaywallView(onSubscribed: { openedStory = .today }, source: .story)
        }
        .sheet(item: $openedStory) { destination in
            switch destination {
            case .today:
                TodayStoryScreen(language: TargetLanguage(rawValue: targetLanguageRaw) ?? .spanish)
            case .story(let story):
                StoryView(story: story)
            }
        }
    }

    private func delete(_ story: DailyStory) {
        if let folder = story.audioFileName {
            try? FileManager.default.removeItem(at: DailyStoryService.storyAudioDirectory.appendingPathComponent(folder))
        }
        StoryScheduler.cancelNotification(for: story)
        context.delete(story)
        try? context.save()
    }

    /// Calling Dr Tusk is a Pro feature — incoming calls stay free. Pro
    /// users place the call; everyone else sees the paywall first.
    private func callDrTusk() {
        if entitlements.isPro {
            IncomingCallCoordinator.shared.requestOutgoing()
        } else {
            isShowingPaywall = true
        }
    }

    private func delete(_ session: ChatSession) {
        // ChatSession.messages has deleteRule: .cascade, so cascading
        // deletion handles the transcript rows.
        context.delete(session)
        try? context.save()
    }

    // MARK: - Call card

    private var callCard: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(.white)
                    .frame(width: 120, height: 120)
                    .overlay(Circle().stroke(DS.Color.ink.opacity(0.12), lineWidth: 1))
                Image("walrus")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 110)
            }
            Text("Dr Tusk")
                .font(.gochiHand(size: 36, relativeTo: .title))
                .foregroundStyle(Color.whiteboardInk)
            Text("Tap to start a conversation in \((OnboardingStore.targetLanguage ?? .spanish).titleInSentence).")
                .font(.sniglet(.callout))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button {
                callDrTusk()
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: entitlements.isPro ? "phone.fill" : "lock.fill")
                    Text("Call Dr Tusk")
                }
            }
            .buttonStyle(.primary)
            .padding(.horizontal, 24)
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(.background)
                .shadow(color: .black.opacity(0.08), radius: 10, y: 4)
        )
        .padding(.horizontal, 16)
    }

    private var emptyHistory: some View {
        VStack(spacing: 8) {
            Image(systemName: "phone.down.fill")
                .font(.sniglet(size: 36))
                .foregroundStyle(.tertiary)
            Text("No calls yet")
                .font(.sniglet(.headline))
            Text("Tap **Call Dr Tusk** above to start your first conversation.")
                .font(.sniglet(.callout))
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }
}

/// What the story sheet shows: today's (written on demand) or a saved one.
private enum StoryDestination: Identifiable {
    case today
    case story(DailyStory)

    var id: String {
        switch self {
        case .today: "today"
        case .story(let story): story.id.uuidString
        }
    }
}

// MARK: - Row

private struct CallHistoryRow: View {
    let session: ChatSession

    var body: some View {
        HStack(spacing: 12) {
            statusIcon
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.sniglet(.headline))
                    .foregroundStyle(titleTint)
                Text(subtitle)
                    .font(.sniglet(.caption))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(session.startedAt, format: .relative(presentation: .named))
                .font(.sniglet(.caption))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private var statusIcon: some View {
        let (system, color) = iconConfig
        return Image(systemName: system)
            .font(.sniglet(.callout, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 36, height: 36)
            .background(Circle().fill(color))
    }

    private var iconConfig: (String, Color) {
        switch session.status {
        case .missed: ("phone.down.fill", .red)
        case .declined: ("phone.down.fill", .orange)
        case .hungUp: ("phone.arrow.down.left.fill", .secondary)
        case .abandoned: ("zzz", .purple)
        case .completed: session.passed
            ? ("phone.fill", .green)
            : ("phone.fill", .blue)
        }
    }

    private var title: LocalizedStringResource {
        switch session.status {
        case .missed: "Missed call"
        case .declined: "Declined"
        case .hungUp: "Hung up"
        case .abandoned: "Dr Tusk gave up"
        case .completed: session.passed ? "Conversation passed" : "Conversation"
        }
    }

    private var titleTint: Color {
        session.status == .missed ? .red : .primary
    }

    private var subtitle: LocalizedStringResource {
        let levelLabel = session.levelAtStart
        return session.wasIncoming ? "Incoming · \(levelLabel)" : "Outgoing · \(levelLabel)"
    }
}

// MARK: - Detail sheet

private struct ConversationDetailSheet: View {
    let session: ChatSession
    let onDelete: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    headerCard
                    if session.messages.isEmpty {
                        Text(emptyMessage)
                            .font(.sniglet(.callout))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)
                    } else {
                        ForEach(orderedMessages) { message in
                            messageBubble(message)
                        }
                    }
                }
                .padding(20)
            }
            .navigationTitle(navTitle)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(role: .destructive, action: onDelete) {
                        Image(systemName: "trash")
                    }
                    .tint(.red)
                    .accessibilityLabel("Delete conversation")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var orderedMessages: [ChatMessage] {
        session.messages.sorted { $0.timestamp < $1.timestamp }
    }

    private var navTitle: String {
        session.startedAt.formatted(date: .abbreviated, time: .shortened)
    }

    private var emptyMessage: LocalizedStringResource {
        switch session.status {
        case .missed: "You missed Dr Tusk's call."
        case .declined: "You declined this call."
        case .hungUp: "No transcript."
        case .abandoned: "Dr Tusk gave up waiting."
        case .completed: "No transcript."
        }
    }

    private var headerCard: some View {
        HStack(spacing: 12) {
            Image("walrus")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 44, height: 44)
                .background(Circle().fill(.background))
            VStack(alignment: .leading, spacing: 2) {
                Text("Dr Tusk · \(session.levelAtStart)")
                    .font(.sniglet(.headline))
                Text(statusSummary)
                    .font(.sniglet(.caption))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.background)
        )
    }

    private var statusSummary: LocalizedStringResource {
        switch session.status {
        case .missed: "Missed"
        case .declined: "Declined"
        case .hungUp: "You ended the call early"
        case .abandoned: "Dr Tusk hung up after you went silent"
        case .completed: session.passed
            ? "Passed · used \(session.elicitedWordIDs.count) target words"
            : "Completed"
        }
    }

    private func messageBubble(_ message: ChatMessage) -> some View {
        HStack {
            if message.role == .walrus {
                MessageBubble(text: message.text, role: .walrus)
                Spacer(minLength: 40)
            } else {
                Spacer(minLength: 40)
                MessageBubble(text: message.text, role: .user)
            }
        }
    }
}

#Preview {
    NavigationStack { PhoneView() }
        .modelContainer(for: [ChatSession.self, ChatMessage.self], inMemory: true)
}
