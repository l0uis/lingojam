import Foundation

/// Walter, backed by Claude through the walrus proxy. This is the one
/// implementation that can actually hold a conversation: the whole call is
/// sent as real message turns, so he answers what was said instead of
/// reaching for the next line in a script.
///
/// Every method falls back to `fallback` (the best on-device brain
/// available) if the network call fails for any reason. That makes
/// `FeatureFlags.useRealWalrus` safe to leave on even when the proxy is
/// down or not yet deployed — the call degrades to scripted Walter rather
/// than dying mid-sentence.
///
/// Endpoint: POST {PROXY_BASE}/v1/walrus/turn — see tools/walrus-proxy.
@MainActor
struct ClaudeWalrusBrain: WalrusBrain {
    /// Used whenever the cloud call can't be completed.
    let fallback: WalrusBrain

    /// Long enough for a Sonnet turn, short enough that a hung network
    /// doesn't leave the learner staring at the thinking dots. On timeout
    /// the on-device brain answers instead.
    private static let timeout: TimeInterval = 12

    /// Background for a call about something specific (`CallSeed`), sent
    /// to the proxy as `storyContext`.
    let storyContext: String?

    init(fallback: WalrusBrain? = nil, storyContext: String? = nil) {
        self.fallback = fallback ?? WalrusBrainFactory.makeOnDevice()
        self.storyContext = storyContext
    }

    func openCall(level: CEFRLevel, targetWords: [VocabularyWord]) async -> WalrusTurn {
        if let turn = await turn(phase: "open", history: [], level: level, targetWords: targetWords) {
            return turn
        }
        return await fallback.openCall(level: level, targetWords: targetWords)
    }

    func reply(
        history: [ChatTurn],
        level: CEFRLevel,
        targetWords: [VocabularyWord]
    ) async -> WalrusTurn {
        // Walter starts winding down once the call has run its natural
        // length. The model still picks the words; this only tells it when.
        let walrusTurns = history.filter { $0.role == .walrus }.count
        let shouldWrapUp = walrusTurns >= MockWalrusBrain.promptTurnCount
        if let turn = await turn(
            phase: "reply",
            history: history,
            level: level,
            targetWords: targetWords,
            shouldWrapUp: shouldWrapUp
        ) {
            return turn
        }
        return await fallback.reply(history: history, level: level, targetWords: targetWords)
    }

    func wrapUp(
        level: CEFRLevel,
        targetWords: [VocabularyWord],
        history: [ChatTurn]
    ) async -> WalrusTurn {
        if let turn = await turn(phase: "wrapUp", history: history, level: level, targetWords: targetWords) {
            return turn
        }
        return await fallback.wrapUp(level: level, targetWords: targetWords, history: history)
    }

    /// Grading stays on-device. `ChatStore.finalize` recomputes the word
    /// hits with the deterministic lemma matcher regardless of what any
    /// brain claims, so a second network round trip would buy nothing but
    /// the one-line encouragement.
    func evaluate(
        transcript: [ChatTurn],
        targetWords: [VocabularyWord],
        level: CEFRLevel
    ) async -> ChatEvaluation {
        await fallback.evaluate(transcript: transcript, targetWords: targetWords, level: level)
    }

    // MARK: - Networking

    private func turn(
        phase: String,
        history: [ChatTurn],
        level: CEFRLevel,
        targetWords: [VocabularyWord],
        shouldWrapUp: Bool = false
    ) async -> WalrusTurn? {
        let language = OnboardingStore.targetLanguage ?? .spanish
        guard let endpoint = URL(string: WalrusProxyConfig.proxyURL)?
            .appendingPathComponent("/v1/walrus/turn") else { return nil }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = Self.timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(DeviceKeyManager.deviceID(), forHTTPHeaderField: "X-Walrus-Device-ID")
        request.setValue(Bundle.main.bundleIdentifier ?? "unknown.bundle", forHTTPHeaderField: "X-Walrus-Bundle-ID")

        var payload: [String: Any] = [
            "language": language.englishName,
            "level": level.rawValue,
            "phase": phase,
            "shouldWrapUp": shouldWrapUp,
            "targetWords": targetWords.map(\.lemma),
            "history": history.map { ["role": $0.role.rawValue, "text": $0.text] },
        ]
        if let storyContext { payload["storyContext"] = storyContext }
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
        request.httpBody = body

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                #if DEBUG
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                print("ClaudeWalrusBrain: proxy returned \(status) — falling back")
                #endif
                return nil
            }
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let text = object["text"] as? String,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return nil }
            let correction = (object["correction"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return WalrusTurn(
                text: text.trimmingCharacters(in: .whitespacesAndNewlines),
                endsConversation: object["endsConversation"] as? Bool ?? false,
                correction: (correction?.isEmpty == false) ? correction : nil
            )
        } catch {
            #if DEBUG
            print("ClaudeWalrusBrain: \(error) — falling back")
            #endif
            return nil
        }
    }
}
