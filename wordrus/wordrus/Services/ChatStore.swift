import Foundation
import Observation
import SwiftData

/// Owns one in-progress conversation with Walter. The view binds to its
/// `displayMessages` for the bubble list and drives turns via `send(_:)`
/// and `endCall()`. Persists everything to SwiftData so transcripts and
/// pass/fail history survive a relaunch.
@Observable
@MainActor
final class ChatStore {
    enum Phase {
        case idle
        case opening
        case awaitingUser
        case walrusThinking
        case finished
    }

    struct DisplayMessage: Identifiable {
        let id: UUID
        let role: ChatRole
        let text: String
    }

    /// One thing Walter says, handed to `onWalrusUtterance` the instant
    /// it's decided. Covers every source — opener, reply, wrap-up, silence
    /// nudge, and the "fine, I'm hanging up" line — so a UI that voices
    /// Walter itself never misses one.
    struct WalrusUtterance {
        let id: UUID
        let text: String
        let endsConversation: Bool
        /// The learner's previous line, corrected by Walter. Travels with
        /// his reply so the UI can show the fix at the moment he answers.
        let correction: String?
    }

    /// Installed by the voice-call UI. When set, the store stops speaking
    /// Walter's lines itself and hands them over instead, so the caller can
    /// reveal them one speech bubble at a time in step with the audio.
    /// Left nil, the store speaks each line immediately as it always has.
    var onWalrusUtterance: ((WalrusUtterance) -> Void)?

    private(set) var phase: Phase = .idle
    private(set) var displayMessages: [DisplayMessage] = []
    private(set) var evaluation: ChatEvaluation?

    /// Word IDs the user has used so far in the conversation. Updated
    /// after every user message via the lemma matcher; the chat view
    /// strikes through their pills as this set grows.
    private(set) var usedTargetWordIDs: Set<String> = []

    /// Grammar corrections per user message ID. Populated asynchronously
    /// in parallel with Walter's reply via `GrammarService`. Keys are
    /// the user's message UUIDs; values are the corrected sentence.
    /// Messages with no entry have either not been checked yet or
    /// passed the check cleanly.
    private(set) var corrections: [UUID: String] = [:]

    /// Grammar verdicts per user message id, recorded as each check
    /// settles. Absent means "still running": the voice UI waits on this
    /// before letting Walter reply, so a correction never lands after he's
    /// already talking over it. Note `.unavailable` is a real outcome, not
    /// a missing one — see `GrammarCheckOutcome`.
    private(set) var checkOutcomes: [UUID: GrammarCheckOutcome] = [:]

    let brain: WalrusBrain
    let context: ModelContext
    let level: CEFRLevel
    /// The 5 (or fewer) words Walter wants the user to use. Exposed so
    /// `ChatView` can render the pill tracker.
    let targetWords: [VocabularyWord]
    private let wasIncoming: Bool
    private var session: ChatSession?
    private var endedByUser: Bool = false
    private var inactivityTask: Task<Void, Never>?
    private var hasNudged: Bool = false

    /// Seconds of silence before Walter pokes the user with a follow-up.
    private static let nudgeAfter: TimeInterval = 25
    /// Additional seconds of silence after the nudge before Walter hangs up.
    private static let hangUpAfter: TimeInterval = 25

    /// "You still there?" + "fine, I'm gone" phrases are pulled from
    /// `WalterCopy` at runtime so they match the user's target language.
    private var localizedNudgePhrases: [String] {
        WalterCopy.forLanguage(OnboardingStore.targetLanguage ?? .spanish).nudgePhrases
    }
    private var localizedHangUpPhrase: String {
        WalterCopy.forLanguage(OnboardingStore.targetLanguage ?? .spanish).hangUpPhrase
    }

    init(
        brain: WalrusBrain? = nil,
        context: ModelContext,
        level: CEFRLevel,
        targetWords: [VocabularyWord],
        wasIncoming: Bool = false
    ) {
        self.brain = brain ?? WalrusBrainFactory.makeCurrent()
        self.context = context
        self.level = level
        self.targetWords = targetWords
        self.wasIncoming = wasIncoming
    }

    func startIfNeeded() async {
        guard phase == .idle else { return }
        phase = .opening

        let newSession = ChatSession(
            levelAtStart: level.rawValue,
            targetWordIDs: targetWords.map(\.id),
            wasIncoming: wasIncoming,
            language: OnboardingStore.targetLanguage ?? .spanish
        )
        context.insert(newSession)
        session = newSession

        let opener = await brain.openCall(level: level, targetWords: targetWords)
        emitWalrus(opener.text, endsConversation: opener.endsConversation)
        phase = opener.endsConversation ? .finished : .awaitingUser

        if opener.endsConversation {
            await finalize()
        } else {
            startInactivityTimer()
        }
    }

