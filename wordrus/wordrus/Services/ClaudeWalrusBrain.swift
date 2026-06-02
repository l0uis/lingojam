import Foundation

/// Stub implementation that will eventually call the Cloudflare Worker
/// proxy described in `tools/walrus-proxy/README.md`. Do NOT enable
/// `FeatureFlags.useRealWalrus` until that proxy is deployed and the
/// endpoint URL is configured — shipping an API key in the iOS binary
/// is unsafe (the key can be extracted from any IPA).
///
/// Expected endpoints:
///   POST {PROXY_BASE}/v1/walrus/turn       — { level, history, targetWords } -> WalrusTurn
///   POST {PROXY_BASE}/v1/walrus/evaluate   — { level, transcript, targetWords } -> ChatEvaluation
struct ClaudeWalrusBrain: WalrusBrain {
    func openCall(level: CEFRLevel, targetWords: [VocabularyWord]) async -> WalrusTurn {
        fatalError("ClaudeWalrusBrain.openCall is not implemented yet — see tools/walrus-proxy/README.md")
    }

    func reply(
        history: [ChatTurn],
        level: CEFRLevel,
        targetWords: [VocabularyWord]
    ) async -> WalrusTurn {
        fatalError("ClaudeWalrusBrain.reply is not implemented yet — see tools/walrus-proxy/README.md")
    }

    func wrapUp(
        level: CEFRLevel,
        targetWords: [VocabularyWord],
        history: [ChatTurn]
    ) async -> WalrusTurn {
        fatalError("ClaudeWalrusBrain.wrapUp is not implemented yet — see tools/walrus-proxy/README.md")
    }

    func evaluate(
        transcript: [ChatTurn],
        targetWords: [VocabularyWord],
        level: CEFRLevel
    ) async -> ChatEvaluation {
        fatalError("ClaudeWalrusBrain.evaluate is not implemented yet — see tools/walrus-proxy/README.md")
    }
}
