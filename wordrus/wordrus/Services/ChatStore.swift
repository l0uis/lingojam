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
        appendWalrus(opener.text)
        try? context.save()
        phase = opener.endsConversation ? .finished : .awaitingUser

        if opener.endsConversation {
            await finalize()
        } else {
            SpeechService.shared.speakAsWalter(opener.text)
            startInactivityTimer()
        }
    }

    func send(_ userText: String) async {
        let trimmed = userText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, phase == .awaitingUser else { return }

        cancelInactivityTimer()
        hasNudged = false
        let userMessageID = appendUser(trimmed)
        try? context.save()
        detectNewlyUsedWords(in: trimmed)
        kickOffGrammarCheck(for: userMessageID, text: trimmed)
        phase = .walrusThinking

        // Early completion: every target word has now been used. Walter
        // wraps up with a celebratory closing instead of asking another
        // question.
        if !targetWords.isEmpty,
           usedTargetWordIDs.count >= targetWords.count {
            let history = displayMessages.map { ChatTurn(role: $0.role, text: $0.text) }
            let closer = await brain.wrapUp(level: level, targetWords: targetWords, history: history)
            appendWalrus(closer.text)
            try? context.save()
            SpeechService.shared.speakAsWalter(closer.text)
            phase = .finished
            await finalize()
            return
        }

        let history = displayMessages.map { ChatTurn(role: $0.role, text: $0.text) }
        let next = await brain.reply(history: history, level: level, targetWords: targetWords)
        appendWalrus(next.text)
        try? context.save()
        SpeechService.shared.speakAsWalter(next.text)

        if next.endsConversation {
            phase = .finished
            await finalize()
        } else {
            phase = .awaitingUser
            startInactivityTimer()
        }
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
        // and show a plain English message instead of fake encouragement.
        if userMessages.isEmpty {
            if let session {
                session.endedAt = .now
                session.status = .hungUp
            }
            try? context.save()
            evaluation = ChatEvaluation(
                elicitedWordIDs: [],
                passed: false,
                encouragement: "The call ended before you said anything. Give it another go when you're ready."
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
            appendWalrus(nudge)
            try? context.save()
            SpeechService.shared.speakAsWalter(nudge)
            startInactivityTimer()
        } else {
            // Walter gives up.
            let hangUp = localizedHangUpPhrase
            appendWalrus(hangUp)
            try? context.save()
            SpeechService.shared.speakAsWalter(hangUp)
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
            encouragement: "Dr Tusk got tired of waiting and hung up. Call back when you're ready."
        )
        OnboardingStore.lastWalterCallDate = .now
    }

    private func appendWalrus(_ text: String) {
        let id = UUID()
        displayMessages.append(DisplayMessage(id: id, role: .walrus, text: text))
        let stored = ChatMessage(id: id, role: .walrus, text: text, session: session)
        context.insert(stored)
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
            guard let correction = await GrammarService.shared.check(text, language: language) else { return }
            self?.corrections[messageID] = correction
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
