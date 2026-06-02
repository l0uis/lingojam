import SwiftUI
import SwiftData

/// Bubble chat with Walter. Owns no business logic — defers to `ChatStore`
/// for turn taking, persistence, and evaluation. Walter's messages are
/// spoken automatically via `SpeechService` (the store calls it on append).
///
/// When the conversation ends (naturally or via end-call), this view
/// briefly lingers so the user reads/hears Walter's closing line, then
/// fires `onFinished(_)` so the host can dismiss us and show the result
/// sheet. The result UI does NOT live in this view.
struct ChatView: View {
    @Environment(\.modelContext) private var context

    @State private var store: ChatStore
    @State private var draft: String = ""
    @FocusState private var inputFocused: Bool

    let onFinished: (ChatEvaluation) -> Void

    init(
        level: CEFRLevel,
        targetWords: [VocabularyWord],
        context: ModelContext,
        wasIncoming: Bool = false,
        onFinished: @escaping (ChatEvaluation) -> Void
    ) {
        let s = ChatStore(
            context: context,
            level: level,
            targetWords: targetWords,
            wasIncoming: wasIncoming
        )
        _store = State(initialValue: s)
        self.onFinished = onFinished
    }

    /// How long to keep the chat on screen after Walter's closing message
    /// arrives, so the user reads it (and the TTS finishes playing) before
    /// we transition to the results sheet.
    /// How long to keep the chat on screen after Walter's closing message
    /// arrives. Calibrated so the user has time to read it AND hear the
    /// TTS playback (~3–4s for a typical wrap-up line) before the result
    /// sheet slides up underneath.
    private static let closingLingerSeconds: Double = 5.5

