import Foundation

/// A single utterance from Walter the Walrus, plus a flag the brain can
/// raise when it has reached its planned end of the call.
struct WalrusTurn {
    let text: String
    /// True on Walter's final closing message, after which the chat UI
    /// triggers evaluation.
    let endsConversation: Bool
}

/// Result of grading a finished transcript.
struct ChatEvaluation: Identifiable {
    /// Word IDs the user successfully used (any inflected form counts).
    let elicitedWordIDs: [String]
    /// Whether the user cleared the bar for this call (≥ 3 of 5 targets).
    let passed: Bool
    /// English message shown directly to the user in the result sheet.
    /// Despite living next to Spanish-language brain output, this field
    /// is intentionally English — see the prompts in AppleWalrusBrain
    /// and the canned strings in MockWalrusBrain.
    let encouragement: String

    /// Stable per-instance identity so SwiftUI `.sheet(item:)` can
    /// present and dismiss this evaluation correctly.
    let id = UUID()
}

/// A snapshot of one message used for the brain's "what did the user say
/// recently" context. Mirrors `ChatMessage` without a SwiftData dependency
/// so the brain can be unit-tested without a model container.
struct ChatTurn {
    let role: ChatRole
    let text: String
}

/// Pluggable conversational AI for Walter. The mock implementation reads
/// from scripted templates; the eventual Claude implementation will hit
/// a backend proxy. See `tools/walrus-proxy/README.md` for the API contract.
@MainActor
protocol WalrusBrain {
    /// Walter's opening line, chosen for the user's level and target words.
    func openCall(level: CEFRLevel, targetWords: [VocabularyWord]) async -> WalrusTurn

    /// Walter's reply to the most recent user message, given full history.
    func reply(
        history: [ChatTurn],
        level: CEFRLevel,
        targetWords: [VocabularyWord]
    ) async -> WalrusTurn

    /// Walter's celebratory closing line, fired when the user has used
    /// every target word ahead of the normal turn budget. Should set
    /// `endsConversation: true` so the chat finalizes immediately.
    func wrapUp(
        level: CEFRLevel,
        targetWords: [VocabularyWord],
        history: [ChatTurn]
    ) async -> WalrusTurn

    /// Final assessment of the conversation.
    func evaluate(
        transcript: [ChatTurn],
        targetWords: [VocabularyWord],
        level: CEFRLevel
    ) async -> ChatEvaluation
}

@MainActor
enum WalrusBrainFactory {
    /// Returns the active brain implementation. Preference order:
    ///   1. Claude (cloud) — only when the proxy is built and the flag is on
    ///   2. Apple Foundation Models — on-device, when the device supports it
    ///   3. Mock — scripted fallback for simulator / older devices
    static func makeCurrent() -> WalrusBrain {
        if FeatureFlags.useRealWalrus {
            return ClaudeWalrusBrain()
        }
        if #available(iOS 26.0, macOS 26.0, *), AppleWalrusBrain.isAvailable {
            return AppleWalrusBrain()
        }
        return MockWalrusBrain()
    }
}

enum FeatureFlags {
    /// Flip to true ONLY once the Cloudflare proxy is deployed and the
    /// app has a configured proxy URL. See tools/walrus-proxy/README.md.
    static let useRealWalrus = false
}