    /// Called by the view whenever the user is actively composing — typing
    /// a character or dictating into the draft. Resets the silence clock so
    /// Walter never nudges or hangs up while the user is mid-message. No-op
    /// unless it's the user's turn with a timer already armed, so stray
    /// `draft` changes (e.g. clearing it on send) don't restart the clock.
    func noteUserActivity() {
        guard phase == .awaitingUser, inactivityTask != nil else { return }
        startInactivityTimer()
    }

    func send(_ userText: String) async {
        guard registerUserTurn(userText) != nil else { return }
        await advance()
    }

    /// Record the user's turn: persist it, cross off any target words it
    /// used, and kick off its grammar check. Returns the new message's id
    /// so the caller can await that check via `correction(for:)`, or nil if
    /// it wasn't the user's turn to speak.
    ///
    /// Split out from `send` so the voice UI can show the user's own line
    /// (and its correction) before Walter starts talking back.
    @discardableResult
    func registerUserTurn(_ userText: String) -> UUID? {
        let trimmed = userText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, phase == .awaitingUser else { return nil }

        cancelInactivityTimer()
        hasNudged = false
        let userMessageID = appendUser(trimmed)
        try? context.save()
        detectNewlyUsedWords(in: trimmed)
        kickOffGrammarCheck(for: userMessageID, text: trimmed)
        phase = .walrusThinking
        return userMessageID
    }

    /// Ask Walter for his next line and emit it. Only valid straight after
    /// `registerUserTurn`.
    func advance() async {
        guard phase == .walrusThinking else { return }

        // Early completion: every target word has now been used. Walter
        // wraps up with a celebratory closing instead of asking another
        // question.
        if !targetWords.isEmpty,
           usedTargetWordIDs.count >= targetWords.count {
            let history = displayMessages.map { ChatTurn(role: $0.role, text: $0.text) }
            let closer = await brain.wrapUp(level: level, targetWords: targetWords, history: history)
            emitWalrus(closer.text, endsConversation: true)
            phase = .finished
            await finalize()
            return
        }

        let history = displayMessages.map { ChatTurn(role: $0.role, text: $0.text) }
        let next = await brain.reply(history: history, level: level, targetWords: targetWords)
        emitWalrus(
            next.text,
            endsConversation: next.endsConversation,
            correction: next.correction
        )

        if next.endsConversation {
            phase = .finished
            await finalize()
        } else {
            phase = .awaitingUser
            if !isExternallyVoiced { startInactivityTimer() }
        }
    }

    /// Restart the silence clock. Callers that voice Walter themselves own
    /// this: the clock must start when the user can actually reply, not
    /// while Walter is still working through his sentences.
    func armSilenceClock() {
        guard phase == .awaitingUser else { return }
        startInactivityTimer()
    }

