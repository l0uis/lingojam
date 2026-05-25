import Foundation
import SwiftData

/// How a call with Walter ended. Drives the icon/label in the Phone tab.
enum ChatSessionStatus: String, Codable {
    /// Walrus rang via scheduled notification and the user never opened
    /// the incoming call screen — written by `MissedCallReconciler`.
    case missed
    /// User tapped Decline on the incoming call screen.
    case declined
    /// User opened the chat and ended it themselves before walrus closed.
    case hungUp
    /// User went silent mid-conversation; Walter nudged once and then
    /// hung up on his own.
    case abandoned
    /// Walrus closed the conversation naturally; check `passed` to know
    /// whether the user cleared the word-recall bar.
    case completed
}

/// One conversation with Walter the Walrus, persisted so we can revisit
/// transcripts and feed them to the LLM evaluator in the future.
@Model
final class ChatSession {
    @Attribute(.unique) var id: UUID
    var startedAt: Date
    var endedAt: Date?

    /// CEFR raw value (A1…C2) — captured at start since the user may level
    /// up mid-session.
    var levelAtStart: String

    /// Word IDs the walrus tried to elicit from the user.
    var targetWordIDsJSON: String

    /// Word IDs the user successfully used during the conversation.
    var elicitedWordIDsJSON: String

    var passed: Bool

    /// Raw `ChatSessionStatus` value. Defaults to `.completed` for older
    /// rows written before this field existed.
    var statusRaw: String = ChatSessionStatus.completed.rawValue

    /// True if the walrus initiated the call (scheduled notification).
    /// False for user-initiated outgoing calls.
    var wasIncoming: Bool = false

    @Relationship(deleteRule: .cascade, inverse: \ChatMessage.session)
    var messages: [ChatMessage] = []

    init(
        id: UUID = UUID(),
        startedAt: Date = .now,
        endedAt: Date? = nil,
        levelAtStart: String,
        targetWordIDs: [String] = [],
        elicitedWordIDs: [String] = [],
        passed: Bool = false,
        status: ChatSessionStatus = .completed,
        wasIncoming: Bool = false
    ) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.levelAtStart = levelAtStart
        self.targetWordIDsJSON = Self.encode(targetWordIDs)
        self.elicitedWordIDsJSON = Self.encode(elicitedWordIDs)
        self.passed = passed
        self.statusRaw = status.rawValue
        self.wasIncoming = wasIncoming
    }

    var status: ChatSessionStatus {
        get { ChatSessionStatus(rawValue: statusRaw) ?? .completed }
        set { statusRaw = newValue.rawValue }
    }

    var targetWordIDs: [String] {
        get { Self.decode(targetWordIDsJSON) }
        set { targetWordIDsJSON = Self.encode(newValue) }
    }

    var elicitedWordIDs: [String] {
        get { Self.decode(elicitedWordIDsJSON) }
        set { elicitedWordIDsJSON = Self.encode(newValue) }
    }

    private static func encode(_ ids: [String]) -> String {
        guard let data = try? JSONEncoder().encode(ids),
              let json = String(data: data, encoding: .utf8) else { return "[]" }
        return json
    }

    private static func decode(_ json: String) -> [String] {
        guard let data = json.data(using: .utf8),
              let list = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return list
    }
}
