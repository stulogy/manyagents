import Foundation

enum MessageRole {
    case user
    case assistant
    case system
}

/// One conversational turn — user prompt or assistant response. Composed of
/// one or more `ContentBlock`s (text, tool_use, tool_result, thinking).
struct Message: Identifiable, Equatable {
    let id: UUID
    let role: MessageRole
    var blocks: [ContentBlock]
    let createdAt: Date

    init(id: UUID = UUID(), role: MessageRole, blocks: [ContentBlock]) {
        self.id = id
        self.role = role
        self.blocks = blocks
        self.createdAt = Date()
    }

    var isEmpty: Bool { blocks.isEmpty }

    /// Concatenated text across all text blocks. Used for the "last prompt"
    /// preview and the auto-namer.
    var flatText: String {
        blocks.compactMap { block -> String? in
            if case .text(_, let t) = block { return t }
            return nil
        }.joined(separator: "\n")
    }

    static func == (lhs: Message, rhs: Message) -> Bool {
        lhs.id == rhs.id && lhs.role == rhs.role && lhs.blocks == rhs.blocks
    }
}
