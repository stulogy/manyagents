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
    /// True when this assistant turn was produced in response to an automatic
    /// orchestrator board-wake (not the user). Pure-text wake turns (the
    /// "holding, nothing actionable" housekeeping) are hidden from the
    /// transcript so the orchestrator's silent checks don't flood it.
    let fromBoardWake: Bool
    /// True when this message belongs to the orchestrator catch-up turn.
    /// Only its TEXT blocks render (the final digest); the gathering
    /// machinery stays behind the inline setup card.
    let fromCatchUp: Bool

    init(id: UUID = UUID(), role: MessageRole, blocks: [ContentBlock],
         fromBoardWake: Bool = false, fromCatchUp: Bool = false) {
        self.id = id
        self.role = role
        self.blocks = blocks
        self.createdAt = Date()
        self.fromBoardWake = fromBoardWake
        self.fromCatchUp = fromCatchUp
    }

    var isEmpty: Bool { blocks.isEmpty }

    /// True if any block is a tool_use — i.e. the turn actually DID something
    /// (e.g. send_to_agent) rather than just narrating.
    var hasToolUse: Bool {
        blocks.contains { if case .toolUse = $0 { return true }; return false }
    }

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