    /// Wait for a user message's grammar check to settle, giving up after
    /// `timeout` seconds so a slow or stalled model can't hold up the
    /// conversation. A timeout reports `.unavailable` — the same as no
    /// checker at all, because in both cases nothing vouched for the
    /// sentence.
    func checkOutcome(for messageID: UUID, timeout: TimeInterval) async -> GrammarCheckOutcome {
        let deadline = Date.now.addingTimeInterval(timeout)
        while checkOutcomes[messageID] == nil, Date.now < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
            if Task.isCancelled { break }
        }
        return checkOutcomes[messageID] ?? .unavailable
    }

    /// Cross off any target words the user just mentioned. Uses the same
    /// `SpanishLemmaMatcher` as the final evaluator so the live tracker
    /// and the final score stay in agreement.
    private func detectNewlyUsedWords(in userText: String) {
        for word in targetWords where !usedTargetWordIDs.contains(word.id) {
            if SpanishLemmaMatcher.userText(userText, mentions: word.lemma, partOfSpeech: word.partOfSpeech) {
                usedTargetWordIDs.insert(word.id)
            }
        }
    }

    func endCall() async {
        guard phase != .finished else { return }
        cancelInactivityTimer()
        endedByUser = true
        phase = .finished
        SpeechService.shared.stop()
        await finalize()
    }

    func replay(messageID: UUID) {
        if let msg = displayMessages.first(where: { $0.id == messageID && $0.role == .walrus }) {
            SpeechService.shared.speakAsWalter(msg.text)
        }
    }

    // MARK: - Private

    private func finalize() async {
        let userMessages = displayMessages.filter { $0.role == .user }

        // No real conversation happened — skip evaluation, mark as hung up,
        // and show a plain message instead of fake encouragement.
        if userMessages.isEmpty {
            if let session {
                session.endedAt = .now
                session.status = .hungUp
            }
            try? context.save()
            evaluation = ChatEvaluation(
                elicitedWordIDs: [],
                passed: false,
                encouragement: String(localized: "The call ended before you said anything. Give it another go when you're ready.")
            )
            OnboardingStore.lastWalterCallDate = .now
            return
        }

        let transcript = displayMessages.map { ChatTurn(role: $0.role, text: $0.text) }
        let result = await brain.evaluate(transcript: transcript, targetWords: targetWords, level: level)

        // The lemma matcher is the authoritative source of truth — it's the
        // same deterministic check that drives the live pill tracker
        // (`usedTargetWordIDs`), so the final score can never contradict what
        // the user watched get crossed off during the call. We run it over
        // every target word against the full user transcript rather than
        // filtering the brain's `elicitedWordIDs`: the brain (Apple FM) both
        // hallucinates hits AND under-reports real ones, and filtering its
        // claim could only ever shrink the count, dropping words the user
        // genuinely used. `usedTargetWordIDs` is folded in as a belt-and-
        // braces guarantee of agreement with the tracker.
        let userText = userMessages.map(\.text).joined(separator: " ")
        let matchedIDs = targetWords.compactMap { word -> String? in
            SpanishLemmaMatcher.userText(userText, mentions: word.lemma, partOfSpeech: word.partOfSpeech) ? word.id : nil
        }
        let validatedHitSet = usedTargetWordIDs.union(matchedIDs)
        // Preserve target-word order for stable display.
        let validatedHits = targetWords.map(\.id).filter { validatedHitSet.contains($0) }
        let validatedPassed = validatedHits.count >= MockWalrusBrain.passingThreshold

        let validatedResult = ChatEvaluation(
            elicitedWordIDs: validatedHits,
            passed: validatedPassed,
            encouragement: result.encouragement
        )
        evaluation = validatedResult

        if let session {
            session.endedAt = .now
            session.elicitedWordIDs = validatedHits
            session.passed = validatedPassed
            session.status = endedByUser ? .hungUp : .completed
        }
        try? context.save()

        // Pass count for level-up gating — only completed (not hung-up) chats count.
        if validatedPassed && !endedByUser {
            OnboardingStore.cefrPassesAtCurrentLevel += 1
        }
        OnboardingStore.lastWalterCallDate = .now
    }

    // MARK: - Inactivity

    private func startInactivityTimer() {
        cancelInactivityTimer()
        let delay = hasNudged ? Self.hangUpAfter : Self.nudgeAfter
        inactivityTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.handleInactivity()
        }
    }

    private func cancelInactivityTimer() {
        inactivityTask?.cancel()
        inactivityTask = nil
    }

    /// Fires when the user has been silent past the timer threshold.
    /// First time: Walter sends a nudge and waits again. Second time:
    /// Walter hangs up himself.
    private func handleInactivity() async {
        guard phase == .awaitingUser else { return }

        if !hasNudged {
            hasNudged = true
            let nudge = localizedNudgePhrases.randomElement() ?? "¿Sigues ahí?"
            emitWalrus(nudge)
            startInactivityTimer()
        } else {
            // Walter gives up.
            emitWalrus(localizedHangUpPhrase, endsConversation: true)
            phase = .finished
            await finalizeAbandoned()
        }
    }

    /// Sister of `finalize()` for the case where Walter, not the user,
    /// ended the call. No evaluation runs — the transcript is too thin
    /// to be pedagogically useful — and the session doesn't count toward
    /// level-up. We surface a parting message in the chat footer.
    private func finalizeAbandoned() async {
        if let session {
            session.endedAt = .now
            session.status = .abandoned
        }
        try? context.save()
        evaluation = ChatEvaluation(
            elicitedWordIDs: [],
            passed: false,
            encouragement: String(localized: "Dr Tusk got tired of waiting and hung up. Call back when you're ready.")
        )
        OnboardingStore.lastWalterCallDate = .now
    }

    /// True when someone else is voicing Walter — see `onWalrusUtterance`.
    private var isExternallyVoiced: Bool { onWalrusUtterance != nil }

    /// The one way Walter says anything: append, persist, and either speak
    /// it here or hand it to whoever installed `onWalrusUtterance`. Funnels
    /// every source through a single path so a new utterance site can't
    /// forget to notify the voice UI.
    private func emitWalrus(
        _ text: String,
        endsConversation: Bool = false,
        correction: String? = nil
    ) {
        let id = appendWalrus(text)
        try? context.save()
        if let onWalrusUtterance {
            onWalrusUtterance(WalrusUtterance(
                id: id,
                text: text,
                endsConversation: endsConversation,
                correction: correction
            ))
        } else {
            SpeechService.shared.speakAsWalter(text)
        }
    }

    @discardableResult
    private func appendWalrus(_ text: String) -> UUID {
        let id = UUID()
        displayMessages.append(DisplayMessage(id: id, role: .walrus, text: text))
        let stored = ChatMessage(id: id, role: .walrus, text: text, session: session)
        context.insert(stored)
        return id
    }

    @discardableResult
    private func appendUser(_ text: String) -> UUID {
        let id = UUID()
        displayMessages.append(DisplayMessage(id: id, role: .user, text: text))
        let stored = ChatMessage(id: id, role: .user, text: text, session: session)
        context.insert(stored)
        return id
    }

    /// Fires `GrammarService` in the background for the user's message
    /// and writes any correction into `corrections[messageID]` so the
    /// chat view can render it underneath the bubble. Runs in parallel
    /// with Walter's reply — no need to block on it.
    private func kickOffGrammarCheck(for messageID: UUID, text: String) {
        let language = OnboardingStore.targetLanguage ?? .spanish
        Task { [weak self] in
            let outcome = await GrammarService.shared.check(text, language: language)
            if case .corrected(let corrected) = outcome {
                self?.corrections[messageID] = corrected
            }
            self?.checkOutcomes[messageID] = outcome
        }
    }
}

