import SwiftUI
import SwiftData

/// A voice call with Dr Tusk, rendered as two big speech bubbles — his on
/// top, yours underneath — and nothing else.
///
/// There is no scrollback and no message list. Walter says one sentence
/// per bubble, in time with his voice; you answer out loud and watch your
/// own words appear, get corrected in place, and then get answered. The
/// full transcript is still recorded and readable afterwards from the
/// Phone tab (and mid-call from the header button).
///
/// All sequencing lives in `CallDirector`; this view is its face.
struct VoiceCallView: View {
    @State private var director: CallDirector
    @State private var speech = SpeechRecognitionService.shared
    @State private var isShowingTranscript: Bool = false
    @Environment(\.scenePhase) private var scenePhase
    /// Focus on the input inside the learner's own bubble — there is no
    /// separate text bar; the bubble you speak into is the bubble you type
    /// into.
    @FocusState private var isComposing: Bool

    /// What this call is about, shown under Dr Tusk's name — e.g. the
    /// story being retold. Nil for an everyday call, which shows his name
    /// alone.
    let topic: String?
    let onFinished: (ChatEvaluation) -> Void

    /// Beat between the last thing said and the result sheet, so the call
    /// doesn't snap shut on Walter's goodbye.
    private static let closingLinger: Double = 1.4

    init(
        level: CEFRLevel,
        targetWords: [VocabularyWord],
        context: ModelContext,
        wasIncoming: Bool = false,
        storyContext: String? = nil,
        topic: String? = nil,
        onFinished: @escaping (ChatEvaluation) -> Void
    ) {
        _director = State(initialValue: CallDirector(
            context: context,
            level: level,
            targetWords: targetWords,
            wasIncoming: wasIncoming,
            storyContext: storyContext
        ))
        self.topic = topic
        self.onFinished = onFinished
    }

    var body: some View {
        ZStack {
            CallBackdrop()

            VStack(spacing: 12) {
                header

                if !director.store.targetWords.isEmpty {
                    targetWordStrip
                }

                WalrusBubble(
                    line: director.walrusLine,
                    isThinking: director.isWalrusThinking,
                    isSpeaking: director.stage == .walrusSpeaking,
                    onReplay: { director.replayWalrusLine() }
                )

                YourBubble(
                    text: Binding(
                        get: { director.userText },
                        set: { director.setUserText($0) }
                    ),
                    state: director.userBubble,
                    correction: director.correction,
                    placeholder: Self.promptPlaceholder,
                    isMyTurn: director.stage == .yourTurn,
                    isComposing: $isComposing,
                    onTap: {
                        startComposing()
                    },
                    onSubmit: submitFromKeyboard
                )

                if let message = director.micErrorMessage {
                    micErrorNote(message)
                }

                if director.canSayGoodbye {
                    goodbyeButton
                        .transition(.scale(scale: 0.9).combined(with: .opacity))
                }

                controls
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
            // On the whole stack, not on your bubble: the state often
            // changes in the same beat as the keyboard (sending closes it),
            // and animating just one bubble put it on a different curve
            // from its neighbour, so they overlapped mid-resize.
            .animation(.easeOut(duration: 0.25), value: director.userBubble)
            .animation(.spring(response: 0.35, dampingFraction: 0.75), value: director.canSayGoodbye)
        }
        .statusBarHidden(true)
        .task { await director.start() }
        .onChange(of: speech.transcript) { _, new in
            director.updateLiveTranscript(new)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { director.noteBackgrounded() }
        }
        .onChange(of: director.stage) { _, stage in
            // The text field stays mounted between turns (so it rides the
            // keyboard animation), which means losing the turn no longer
            // drops the keyboard by itself — do it here. Typing is ignored
            // off-turn anyway, and an open keyboard outliving the call
            // stuck over the result sheet.
            if stage != .yourTurn { dismissKeyboard() }
            guard stage == .ended else { return }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(Self.closingLinger * 1_000_000_000))
                // Again on the way out, in case anything took focus
                // during the linger.
                dismissKeyboard()
                onFinished(await director.finalEvaluation())
            }
        }
        .sheet(isPresented: $isShowingTranscript) {
            CallTranscriptSheet(messages: director.store.displayMessages)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            Image("walrus")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 38, height: 38)
                .background(Circle().fill(.white))
                .overlay(
                    Circle().stroke(.white.opacity(director.stage == .walrusSpeaking ? 0.9 : 0.25), lineWidth: 2)
                )
                .scaleEffect(director.stage == .walrusSpeaking ? 1.06 : 1.0)
                .animation(.easeInOut(duration: 0.35), value: director.stage)

