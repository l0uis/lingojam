import Foundation
import Observation
import SwiftData
#if canImport(UIKit)
import UIKit
#endif

/// Runs the back-and-forth of a voice call with Walter.
///
/// The conversation itself — turn validity, persistence, target-word
/// tracking, grading — stays in `ChatStore`. What lives here is the
/// *performance*: breaking Walter's reply into one sentence per speech
/// bubble and revealing each in time with his voice, opening the mic when
/// it's the learner's turn, sending on a pause, and holding his reply back
/// until the learner has seen their own sentence corrected.
///
/// Exactly one line is on screen per speaker at any moment. There is no
/// scrollback — the full transcript is persisted and readable afterwards
/// from the Phone tab.
@Observable
@MainActor
final class CallDirector {
    enum Stage {
        /// Placing the call — waiting on Walter's opener.
        case connecting
        /// A sentence of Walter's is on screen and being spoken.
        case walrusSpeaking
        /// The learner's turn: mic open, or waiting for them to tap it.
        case yourTurn
        /// Their line is in — being corrected, and Walter is thinking.
        case checking
        /// Call over. The view lingers a beat, then shows the result.
        case ended
    }

    /// What the learner's bubble is showing right now.
    enum UserBubbleState: Equatable {
        /// Nothing said yet this turn.
        case empty
        /// Mic is live; `userText` is the running transcript.
        case listening
        /// Sent, grammar check still out.
        case checking
        /// Sent, but no verdict — the grammar check timed out or isn't
        /// available on this device. Deliberately distinct from `.clean`:
        /// claiming "nicely said" when nothing was actually checked would
        /// be telling the learner their Spanish is fine on no evidence.
        case sent
        /// Checked and correct as spoken.
        case clean
        /// Checked and fixed — the diff is rendered inside the same bubble.
        case corrected

        static func == (lhs: UserBubbleState, rhs: UserBubbleState) -> Bool {
            String(describing: lhs) == String(describing: rhs)
        }
    }

    // MARK: - Published state

    private(set) var stage: Stage = .connecting

    /// The single sentence of Walter's currently on screen.
    private(set) var walrusLine: String = ""
    /// True between the learner sending and Walter's first sentence
    /// arriving — his bubble shows the thinking dots.
    private(set) var isWalrusThinking: Bool = false

    /// What the learner said (live transcript while listening, their final
    /// sentence once sent).
    private(set) var userText: String = ""
    private(set) var userBubble: UserBubbleState = .empty
    /// Word-level diff between what they said and the corrected version.
    /// Non-nil only in the `.corrected` state.
    private(set) var correction: CorrectionDiff.Result?

    /// Set when the mic can't be used, so the view can fall back to the
    /// keyboard and explain why.
    private(set) var micErrorMessage: String?

    /// The learner's mic switch. On for the whole call unless they turn it
    /// off, so they never have to tap to start talking.
    ///
    /// "On" can't mean literally capturing while Walter speaks — the
    /// recogniser would transcribe his voice coming out of the speaker,
    /// and `SpeechRecognitionService` has to take the audio session off
    /// playback to record at all. So capture pauses for his audio and
    /// re-arms the moment he stops, which is invisible from the outside.
    var isMicEnabled: Bool = true

    let store: ChatStore

    // MARK: - Tuning

    /// Beat between Walter's speech bubbles. Long enough to read as two
    /// separate utterances, short enough not to feel like a dropped call.
    private static let interChunkPause: Double = 0.45
    /// Silence after the learner stops talking before the turn auto-sends.
    private static let silenceBeforeSend: Double = 1.8
    /// How long Walter will hold his reply waiting on the grammar check.
    private static let correctionTimeout: TimeInterval = 2.5
    /// Pause after a correction appears so the fix registers before Walter
    /// starts talking.
    private static let correctionReadingBeat: Double = 1.1

    // MARK: - Private