extension ChatStore {
    /// One-shot writer used when a call ends before a `ChatStore` is even
    /// constructed — e.g. the user declines an incoming call, or a
    /// scheduled call notification was never answered.
    static func recordTerminalSession(
        context: ModelContext,
        status: ChatSessionStatus,
        wasIncoming: Bool,
        at date: Date = .now
    ) {
        let session = ChatSession(
            startedAt: date,
            endedAt: date,
            levelAtStart: OnboardingStore.cefrLevel.rawValue,
            status: status,
            wasIncoming: wasIncoming,
            language: OnboardingStore.targetLanguage ?? .spanish
        )
        context.insert(session)
        try? context.save()
    }

    /// Selects `count` target words for the chat by sampling from the
    /// most recently studied `recentPoolSize` words. Sorting by
    /// recency first ensures Walter only quizzes on fresh material;
    /// the random sample within that window keeps repeated calls from
    /// always picking the same 5 in the same order. Includes words in
    /// ANY state the user has touched — including `.known`, because a
    /// left-swipe-known marks a word as `.known` immediately, and those
    /// are exactly the words the user just declared they know and
    /// should be tested on. Restricted to words at-or-below the user's
    /// current CEFR level. Caller passes in the full word/progress
    /// snapshots so this stays a pure function — no SwiftData access
    /// required.
    static func pickTargetWords(
        from words: [VocabularyWord],
        progress: [LearningProgress],
        level: CEFRLevel,
        count: Int = 5,
        recentPoolSize: Int = 10
    ) -> [VocabularyWord] {
        let progressByID = Dictionary(uniqueKeysWithValues: progress.map { ($0.wordID, $0) })

        let eligible = words.compactMap { word -> (VocabularyWord, Date)? in
            // `.new` words have no `lastReviewedAt`, so the guard naturally
            // excludes them. Everything the user has actually swiped is fair
            // game — `.learning`, `.review`, and `.known` all count.
            guard let p = progressByID[word.id],
                  let reviewedAt = p.lastReviewedAt
            else { return nil }
            if let raw = word.cefrLevel,
               let wordLevel = CEFRLevel(rawValue: raw),
               wordLevel > level {
                return nil
            }
            return (word, reviewedAt)
        }

        // Take the freshest `recentPoolSize` words, then pick `count`
        // at random from that pool. Two passes so a learner with months
        // of vocab doesn't end up testing on words from weeks ago.
        let recentPool = eligible
            .sorted { $0.1 > $1.1 }
            .prefix(recentPoolSize)
            .map(\.0)
        return Array(recentPool.shuffled().prefix(count))
    }
}