            VStack(alignment: .leading, spacing: 1) {
                Text("Dr Tusk")
                    .font(.sniglet(.headline))
                    .foregroundStyle(.white)
                if let topic {
                    Text(topic)
                        .font(.sniglet(.caption))
                        .foregroundStyle(.white.opacity(0.65))
                        .lineLimit(1)
                }
            }

            Spacer()

            Button {
                isShowingTranscript = true
            } label: {
                Image(systemName: "text.bubble")
                    .font(.sniglet(.subheadline, weight: .bold))
                    .foregroundStyle(.white.opacity(0.9))
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(.white.opacity(0.14)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Show transcript")

            // Ending the call sits up here rather than in the controls row:
            // down there, next to the mic, it read as one of the two things
            // you're meant to be doing.
            Button {
                director.hangUp()
            } label: {
                Image(systemName: "phone.down.fill")
                    .font(.sniglet(.subheadline, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(.red.opacity(0.9)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("End call")
        }
        .padding(.top, 8)
    }

    // MARK: - Target words

    /// The words Walter is fishing for, crossed off as they're used. Sits
    /// between the two bubbles as a quiet reminder, not a scoreboard.
    private var targetWordStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(director.store.targetWords, id: \.id) { word in
                    let used = director.store.usedTargetWordIDs.contains(word.id)
                    HStack(spacing: 3) {
                        if used {
                            Image(systemName: "checkmark")
                                .font(.sniglet(.caption2, weight: .bold))
                        }
                        Text(word.lemma)
                            .font(.sniglet(.caption, weight: .medium))
                            .strikethrough(used)
                    }
                    .foregroundStyle(used ? Color.green.opacity(0.95) : .white.opacity(0.7))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(
                        Capsule().fill(used ? Color.green.opacity(0.18) : Color.white.opacity(0.10))
                    )
                }
            }
            .padding(.horizontal, 2)
        }
        .frame(height: 28)
        .animation(.spring(response: 0.35, dampingFraction: 0.7), value: director.store.usedTargetWordIDs)
    }

    // MARK: - Controls

    @ViewBuilder
    private var controls: some View {
        HStack(spacing: 0) {
            Button {
                if isComposing {
                    isComposing = false
                } else {
                    startComposing()
                }
            } label: {
                Image(systemName: isComposing ? "keyboard.chevron.compact.down" : "keyboard")
                    .font(.sniglet(.body, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 50, height: 50)
                    .background(Circle().fill(.white.opacity(0.14)))
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isComposing ? "Hide keyboard" : "Type instead of speaking")

            Spacer()

            TalkButton(
                isMicEnabled: director.isMicEnabled,
                isRecording: speech.isRecording,
                level: speech.audioLevel,
                isDisabled: director.stage == .checking || director.stage == .ended,
                onTap: handleTalkTap
            )

            Spacer()

            Button(action: submitFromKeyboard) {
                Image(systemName: "arrow.up")
                    .font(.sniglet(.body, weight: .bold))
                    .foregroundStyle(.white)
                    .animation(.easeOut(duration: 0.2)) {
                        $0.opacity(director.canSubmit ? 1 : 0.4)
                    }
                    .frame(width: 50, height: 50)
                    .background {
                        // Blue CTA when there's something to send; until
                        // then the same see-through disc as the keyboard
                        // button, so it recedes instead of looking broken.
                        // Both discs are always there and only fade: sending
                        // also closes the keyboard, and a disc swapped out
                        // mid-move was left behind while the arrow slid down.
                        ZStack {
                            Circle().fill(.white.opacity(0.14))
                            GlossyInkFill(shape: Circle())
                                .shadow(color: DS.Shadow.buttonColor, radius: 8, y: 4)
                                .animation(.easeOut(duration: 0.2)) {
                                    $0.opacity(director.canSubmit ? 1 : 0)
                                }
                        }
                    }
            }
            .buttonStyle(.plain)
            .disabled(!director.canSubmit)
            .accessibilityLabel("Send")
        }
        .padding(.horizontal, 8)
        .padding(.top, 4)
    }

    /// Appears once they've used enough words to pass: a way out that lets
    /// Dr Tusk say goodbye, where the red button just cuts him off.
    private var goodbyeButton: some View {
        Button {
            dismissKeyboard()
            director.sayGoodbye()
        } label: {
            Label("Say goodbye", systemImage: "hand.wave.fill")
                .font(.sniglet(size: 16, relativeTo: .subheadline))
                .foregroundStyle(DS.Color.ink)
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .background(Capsule().fill(.white))
        }
        .buttonStyle(.plain)
        .accessibilityHint("Dr Tusk says goodbye and the call ends")
    }

    /// Take the turn (cutting Walter off if need be) and open the keyboard.
    /// Focus waits a tick: the field is disabled until it's the learner's
    /// turn, and focusing it in the same update that enables it is dropped.
    private func startComposing() {
        guard director.beginComposing() else { return }
        Task { @MainActor in isComposing = true }
    }

    /// Drop the keyboard for certain. Clearing `isComposing` alone isn't
    /// enough once the turn is lost: the field is disabled in that same
    /// update, SwiftUI ignores focus changes on a disabled field, and
    /// UIKit's first responder survives — keyboard and all — floating over
    /// the result sheet after the call closes.
    private func dismissKeyboard() {
        isComposing = false
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    /// The mic switch, nothing else — sending has its own button now.
    private func handleTalkTap() {
        guard director.stage != .checking, director.stage != .ended else { return }
        isComposing = false
        director.toggleMic()
    }

    private func submitFromKeyboard() {
        guard director.canSubmit else { return }
        isComposing = false
        director.submit()
    }

    private func micErrorNote(_ message: String) -> some View {
        Text(message)
            .font(.sniglet(.caption))
            .foregroundStyle(.white.opacity(0.85))
            .multilineTextAlignment(.center)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Capsule().fill(Color.orange.opacity(0.35)))
    }

    /// Language-appropriate nudge shown in the empty user bubble and the
    /// keyboard fallback. Deliberately written in the TARGET language, so
    /// these literals stay plain `String`s and out of the String Catalog.
    private static var promptPlaceholder: String {
        switch OnboardingStore.targetLanguage ?? .spanish {
        case .spanish: "Di algo en español…"
        case .french: "Dis quelque chose en français…"
        case .italian: "Di' qualcosa in italiano…"
        case .german: "Sag etwas auf Deutsch…"
        case .english: "Say something in English…"
        }
    }
}

// MARK: - Walter's bubble

/// Walter's single speech bubble. One sentence at a time, swapped in as
/// he speaks it, with progress dots when his turn runs to several.
private struct WalrusBubble: View {
    let line: String
    let isThinking: Bool
    let isSpeaking: Bool
    let onReplay: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            Spacer(minLength: 0)
            ZStack {
                if isThinking || line.isEmpty {
                    ThinkingDots()
                } else {
                    WordByWordText(text: line)
                        .frame(maxWidth: .infinity)
                }
            }
            .animation(.easeOut(duration: 0.2), value: isThinking)

            Spacer(minLength: 0)

            if !line.isEmpty, !isSpeaking {
                Button(action: onReplay) {
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.sniglet(.caption, weight: .bold))
                        .foregroundStyle(DS.Color.ink.opacity(0.55))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Say that again")
            }
        }
        // Expand *inside* the bubble chrome so the bubble itself fills the
        // space — the two of them are the screen, not two labels floating
        // in it.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 22)
        .padding(.top, 20)
        .padding(.bottom, 16)
        .callBubble(.walrus, isActive: isSpeaking)
    }
}