    private var speech = SpeechRecognitionService.shared
    private var queue: [ChatStore.WalrusUtterance] = []
    private var drainTask: Task<Void, Never>?
    /// Bumped whenever a drain is started or abandoned, so a stale drain
    /// can tell it's been replaced.
    private var drainGeneration: Int = 0
    private var silenceTask: Task<Void, Never>?
    /// The turn awaiting a verdict — set on submit, consumed by
    /// `applyCorrection` when Walter's reply comes back.
    private var pendingUserMessage: (id: UUID, text: String)?
    private var hasStarted = false
    private var callStartedAt: Date?

    init(store: ChatStore) {
        self.store = store
    }

    convenience init(
        context: ModelContext,
        level: CEFRLevel,
        targetWords: [VocabularyWord],
        wasIncoming: Bool,
        storyContext: String? = nil
    ) {
        self.init(store: ChatStore(
            brain: WalrusBrainFactory.makeCurrent(storyContext: storyContext),
            context: context,
            level: level,
            targetWords: targetWords,
            wasIncoming: wasIncoming
        ))
    }

    // MARK: - Lifecycle

    func start() async {
        guard !hasStarted else { return }
        hasStarted = true
        callStartedAt = Date()
        // Take over voicing Walter so his lines arrive here as they're
        // decided instead of being spoken over the top of each other.
        store.onWalrusUtterance = { [weak self] utterance in
            self?.enqueue(utterance)
        }
        stage = .connecting
        // Get the permission sheet out of the way while Walter is still
        // saying hello, rather than having it interrupt the learner's
        // first turn.
        Task { _ = await speech.requestPermissions() }
        await store.startIfNeeded()
    }

    /// The mic button. Turns capture off if it's running, and otherwise
    /// takes the floor — cutting Walter off if he's mid-sentence, since
    /// reaching for the mic means you want to talk now.
    func toggleMic() {
        if isMicEnabled, speech.isRecording {
            isMicEnabled = false
            cancelListening()
            return
        }
        isMicEnabled = true
        beginListening()
    }

    /// Learner tapped the red button.
    func hangUp() {
        guard stage != .ended else { return }
        teardown()
        stage = .ended
        Analytics.capture(.callEnded, [
            "ended_by": "user",
            "duration_bucket": Analytics.durationBucket(Date().timeIntervalSince(callStartedAt ?? Date()))
        ])
        Task { await store.endCall() }
    }

