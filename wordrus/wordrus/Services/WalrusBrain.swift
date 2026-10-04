import Foundation

/// A single utterance from Walter the Walrus, plus a flag the brain can
/// raise when it has reached its planned end of the call.
struct WalrusTurn {
    let text: String
    /// True on Walter's final closing message, after which the chat UI
    /// triggers evaluation.
    let endsConversation: Bool
    /// The learner's previous message written out correctly, when Walter
    /// spotted a real mistake in it. nil when it was fine — or when the
    /// brain can't judge, which is every brain but the cloud one.
    ///
    /// Having Walter do this means corrections work on every device;
    /// `GrammarService` needs Apple Intelligence and silently does nothing
    /// without it.
    let correction: String?

    init(text: String, endsConversation: Bool, correction: String? = nil) {
        self.text = text
        self.endsConversation = endsConversation
        self.correction = correction
    }
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
    ///   1. Claude (cloud) — the only one that truly converses
    ///   2. Apple Foundation Models — on-device, when the device supports it
    ///   3. Mock — scripted fallback for simulator / older devices
    ///
    /// The cloud brain wraps the best on-device brain as its own fallback,
    /// so a failed request drops to (2) or (3) mid-call rather than
    /// stranding the learner.
    ///
    /// `storyContext` is background for a call about something specific
    /// (retelling today's story); nil for the usual recent-words call.
    static func makeCurrent(storyContext: String? = nil) -> WalrusBrain {
        if FeatureFlags.useRealWalrus {
            return ClaudeWalrusBrain(fallback: makeOnDevice(storyContext: storyContext), storyContext: storyContext)
        }
        return makeOnDevice(storyContext: storyContext)
    }

    /// The best brain that needs no network. The scripted mock can't use
    /// `storyContext`.
    static func makeOnDevice(storyContext: String? = nil) -> WalrusBrain {
        if #available(iOS 26.0, macOS 26.0, *), AppleWalrusBrain.isAvailable {
            return AppleWalrusBrain(storyContext: storyContext)
        }
        return MockWalrusBrain()
    }
}

enum FeatureFlags {
    /// Route Walter's conversation through Claude on the proxy
    /// (`/v1/walrus/turn`). This is what makes him respond to what you
    /// actually said rather than reciting a template.
    ///
    /// Safe to leave on: `ClaudeWalrusBrain` falls back to the on-device
    /// brain on any failure, so an undeployed or unreachable proxy costs a
    /// couple of seconds, not a broken call. Requires the worker to be
    /// deployed with `ANTHROPIC_API_KEY` set — see tools/walrus-proxy/README.md.
    static let useRealWalrus = true

    /// Route Add-a-Word vocabulary lookups through the Claude proxy
    /// (`/v1/walrus/enrich`) for accuracy. Requires the `ANTHROPIC_API_KEY`
    /// secret set on the worker. Safe to leave on before deploy: a missing
    /// endpoint just 404s and (with the fallback off) the user sees the
    /// "couldn't look this up" banner instead of a wrong answer.
    static let useCloudEnrichment = true

    /// Whether to fall back to the on-device Apple model when the cloud
    /// lookup fails. OFF by default: the small on-device model hallucinates
    /// vocabulary (mangles lemmas, invents definitions), which is worse than
    /// showing nothing for a feature whose whole point is accuracy. Turn on
    /// only if you want a best-effort offline guess and accept the risk.
    static let useOnDeviceEnrichmentFallback = false
}