// MARK: - Your bubble

/// The learner's bubble — and their input box. Whatever they say out loud
/// streams into it, and tapping it puts a cursor in the very same place so
/// they can type instead. One box, both ways in.
private struct YourBubble: View {
    @Binding var text: String
    let state: CallDirector.UserBubbleState
    let correction: CorrectionDiff.Result?
    let placeholder: String
    let isMyTurn: Bool
    @FocusState.Binding var isComposing: Bool
    let onTap: () -> Void
    let onSubmit: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Spacer(minLength: 0)

            if let correction, state == .corrected {
                correctedContent(correction)
            } else {
                // One field for the whole call, rather than swapping to a
                // static label once they've sent. Swapping it out on send
                // left the old view stranded where it was while the bubble
                // grew back from under the keyboard; keeping the same view
                // lets the text ride the resize and stay centred. Out of
                // turn it just stops taking touches.
                inputField
                    // Off-turn: taps fall through to the bubble (so tapping
                    // it can still barge in on Walter), and disabling is
                    // what actually makes the field let go of the keyboard
                    // — clearing focus alone left it up through the check.
                    .allowsHitTesting(isMyTurn)
                    .disabled(!isMyTurn)
                    // Shimmers while the grammar check is out, then settles
                    // to plain white — the "checking" signal lives on the
                    // words themselves rather than in a spinner below them.
                    //
                    // The shimmer runs on a copy of the words laid over the
                    // field, never on the field itself: masking the field
                    // re-parents its text view mid-send, and UIKit answers
                    // that by handing it the keyboard straight back.
                    .overlay { shimmeringCopy }
            }