    /// The final grade, once `finalize` has produced one. Polls briefly
    /// because grading can still be in flight when Walter's closing line
    /// finishes playing. Falls back to a plain "call ended" result rather
    /// than leaving the learner on a dead screen.
    func finalEvaluation() async -> ChatEvaluation {
        let deadline = Date.now.addingTimeInterval(6)
        while store.evaluation == nil, Date.now < deadline {
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        return store.evaluation ?? ChatEvaluation(
            elicitedWordIDs: [],
            passed: false,
            encouragement: "The call ended. Give Dr Tusk another ring when you're ready."
        )
    }

    /// Replay the sentence currently in Walter's bubble.
    func replayWalrusLine() {
        guard !walrusLine.isEmpty, stage != .walrusSpeaking else { return }
        SpeechService.shared.speakAsWalter(walrusLine)
    }

    // MARK: - Walter's turn

    private func enqueue(_ utterance: ChatStore.WalrusUtterance) {
        queue.append(utterance)
        guard drainTask == nil else { return }
        drainGeneration &+= 1
        let generation = drainGeneration
        drainTask = Task { [weak self] in
            await self?.drain()
            // A cancelled drain still runs to completion. Without the
            // generation check it could clear the handle belonging to the
            // drain that replaced it, and the next utterance would start a
            // second one talking over the first.
            guard let self, self.drainGeneration == generation else { return }
            self.drainTask = nil
        }
    }

    /// Speak the queue out, one sentence per bubble, waiting on each one's
    /// audio before revealing the next.
    private func drain() async {
        while !queue.isEmpty, stage != .ended, !Task.isCancelled {
            let utterance = queue.removeFirst()

            // Settle the verdict on what they just said and let it land
            // before Walter talks over it — that's the shape of the turn.
            await applyCorrection(from: utterance)
            guard stage != .ended, !Task.isCancelled else { return }

            // Walter has taken their message in. Their bubble goes back to
            // being an empty input box, ready for the next turn.
            clearSettledUserLine()

            let chunks = Self.chunk(utterance.text)
            isWalrusThinking = false

            for (index, chunk) in chunks.enumerated() {
                guard stage != .ended, !Task.isCancelled else { return }
                stage = .walrusSpeaking
                walrusLine = chunk

                // Fetch the next sentence's audio while this one plays, so
                // the gap between bubbles is a breath rather than a
                // round-trip.
                if index + 1 < chunks.count {
                    SpeechService.shared.prefetchAsWalter(chunks[index + 1])
                }
                await SpeechService.shared.speakAsWalterAndWait(chunk)

                guard stage != .ended, !Task.isCancelled else { return }
                if index + 1 < chunks.count {
                    try? await Task.sleep(nanoseconds: UInt64(Self.interChunkPause * 1_000_000_000))
                }
            }

            if utterance.endsConversation {
                teardown()
                stage = .ended
                return
            }
        }
        guard !Task.isCancelled else { return }
        handOverToUser()
    }

    /// Wipe the learner's bubble once their message has been delivered and
    /// any correction has had its moment on screen.
    ///
    /// Only clears a *settled* turn. A half-typed draft or a live
    /// transcript must survive — Walter's silence nudge comes through this
    /// same path, and wiping someone's sentence out from under them as
    /// they compose it would be maddening.
    private func clearSettledUserLine() {
        switch userBubble {
        case .sent, .clean:
            userText = ""
            correction = nil
            userBubble = .empty
        case .corrected:
            // A correction stays up while Walter answers — it's the one
            // thing on screen worth reading, and wiping it a second after
            // it appears is the same as never showing it. Taking the next
            // turn is what clears it.
            break
        case .empty, .listening, .checking:
            break
        }
    }

    /// Walter's finished — hand the floor back.
    private func handOverToUser() {
        guard stage != .ended, store.phase == .awaitingUser else { return }
        stage = .yourTurn
        // The silence clock starts now — not while Walter was still
        // talking — so "you still there?" only fires on real silence.
        store.armSilenceClock()
        if isMicEnabled { beginListening() }
    }

    // MARK: - The learner's turn

    /// Open the mic. Also acts as barge-in: tapping while Walter is
    /// mid-sentence cuts him off and gives the learner the floor.
    func beginListening() {
        if stage == .walrusSpeaking || stage == .connecting {
            interruptWalrus()
        }
        guard stage == .yourTurn, !speech.isRecording else { return }

        micErrorMessage = nil
        userText = ""
        correction = nil
        userBubble = .listening

        Task {
            guard await speech.requestPermissions() else {
                micErrorMessage = "Wordrus needs Microphone and Speech Recognition access to hear you. Turn them on in Settings, or tap your bubble to type instead."
                userBubble = .empty
                isMicEnabled = false
                return
            }
            let locale = Locale(identifier: (OnboardingStore.targetLanguage ?? .spanish).bcp47)
            do {
                try await speech.startRecording(locale: locale)
            } catch {
                micErrorMessage = speech.lastErrorMessage
                    ?? "Couldn't start the microphone. Tap your bubble to type instead."
                userBubble = .empty
                isMicEnabled = false
            }
        }
    }

    /// Dismiss the microphone warning — the learner has moved on to the
    /// keyboard and doesn't need to keep reading it.
    func clearMicError() {
        micErrorMessage = nil
    }

    /// Stop the mic without sending — the learner wants to start over.
    func cancelListening() {
        silenceTask?.cancel()
        silenceTask = nil
        if speech.isRecording { _ = speech.stopRecording() }
        userText = ""
        userBubble = .empty
    }

    /// Take the keyboard. Clears whatever the bubble was showing — an old
    /// sentence and its correction shouldn't sit there as the starting
    /// text of a new turn — and stands the mic down so the two input
    /// methods don't fight over the box.
    ///
    /// Like tapping the mic, this cuts Walter off mid-sentence: reaching
    /// for the input box is a clear signal you want the floor. Returns
    /// false if the floor isn't available (he hasn't opened the call yet),
    /// so the caller knows not to raise the keyboard.
    @discardableResult
    func beginComposing() -> Bool {
        if stage == .walrusSpeaking || stage == .connecting {
            interruptWalrus()
        }
        guard stage == .yourTurn else { return false }
        isMicEnabled = false
        cancelListening()
        clearMicError()
        userText = ""
        correction = nil
        userBubble = .empty
        return true
    }

    /// Typed edits from the shared input bubble. Voice and keyboard write
    /// to the same `userText`, which is why there's only ever one box.
    func setUserText(_ text: String) {
        guard stage == .yourTurn else { return }
        userText = text
        store.noteUserActivity()
    }

    /// True when the bubble holds fresh, unsent input. Guards the send
    /// button from re-submitting the sentence still on display from the
    /// previous turn.
    var canSubmit: Bool {
        stage == .yourTurn
            && !userText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (userBubble == .empty || userBubble == .listening)
    }

    /// Called by the view as the recognizer streams words in.
    func updateLiveTranscript(_ text: String) {
        guard speech.isRecording, stage == .yourTurn else { return }
        userText = text
        // Every word resets Walter's patience — he should only nudge on
        // real silence, never mid-sentence.
        store.noteUserActivity()
        scheduleSilenceAutoSend()
    }

    /// Send the current turn. Pass `typed` from the keyboard fallback;
    /// otherwise the live transcript is used.
    func submit(typed: String? = nil) {
        silenceTask?.cancel()
        silenceTask = nil

        var text = typed ?? userText
        if speech.isRecording {
            let final = speech.stopRecording()
            if typed == nil, !final.isEmpty { text = final }
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, stage == .yourTurn else { return }
        guard let messageID = store.registerUserTurn(trimmed) else { return }

        userText = trimmed
        correction = nil
        userBubble = .checking
        stage = .checking
        isWalrusThinking = true
        playHaptic(.light)

        // The verdict is settled when Walter's reply arrives — it may come
        // from him — and shown just before he speaks. See `applyCorrection`.
        pendingUserMessage = (id: messageID, text: trimmed)
        Task { await store.advance() }
    }

    /// Decide the verdict on the learner's last line and show it, just
    /// before Walter answers.
    ///
    /// Walter's own correction wins when he offered one — he had the whole
    /// conversation in front of him, and unlike `GrammarService` he works
    /// on every device. The on-device checker is the fallback for when
    /// he's offline or scripted.
    private func applyCorrection(from utterance: ChatStore.WalrusUtterance) async {
        guard let pending = pendingUserMessage else { return }
        pendingUserMessage = nil

        var corrected = utterance.correction
        // Whether anything actually judged the sentence. Without this we'd
        // be back to congratulating people on unexamined Spanish.
        var wasChecked = corrected != nil

        if corrected == nil {
            switch await store.checkOutcome(for: pending.id, timeout: Self.correctionTimeout) {
            case .corrected(let text):
                corrected = text
                wasChecked = true
            case .clean:
                wasChecked = true
            case .unavailable:
                wasChecked = false
            }
        }
        guard stage != .ended else { return }

        if let corrected {
            let diff = CorrectionDiff.compare(original: pending.text, corrected: corrected)
            // The correction may amount to punctuation only, which
            // `CorrectionDiff` rightly ignores — that's a clean sentence.
            if diff.hasChanges {
                correction = diff
                userBubble = .corrected
                playHaptic(.medium)
                // Hold Walter back a beat so the fix isn't buried under his
                // reply.
                try? await Task.sleep(nanoseconds: UInt64(Self.correctionReadingBeat * 1_000_000_000))
                return
            }
        }
        userBubble = wasChecked ? .clean : .sent
    }

    /// Cut Walter off mid-turn and hand the floor over. Drops whatever he
    /// had queued — he'll pick the thread back up from the transcript.
    private func interruptWalrus() {
        drainTask?.cancel()
        drainTask = nil
        drainGeneration &+= 1
        queue.removeAll()
        SpeechService.shared.stop()
        isWalrusThinking = false
        guard store.phase == .awaitingUser else { return }
        stage = .yourTurn
        store.armSilenceClock()
    }

    /// Re-arms on every transcript change; when it survives the pause, the
    /// turn sends itself. This is what makes the call feel like talking
    /// rather than dictating into a text box.
    private func scheduleSilenceAutoSend() {
        silenceTask?.cancel()
        silenceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.silenceBeforeSend * 1_000_000_000))
            guard let self, !Task.isCancelled, self.isMicEnabled,
                  self.stage == .yourTurn, self.speech.isRecording,
                  !self.speech.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return }
            self.submit()
        }
    }

    private func teardown() {
        drainTask?.cancel()
        drainTask = nil
        drainGeneration &+= 1
        silenceTask?.cancel()
        silenceTask = nil
        pendingUserMessage = nil
        queue.removeAll()
        if speech.isRecording { _ = speech.stopRecording() }
        isWalrusThinking = false
    }

    private func playHaptic(_ style: HapticStyle) {
        #if canImport(UIKit)
        UIImpactFeedbackGenerator(style: style.uiStyle).impactOccurred()
        #endif
    }

    enum HapticStyle {
        case light, medium
        #if canImport(UIKit)
        var uiStyle: UIImpactFeedbackGenerator.FeedbackStyle {
            switch self {
            case .light: .light
            case .medium: .medium
            }
        }
        #endif
    }

    // MARK: - Chunking

    /// Longest sentence that gets its own bubble before we split it
    /// further at clause boundaries.
    private static let maxChunkCharacters = 150
    /// Sentences shorter than this ("¡Hola!", "Sí.") merge into the next
    /// one instead of flashing past on their own. Kept low on purpose:
    /// Walter speaks in short sentences, and "Buenos días." earns its own
    /// bubble — only true stubs should be swallowed.
    private static let minChunkCharacters = 10

    /// Split one of Walter's turns into per-bubble sentences.
    static func chunk(_ text: String) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var sentences: [String] = []
        trimmed.enumerateSubstrings(
            in: trimmed.startIndex..<trimmed.endIndex,
            options: [.bySentences, .localized]
        ) { substring, _, _, _ in
            let sentence = substring?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !sentence.isEmpty { sentences.append(sentence) }
        }
        // Some brains return text the tokenizer can't split (no terminal
        // punctuation at all) — one bubble is the honest answer there.
        if sentences.isEmpty { sentences = [trimmed] }

        return merged(sentences.flatMap(splitIfOverlong))
    }

    /// Break a runaway sentence at its clause boundaries so a single
    /// bubble never turns into a wall of text.
    private static func splitIfOverlong(_ sentence: String) -> [String] {
        guard sentence.count > maxChunkCharacters else { return [sentence] }

        var parts: [String] = []
        var current = ""
        for clause in sentence.split(separator: ",", omittingEmptySubsequences: false) {
            let piece = current.isEmpty ? String(clause) : current + "," + String(clause)
            if piece.count > maxChunkCharacters, !current.isEmpty {
                parts.append(current.trimmingCharacters(in: .whitespaces))
                current = String(clause)
            } else {
                current = piece
            }
        }
        let tail = current.trimmingCharacters(in: .whitespaces)
        if !tail.isEmpty { parts.append(tail) }
        return parts.isEmpty ? [sentence] : parts
    }

    /// Fold stub sentences forward into the one that follows.
    private static func merged(_ sentences: [String]) -> [String] {
        var result: [String] = []
        var pending = ""
        for sentence in sentences {
            let combined = pending.isEmpty ? sentence : pending + " " + sentence
            if combined.count < minChunkCharacters {
                pending = combined
            } else {
                result.append(combined)
                pending = ""
            }
        }
        // A trailing stub has nothing to merge into — glue it onto the
        // previous bubble rather than emitting "Sí." on its own.
        if !pending.isEmpty {
            if let last = result.popLast() {
                result.append(last + " " + pending)
            } else {
                result.append(pending)
            }
        }
        return result
    }
}
