import Foundation
import SwiftData

// MARK: - Models

/// Chat message author.
enum ChatRole: String, Codable, Sendable {
    case system
    case user
    case assistant
}

/// A user-created folder grouping conversations (LM Studio–style).
@Model
final class ChatFolder {
    var name: String
    var createdAt: Date

    @Relationship(deleteRule: .nullify, inverse: \Conversation.folder)
    var conversations: [Conversation]

    init(name: String, createdAt: Date = .now) {
        self.name = name
        self.createdAt = createdAt
        self.conversations = []
    }
}

/// A chat thread.
@Model
final class Conversation {
    var title: String
    var createdAt: Date
    var updatedAt: Date
    /// The model this thread was last used with.
    var modelName: String?
    var folder: ChatFolder?

    @Relationship(deleteRule: .cascade, inverse: \ChatMessage.conversation)
    var messages: [ChatMessage]

    init(title: String, createdAt: Date = .now) {
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = createdAt
        self.modelName = nil
        self.folder = nil
        self.messages = []
    }
}

/// One message in a `Conversation`.
@Model
final class ChatMessage {
    var role: ChatRole
    var content: String
    var timestamp: Date
    /// The model that produced an assistant message (for multi-model attribution).
    var modelName: String?
    /// Seconds spent in the `<think>` block (reasoning models), if any.
    var thinkingSeconds: Double?
    /// Wall-clock seconds the reply took to stream, for tok/s.
    var generationSeconds: Double?
    /// Server-reported token counts (exact, from `stream_options.include_usage`).
    var completionTokens: Int?
    var totalTokens: Int?
    /// Files attached to a user message (copies under Application Support), so
    /// bubbles can render them and history resends them.
    var attachmentPaths: [String]?
    var conversation: Conversation?

    init(
        role: ChatRole,
        content: String,
        timestamp: Date = .now,
        modelName: String? = nil,
        conversation: Conversation? = nil
    ) {
        self.role = role
        self.content = content
        self.timestamp = timestamp
        self.modelName = modelName
        self.thinkingSeconds = nil
        self.conversation = conversation
    }
}
