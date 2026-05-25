import Foundation
import SwiftData

enum ChatRole: String, Codable {
    case walrus
    case user
}

@Model
final class ChatMessage {
    @Attribute(.unique) var id: UUID
    var roleRaw: String
    var text: String
    var timestamp: Date
    var session: ChatSession?

    init(
        id: UUID = UUID(),
        role: ChatRole,
        text: String,
        timestamp: Date = .now,
        session: ChatSession? = nil
    ) {
        self.id = id
        self.roleRaw = role.rawValue
        self.text = text
        self.timestamp = timestamp
        self.session = session
    }

    var role: ChatRole {
        get { ChatRole(rawValue: roleRaw) ?? .walrus }
        set { roleRaw = newValue.rawValue }
    }
}