            Spacer(minLength: 0)

            statusFooter
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 22)
        .padding(.top, 18)
        .padding(.bottom, 16)
        .callBubble(.user, isActive: state == .listening || isComposing)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
    }

    /// The text view is always a field while it's their turn, so tapping
    /// anywhere in the bubble lands a cursor without the content jumping
    /// or restyling.
    private var inputField: some View {
        TextField(
            "",
            text: $text,
            prompt: Text(placeholder)
                .foregroundStyle(.white.opacity(0.45)),
            axis: .vertical
        )
        .font(.sniglet(size: 23, relativeTo: .title3))
        // Hidden (not removed) while the shimmering copy stands in for it.
        .foregroundStyle(.white.opacity(isChecking ? 0 : 1))
        .tint(.white)
        .multilineTextAlignment(.center)
        .lineLimit(1...5)
        .textFieldStyle(.plain)
        // The keyboard is almost certainly English while the learner is
        // writing Spanish. Left on, autocorrect rewrites their answer out
        // from under them ("la mujer está" → "la miner estate") and the
        // spell checker underlines correct words in red — which reads as
        // this app marking them wrong.
        .autocorrectionDisabled()
        .focused($isComposing)
        .submitLabel(.send)
        .onSubmit(onSubmit)
        .frame(maxWidth: .infinity)
    }

    private var isChecking: Bool { state == .checking }

    /// Stand-in for the field's text while it's being checked. Always in
    /// the hierarchy so switching it on changes nothing structural.
    private var shimmeringCopy: some View {
        Text(text)
            .font(.sniglet(size: 23, relativeTo: .title3))
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .lineLimit(1...5)
            .frame(maxWidth: .infinity)
            .modifier(Shimmer(isActive: isChecking))
            // Swap in a single frame, in step with the field's own text,
            // which UIKit hides instantly. Fading the copy in left the
            // bubble blank for the length of the keyboard animation.
            // Scoped to opacity so the copy still rides the resize.
            .animation(nil) { $0.opacity(isChecking ? 1 : 0) }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    /// The correction, inside the same bubble: the fixed sentence up top
    /// with the changed words called out, and what they actually said
    /// underneath with those words struck through.
    private func correctedContent(_ diff: CorrectionDiff.Result) -> some View {
        VStack(spacing: 8) {
            Text(attributedCorrected(diff))
                .font(.sniglet(size: 23, relativeTo: .title3))
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.6)
                .frame(maxWidth: .infinity)

            Rectangle()
                .fill(.white.opacity(0.22))
                .frame(height: 1)

            Text(attributedOriginal(diff))
                .font(.sniglet(size: 16, relativeTo: .subheadline))
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
        }
        .transition(.opacity.combined(with: .scale(scale: 0.97)))
    }

    /// Fixed words in bright mint with an underline; everything they got
    /// right stays plain white.
    private func attributedCorrected(_ diff: CorrectionDiff.Result) -> AttributedString {
        var result = AttributedString()
        for token in diff.corrected {
            var piece = AttributedString(token.text)
            if token.change == .changed {
                piece.foregroundColor = Color(red: 0.55, green: 1.0, blue: 0.78)
                piece.underlineStyle = .single
            } else {
                piece.foregroundColor = .white
            }
            result += piece
            result += AttributedString(" ")
        }
        return result
    }

    private func attributedOriginal(_ diff: CorrectionDiff.Result) -> AttributedString {
        var result = AttributedString()
        for token in diff.original {
            var piece = AttributedString(token.text)
            if token.change == .changed {
                piece.foregroundColor = Color(red: 1.0, green: 0.72, blue: 0.68)
                piece.strikethroughStyle = .single
            } else {
                piece.foregroundColor = .white.opacity(0.45)
            }
            result += piece
            result += AttributedString(" ")
        }
        return result
    }

    @ViewBuilder
    private var statusFooter: some View {
        switch state {
        case .listening:
            label("Listening…", system: "waveform", tint: .white.opacity(0.75))
        case .clean:
            label("Nicely said", system: "checkmark.seal.fill", tint: Color(red: 0.55, green: 1.0, blue: 0.78))
        // No label for a correction — the highlighted words and the
        // struck-through original say it better than a counter can.
        case .corrected, .sent, .empty, .checking:
            EmptyView()
        }
    }

    private func label(_ text: LocalizedStringResource, system: String, tint: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: system)
                .font(.sniglet(.caption2, weight: .bold))
            Text(text)
                .font(.sniglet(.caption))
        }
        .foregroundStyle(tint)
    }
}

