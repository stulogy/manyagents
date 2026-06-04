import Foundation

/// One piece of a message. Mirrors the Anthropic Messages API content-block
/// shape that the `claude` CLI emits over the stream-json transport.
///
/// `parentToolUseId` is set on tool blocks that were spawned by a subagent
/// (Task tool). The renderer uses it to nest sub-tool-calls visually
/// underneath their parent Agent card instead of letting them sprawl as
/// independent top-level cards.
enum ContentBlock: Identifiable, Equatable {
    case text(id: UUID, text: String)
    case toolUse(id: UUID, toolUseId: String, name: String, input: [String: AnyCodable], parentToolUseId: String?)
    case toolResult(id: UUID, toolUseId: String, content: String, isError: Bool, parentToolUseId: String?)
    case thinking(id: UUID, text: String)
    case image(id: UUID, data: Data, mediaType: String)

    var id: UUID {
        switch self {
        case .text(let id, _),
             .toolUse(let id, _, _, _, _),
             .toolResult(let id, _, _, _, _),
             .thinking(let id, _),
             .image(let id, _, _):
            return id
        }
    }

    /// Parent tool_use id, if this block was emitted under a subagent.
    /// nil for top-level blocks. Drives the nested-card rendering.
    var parentToolUseId: String? {
        switch self {
        case .toolUse(_, _, _, _, let p),
             .toolResult(_, _, _, _, let p):
            return p
        default:
            return nil
        }
    }

    /// Tool-use id that other blocks can reference as their parent.
    /// nil for non-tool-use blocks.
    var toolUseId: String? {
        switch self {
        case .toolUse(_, let id, _, _, _),
             .toolResult(_, let id, _, _, _):
            return id
        default:
            return nil
        }
    }

    /// Append text to a streaming text block. Used during delta accumulation.
    mutating func appendText(_ s: String) {
        switch self {
        case .text(let id, let existing):
            self = .text(id: id, text: existing + s)
        case .thinking(let id, let existing):
            self = .thinking(id: id, text: existing + s)
        default:
            break
        }
    }
}

/// Type-erased Codable wrapper for tool inputs (whose shape varies per tool).
struct AnyCodable: Equatable {
    let value: Any

    init(_ value: Any) { self.value = value }

    static func == (lhs: AnyCodable, rhs: AnyCodable) -> Bool {
        switch (lhs.value, rhs.value) {
        case let (l as String, r as String): return l == r
        case let (l as Int, r as Int): return l == r
        case let (l as Double, r as Double): return l == r
        case let (l as Bool, r as Bool): return l == r
        case let (l as [String: AnyCodable], r as [String: AnyCodable]): return l == r
        case let (l as [AnyCodable], r as [AnyCodable]): return l == r
        case (is NSNull, is NSNull): return true
        default: return false
        }
    }

    var stringValue: String? { value as? String }
    var dictValue: [String: AnyCodable]? { value as? [String: AnyCodable] }
}

extension AnyCodable {
    static func from(_ raw: Any) -> AnyCodable {
        if let dict = raw as? [String: Any] {
            return AnyCodable(dict.mapValues(AnyCodable.from))
        }
        if let arr = raw as? [Any] {
            return AnyCodable(arr.map(AnyCodable.from))
        }
        return AnyCodable(raw)
    }
}
