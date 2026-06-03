import Foundation

/// Reads a `claude` JSONL transcript from disk and reconstructs `Message`
/// objects so a restored session can show its prior conversation history.
/// We deliberately keep this simple: text blocks, tool_use blocks, and
/// tool_result blocks. Streaming deltas, queue-operations, and other
/// internal event types are skipped.
enum TranscriptLoader {
    static func load(cwd: String, sessionId: String) -> [Message] {
        let path = jsonlPath(cwd: cwd, sessionId: sessionId)
        guard let raw = try? String(contentsOfFile: path, encoding: .utf8) else {
            return []
        }
        var out: [Message] = []
        raw.enumerateLines { line, _ in
            guard let lineData = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let type = obj["type"] as? String
            else { return }
            switch type {
            case "user":
                if let m = parseUser(obj) { out.append(m) }
            case "assistant":
                if let m = parseAssistant(obj) { out.append(m) }
            default:
                break
            }
        }
        return out
    }

    /// Claude Code stores transcripts at
    ///   ~/.claude/projects/<slugified-cwd>/<session-id>.jsonl
    /// where the slug is "every / replaced with -". Absolute cwds already
    /// start with /, so the leading dash comes free.
    static func jsonlPath(cwd: String, sessionId: String) -> String {
        let expanded = (cwd as NSString).expandingTildeInPath
        let trimmed = expanded.hasSuffix("/") && expanded.count > 1
            ? String(expanded.dropLast()) : expanded
        let slug = trimmed.replacingOccurrences(of: "/", with: "-")
        return "\(NSHomeDirectory())/.claude/projects/\(slug)/\(sessionId).jsonl"
    }

    // MARK: - Parsers

    private static func parseUser(_ obj: [String: Any]) -> Message? {
        guard let msg = obj["message"] as? [String: Any] else { return nil }
        var blocks: [ContentBlock] = []
        var isToolResultsOnly = true

        if let s = msg["content"] as? String {
            // Plain-string user content (the typical "you typed a prompt" case).
            let cleaned = sanitizeUserText(s)
            if !cleaned.isEmpty {
                blocks.append(.text(id: UUID(), text: cleaned))
                isToolResultsOnly = false
            }
        } else if let arr = msg["content"] as? [[String: Any]] {
            for c in arr {
                let ct = c["type"] as? String
                if ct == "text", let t = c["text"] as? String {
                    let cleaned = sanitizeUserText(t)
                    if !cleaned.isEmpty {
                        blocks.append(.text(id: UUID(), text: cleaned))
                        isToolResultsOnly = false
                    }
                } else if ct == "image", let source = c["source"] as? [String: Any] {
                    // claude writes pasted images to the JSONL as base64
                    // (type "base64", media_type "image/png" or similar).
                    // Decode back to Data so the restored conversation
                    // shows the image inline.
                    if let kind = source["type"] as? String, kind == "base64",
                       let mediaType = source["media_type"] as? String,
                       let b64 = source["data"] as? String,
                       let data = Data(base64Encoded: b64) {
                        blocks.append(.image(id: UUID(), data: data, mediaType: mediaType))
                        isToolResultsOnly = false
                    }
                } else if ct == "tool_result" {
                    let toolUseId = c["tool_use_id"] as? String ?? ""
                    let isError = c["is_error"] as? Bool ?? false
                    let text = flattenToolResultContent(c["content"])
                    blocks.append(.toolResult(id: UUID(),
                                              toolUseId: toolUseId,
                                              content: text,
                                              isError: isError))
                }
            }
        }

        if blocks.isEmpty { return nil }
        // tool_result-only "user" lines render as system blocks so they sit
        // visually distinct from the human-typed prompts.
        let role: MessageRole = isToolResultsOnly ? .system : .user
        return Message(role: role, blocks: blocks)
    }

    private static func parseAssistant(_ obj: [String: Any]) -> Message? {
        guard let msg = obj["message"] as? [String: Any],
              let content = msg["content"] as? [[String: Any]]
        else { return nil }
        var blocks: [ContentBlock] = []
        for c in content {
            let ct = c["type"] as? String
            switch ct {
            case "text":
                if let t = c["text"] as? String {
                    blocks.append(.text(id: UUID(), text: t))
                }
            case "thinking":
                if let t = c["thinking"] as? String {
                    blocks.append(.thinking(id: UUID(), text: t))
                }
            case "tool_use":
                if let id = c["id"] as? String,
                   let name = c["name"] as? String {
                    let rawInput = c["input"] as? [String: Any] ?? [:]
                    let input = rawInput.mapValues(AnyCodable.from)
                    blocks.append(.toolUse(id: UUID(),
                                           toolUseId: id,
                                           name: name,
                                           input: input))
                }
            default:
                break
            }
        }
        if blocks.isEmpty { return nil }
        return Message(role: .assistant, blocks: blocks)
    }

    /// Strip the synthetic tags claude code wraps system reminders and IDE
    /// notifications in. They're noise to the user.
    private static func sanitizeUserText(_ raw: String) -> String {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("<") && s.contains("system-reminder") { return "" }
        if s.hasPrefix("<command-") { return "" }
        if s.hasPrefix("<local-command-stdout>") { return "" }
        return s
    }

    private static func flattenToolResultContent(_ value: Any?) -> String {
        if let s = value as? String { return s }
        if let arr = value as? [[String: Any]] {
            return arr.compactMap { item in
                item["type"] as? String == "text" ? item["text"] as? String : nil
            }.joined(separator: "\n")
        }
        return ""
    }
}