// MARK: - Talk button

/// The one control that matters. Grows a live ring driven by the actual
/// microphone level while listening, so the learner can see they're being
/// heard before they see any words.
private struct TalkButton: View {
    let isMicEnabled: Bool
    let isRecording: Bool
    let level: Double
    let isDisabled: Bool
    let onTap: () -> Void

    /// Drives the steady "I'm listening" breath, so the button visibly
    /// pulses even in silence — the level rings only move when there's
    /// sound to react to.
    @State private var isBreathing = false

    var body: some View {
        Button(action: onTap) {
            ZStack {
                if isRecording {
                    Circle()
                        .fill(.white.opacity(0.18))
                        .frame(width: 84, height: 84)
                        .scaleEffect(isBreathing ? 1.32 : 1.0)
                        .opacity(isBreathing ? 0 : 1)
                        .animation(.easeOut(duration: 1.3).repeatForever(autoreverses: false), value: isBreathing)
                        .onAppear { isBreathing = true }
                        .onDisappear { isBreathing = false }
                    Circle()
                        .stroke(.white.opacity(0.28), lineWidth: 3)
                        .frame(width: 84, height: 84)
                        .scaleEffect(1.0 + level * 0.45)
                        .animation(.easeOut(duration: 0.12), value: level)
                    Circle()
                        .stroke(.white.opacity(0.16), lineWidth: 2)
                        .frame(width: 84, height: 84)
                        .scaleEffect(1.15 + level * 0.7)
                        .animation(.easeOut(duration: 0.25), value: level)
                }

                Circle()
                    .fill(.white)
                    .frame(width: 84, height: 84)
                    .shadow(color: .black.opacity(0.3), radius: 10, y: 5)

                Image(systemName: symbol)
                    .font(.sniglet(size: 30, weight: .bold))
                    .foregroundStyle(DS.Color.ink)
                    .contentTransition(.symbolEffect(.replace))
            }
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.4 : 1)
        .accessibilityLabel(Text(accessibilityText))
    }