    var body: some View {
        VStack(spacing: 0) {
            header

            if !store.targetWords.isEmpty {
                TargetWordTracker(
                    targetWords: store.targetWords,
                    usedWordIDs: store.usedTargetWordIDs
                )
            }

            ScrollViewReader { scroller in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(store.displayMessages) { message in
                            messageRow(message)
                                .id(message.id)
                        }
                        if store.phase == .walrusThinking {
                            typingIndicator
                                .id("typing")
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 16)
                }
                .onChange(of: store.displayMessages.count) { _, _ in
                    if let last = store.displayMessages.last {
                        withAnimation(.easeOut(duration: 0.2)) {
                            scroller.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }

            if store.phase == .finished {
                callEndedBanner
            } else {
                inputBar
            }
        }
        .background(DS.Color.paper.ignoresSafeArea())
        .task { await store.startIfNeeded() }
        .onChange(of: store.phase) { _, new in
            // Pop the keyboard the moment Walter is done greeting the
            // user so they can reply without an extra tap. Also fires
            // after each Walter reply, keeping the input focused.
            if new == .awaitingUser {
                inputFocused = true
            }
            if new == .finished {
                inputFocused = false
                Task {
                    try? await Task.sleep(nanoseconds: UInt64(Self.closingLingerSeconds * 1_000_000_000))
                    guard let eval = store.evaluation else { return }
                    onFinished(eval)
                }
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            Image("walrus")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 44, height: 44)
                .background(Circle().fill(.background))
                .overlay(Circle().stroke(DS.Color.ink.opacity(0.15), lineWidth: 1))
            VStack(alignment: .leading, spacing: 2) {
                Text("Dr Tusk")
                    .font(.sniglet(.headline))
                Text(store.phase == .finished ? "Call ended" : "On the line")
                    .font(.sniglet(.caption))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                Task { await store.endCall() }
            } label: {
                Image(systemName: "phone.down.fill")
                    .font(.sniglet(.callout, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(.red))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("End call")
            .disabled(store.phase == .finished)
            .opacity(store.phase == .finished ? 0.4 : 1.0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.background)
        .overlay(InkDivider(), alignment: .bottom)
    }

    // MARK: - Bubbles

    private func messageRow(_ message: ChatStore.DisplayMessage) -> some View {
        HStack {
            if message.role == .walrus {
                walrusBubble(message)
                Spacer(minLength: 40)
            } else {
                Spacer(minLength: 40)
                userBubble(message)
            }
        }
    }

    private func walrusBubble(_ message: ChatStore.DisplayMessage) -> some View {
        HStack(alignment: .top, spacing: 8) {
            MessageBubble(text: message.text, role: .walrus)

            Button {
                store.replay(messageID: message.id)
            } label: {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.sniglet(.caption))
                    .foregroundStyle(.secondary)
                    .padding(6)
                    .background(.gray.opacity(0.15), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Replay")
        }
    }

    private func userBubble(_ message: ChatStore.DisplayMessage) -> some View {
        VStack(alignment: .trailing, spacing: 4) {
            MessageBubble(text: message.text, role: .user)
            if let correction = store.corrections[message.id] {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "pencil.line")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.orange)
                    Text(correction)
                        .font(.caption.italic())
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                }
                .padding(.trailing, 4)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.easeOut(duration: 0.2), value: store.corrections[message.id])
    }

    private var typingIndicator: some View {
        HStack(spacing: 6) {
            ForEach(0..<3) { i in
                Circle()
                    .fill(.secondary)
                    .frame(width: 6, height: 6)
                    .opacity(0.5)
                    .scaleEffect(1.0)
                    .animation(
                        .easeInOut(duration: 0.6)
                            .repeatForever()
                            .delay(Double(i) * 0.15),
                        value: store.phase
                    )
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.background)
        )
    }

    // MARK: - Input

    private var inputBar: some View {
        HStack(spacing: 10) {
            TextField(Self.inputPlaceholder, text: $draft, axis: .vertical)
                .textInputAutocapitalization(.sentences)
                .lineLimit(1...4)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(.background)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(DS.Color.ink.opacity(0.15), lineWidth: 1)
                )
                .focused($inputFocused)
                .submitLabel(.send)
                .onSubmit { submit() }

            Button(action: submit) {
                Image(systemName: "arrow.up")
                    .font(.sniglet(.body, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(DS.Color.ink))
            }
            .buttonStyle(.plain)
            .disabled(canSend == false)
            .opacity(canSend ? 1.0 : 0.4)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.background)
    }

    private var canSend: Bool {
        store.phase == .awaitingUser
            && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func submit() {
        guard canSend else { return }
        let text = draft
        draft = ""
        Task { await store.send(text) }
    }

    /// Language-appropriate placeholder for the chat input. Read at view-
    /// build time, so changing the target language after onboarding takes
    /// effect on the next chat session.
    private static var inputPlaceholder: String {
        switch OnboardingStore.targetLanguage ?? .spanish {
        case .spanish: "Escribe en español…"
        case .french: "Écris en français…"
        case .italian: "Scrivi in italiano…"
        case .german: "Schreib auf Deutsch…"
        }
    }

    // MARK: - Call-ended banner

    /// Bottom-of-screen placeholder shown for the brief linger period
    /// after Walter's closing line and before the result sheet appears.
    private var callEndedBanner: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text("Wrapping up…")
                .font(.sniglet(.subheadline))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity)
        .background(.background)
        .overlay(InkDivider(), alignment: .top)
    }
}

// MARK: - Target word tracker

/// Horizontal pill row showing the words Walter wants the user to use.
/// Pills strike through and fade as the user uses each one. When the
/// last pill is crossed off, the chat auto-wraps via `ChatStore`'s
/// early-completion path.
private struct TargetWordTracker: View {
    let targetWords: [VocabularyWord]
    let usedWordIDs: Set<String>

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "target")
                    .font(.sniglet(.caption, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("Try to use these")
                    .font(.sniglet(.caption))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(usedWordIDs.count) / \(targetWords.count)")
                    .font(.sniglet(.caption, weight: .semibold))
                    .foregroundStyle(usedWordIDs.count == targetWords.count ? Color.green : .secondary)
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(targetWords, id: \.id) { word in
                        pill(for: word, used: usedWordIDs.contains(word.id))
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.background)
        .overlay(InkDivider(), alignment: .bottom)
        .animation(.spring(response: 0.35, dampingFraction: 0.7), value: usedWordIDs)
    }

    private func pill(for word: VocabularyWord, used: Bool) -> some View {
        HStack(spacing: 4) {
            if used {
                Image(systemName: "checkmark")
                    .font(.sniglet(.caption2, weight: .bold))
            }
            Text(word.lemma.capitalizedFirst)
                .font(.sniglet(.caption, weight: .medium))
                .strikethrough(used)
        }
        .foregroundStyle(used ? Color.green : Color.primary)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            Capsule()
                .fill(used ? Color.green.opacity(0.15) : Color.secondary.opacity(0.12))
        )
        .overlay(
            Capsule()
                .stroke(used ? Color.green.opacity(0.3) : Color.clear, lineWidth: 1)
        )
        .opacity(used ? 0.85 : 1.0)
        .scaleEffect(used ? 0.98 : 1.0)
    }
}