    private var symbol: String {
        isMicEnabled ? "mic.fill" : "mic.slash.fill"
    }

    private var accessibilityText: LocalizedStringResource {
        isMicEnabled ? "Turn the microphone off" : "Turn the microphone on"
    }
}

// MARK: - Shimmer

/// A bright band sweeping across dimmed content, on a loop.
///
/// The mask is always applied and only its stops change, so turning the
/// shimmer on or off never swaps out the view it's on — that view is the
/// learner's text field, and replacing it mid-call loses its position in
/// the keyboard animation.
private struct Shimmer: ViewModifier {
    let isActive: Bool

    private static let period: Double = 1.4
    /// Width of the bright band, as a fraction of the content's width.
    private static let band: CGFloat = 0.6

    func body(content: Content) -> some View {
        content.mask {
            TimelineView(.animation(paused: !isActive)) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                let phase = t.truncatingRemainder(dividingBy: Self.period) / Self.period
                // Start fully off the leading edge, end fully off the trailing.
                let x = -Self.band + CGFloat(phase) * (1 + Self.band)
                let dim = isActive ? 0.35 : 1
                LinearGradient(
                    stops: [
                        .init(color: .black.opacity(dim), location: 0),
                        .init(color: .black, location: 0.5),
                        .init(color: .black.opacity(dim), location: 1)
                    ],
                    startPoint: UnitPoint(x: x, y: 0.5),
                    endPoint: UnitPoint(x: x + Self.band, y: 0.5)
                )
            }
        }
    }
}

// MARK: - Word-by-word reveal

/// Text that arrives one word at a time, the way it's being spoken.
///
/// Needs a real layout rather than a single `Text`, because SwiftUI can't
/// animate individual words inside one string while still wrapping them.
/// `FlowLayout` does the wrapping; each word is its own view so it can fade
/// and rise on its own beat.
private struct WordByWordText: View {
    let text: String
    var size: CGFloat = 25
    var color: Color = DS.Color.ink

    /// Time between words. Fast enough to keep pace with speech — this is
    /// a flourish, not a countdown.
    private static let perWord: Double = 0.055
    /// However long the sentence, the reveal is done by now. A long line
    /// must never still be arriving after Walter has stopped saying it.
    private static let maxTotal: Double = 1.1

    @State private var revealedCount: Int = 0

    private var words: [String] {
        text.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    var body: some View {
        let words = words
        FlowLayout(spacing: 7, lineSpacing: 6) {
            ForEach(Array(words.enumerated()), id: \.offset) { index, word in
                Text(word)
                    .font(.sniglet(size: size, relativeTo: .title3))
                    .foregroundStyle(color)
                    .opacity(index < revealedCount ? 1 : 0)
                    .offset(y: index < revealedCount ? 0 : 7)
                    .blur(radius: index < revealedCount ? 0 : 2.5)
            }
        }
        // Keyed on the text so a new sentence restarts the reveal and
        // cancels the previous one mid-flight.
        .task(id: text) {
            revealedCount = 0
            guard !words.isEmpty else { return }
            let step = min(Self.perWord, Self.maxTotal / Double(words.count))
            for index in words.indices {
                if Task.isCancelled { return }
                withAnimation(.easeOut(duration: 0.28)) {
                    revealedCount = index + 1
                }
                try? await Task.sleep(nanoseconds: UInt64(step * 1_000_000_000))
            }
        }
        // One label for VoiceOver — the staggered words are decoration.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
    }
}

/// Wrapping row layout that centres each line. Used for the word-by-word
/// reveal, where each word has to be its own view.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        let rows = rows(subviews: subviews, maxWidth: maxWidth)
        let height = rows.reduce(0) { $0 + $1.height } + lineSpacing * CGFloat(max(0, rows.count - 1))
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: min(width, maxWidth), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = rows(subviews: subviews, maxWidth: bounds.width)
        var y = bounds.minY
        for row in rows {
            var x = bounds.minX + (bounds.width - row.width) / 2
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(
                    at: CGPoint(x: x, y: y + (row.height - size.height) / 2),
                    proposal: ProposedViewSize(size)
                )
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func rows(subviews: Subviews, maxWidth: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let candidateWidth = current.indices.isEmpty
                ? size.width
                : current.width + spacing + size.width
            if !current.indices.isEmpty, candidateWidth > maxWidth {
                rows.append(current)
                current = Row(indices: [index], width: size.width, height: size.height)
            } else {
                current.indices.append(index)
                current.width = candidateWidth
                current.height = max(current.height, size.height)
            }
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}

// MARK: - Thinking dots

private struct ThinkingDots: View {
    @State private var phase: Int = 0

    var body: some View {
        HStack(spacing: 7) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(DS.Color.ink.opacity(phase == index ? 0.7 : 0.25))
                    .frame(width: 9, height: 9)
            }
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 300_000_000)
                withAnimation(.easeInOut(duration: 0.25)) { phase = (phase + 1) % 3 }
            }
        }
    }
}

// MARK: - Bubble chrome

/// The two big bubbles that make up the call. Walter's is the solid pale
/// one; the learner's is translucent glass — the same treatment as a text
/// input, because that is exactly what it is.
private enum CallBubbleRole {
    case walrus
    case user
}

private struct CallBubbleModifier: ViewModifier {
    let role: CallBubbleRole
    let isActive: Bool

    private static let cornerRadius: CGFloat = 26

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
        content
            .background { fillLayer(shape) }
            .overlay(shape.stroke(strokeColor(active: false), lineWidth: 1))
            .overlay {
                // The active rim fades in on its own. Scoped to opacity so
                // the fade never animates the bubble's frame: `isActive`
                // flips in the same beat as the keyboard, and a whole-bubble
                // animation put this bubble on a different curve from the
                // other one, so they overlapped mid-resize.
                shape.stroke(strokeColor(active: true), lineWidth: 2)
                    .animation(.easeInOut(duration: 0.3)) {
                        $0.opacity(isActive ? 1 : 0)
                    }
            }
            .shadow(color: .black.opacity(0.25), radius: 12, y: 6)
    }

    /// Solid fills only. The keyboard's resize animation moves plain
    /// shapes smoothly, but gradients (and clip masks) jump to their final
    /// size while the outline is still moving — which read as Walter's
    /// bubble running ahead of, or overlapping, the learner's.
    private func fillLayer(_ shape: RoundedRectangle) -> some View {
        switch role {
        case .walrus: shape.fill(Color.white)
        case .user: shape.fill(Color.white.opacity(0.12))
        }
    }

    private func strokeColor(active: Bool) -> Color {
        switch role {
        case .walrus: .white.opacity(active ? 0.55 : 0.12)
        case .user: .white.opacity(active ? 0.55 : 0.25)
        }
    }
}

private extension View {
    func callBubble(_ role: CallBubbleRole, isActive: Bool) -> some View {
        modifier(CallBubbleModifier(role: role, isActive: isActive))
    }
}

// MARK: - Transcript

/// Mid-call escape hatch for anyone who wants the scrollback the two-bubble
/// UI deliberately doesn't show.
private struct CallTranscriptSheet: View {
    let messages: [ChatStore.DisplayMessage]

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(messages) { message in
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
                .padding(20)
            }
            .background(DS.Color.paper.ignoresSafeArea())
            .navigationTitle("Transcript")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

