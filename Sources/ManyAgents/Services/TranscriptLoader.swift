import Foundation

/// Reads a `claude` JSONL transcript from disk and reconstructs `Message`
/// objects so a restored session can show its prior conversation history.
/// We deliberately keep this simple: text blocks, tool_use blocks, and
/// tool_result blocks. Streaming deltas, queue-operations, and other
/// internal event types are skipped.
enum TranscriptLoader {
    /// How much of a transcript's tail we parse on restore.
    ///
    /// These JSONLs reach 100 MB here, and parsing one whole file
    /// materializes a JSON object graph several times its size. Restore did
    /// that for every tab in a single main-thread loop with no autorelease
    /// pool anywhere, so nothing drained until all 25 were done — which is
    /// how the app reached tens of GB and took the machine down with it.
    ///
    /// The transcript view windows to its last few hundred messages anyway,
    /// so read the tail and stop. Older history stays on disk, and `claude`
    /// still resumes with its own full context regardless of what we show.
    static let maxTailBytes = 8 * 1024 * 1024

    /// Hard cap on restored messages, independent of the byte cap — a tail
    /// of tiny lines shouldn't restore 20,000 rows either.
    static let maxMessages = 600

    /// What a restore pass recovered. One pass over the tail produces both,
    /// so the file is never read twice.
    struct Restored {
        var messages: [Message]
        var contextTokens: Int?
        /// True when history was cut — the caller shows a marker row.
        var truncated: Bool
    }

    /// Rebuild a session's visible history from disk. Call OFF the main
    /// thread: it does file IO and JSON parsing proportional to the tail.
    static func restore(cwd: String, sessionId: String) -> Restored {
        let path = jsonlPath(cwd: cwd, sessionId: sessionId)
        var out: [Message] = []
        var context: Int? = nil
        var dropped = false

        // Track AskUserQuestion tool_use ids so the CLI's auto-deny
        // "Answer questions?" error tool_result (headless `--print` behaviour)
        // can be dropped when it lands on the following user line — matching
        // how the live bridge suppresses it.
        var askUserQuestionIds = Set<String>()
        // Tracks whether the next assistant turn is an automatic orchestrator
        // board-wake (the prompt was injected by us with `visible:false`, so on
        // restore we drop the prompt and tag the reply — matching live tagging,
        // so silent "holding" turns stay hidden).
        var pendingBoardWake = false

        let cut = enumerateTailLines(path: path, maxBytes: maxTailBytes) { lineData in
            guard let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let type = obj["type"] as? String
            else { return }
            switch type {
            case "user":
                if isBoardWakeUser(obj) {
                    // Our injected board-wake prompt — never user-typed. Drop it
                    // and flag the assistant turn it triggers.
                    pendingBoardWake = true
                } else if isCatchUpUser(obj) {
                    // The injected catch-up prompt is never user-typed — drop
                    // it. Its turn (tool calls + digest) restores like any
                    // normal turn: grey markers for housekeeping, text digest.
                    return
                } else if let m = parseUser(obj, askUserQuestionIds: askUserQuestionIds) {
                    // A real typed prompt ends a board-wake turn; tool_result
                    // (.system) lines mid-turn don't.
                    if m.role == .user { pendingBoardWake = false }
                    out.append(m)
                }
            case "assistant":
                if let msg = obj["message"] as? [String: Any] {
                    if let content = msg["content"] as? [[String: Any]] {
                        for c in content
                        where (c["type"] as? String) == "tool_use"
                            && (c["name"] as? String) == "AskUserQuestion" {
                            if let id = c["id"] as? String { askUserQuestionIds.insert(id) }
                        }
                    }
                    // Context gauge: every assistant call carries the model's
                    // context for that call (input + both cache figures). The
                    // last one wins, so this lands on the real final value.
                    if let usage = msg["usage"] as? [String: Any],
                       let inT = usage["input_tokens"] as? Int {
                        let cr = usage["cache_read_input_tokens"] as? Int ?? 0
                        let cc = usage["cache_creation_input_tokens"] as? Int ?? 0
                        let total = inT + cr + cc
                        if total > 0 { context = total }
                    }
                }
                if let m = parseAssistant(obj, boardWake: pendingBoardWake) { out.append(m) }
            default:
                break
            }
            // Trim in batches rather than per-append: removing one element
            // from the front of an Array is O(n), and doing it on every line
            // of a long transcript is the kind of quiet O(n²) that shows up
            // as a hang, not a crash.
            if out.count > maxMessages * 2 {
                out.removeFirst(out.count - maxMessages)
                dropped = true
            }
        }

        if out.count > maxMessages {
            out.removeFirst(out.count - maxMessages)
            dropped = true
        }
        return Restored(messages: out, contextTokens: context, truncated: cut || dropped)
    }

    /// Rebuild history across a chain of claude sessions, oldest id first.
    ///
    /// A rolling compact abandons the old claude session and starts a new
    /// one, so from the CLI's point of view the conversation is now two
    /// files. In the app it is one thread, and it stays one thread on
    /// screen — which meant nothing after a restart, because restore only
    /// ever read the current session's transcript and the scrollback the
    /// rolling compact had gone out of its way to preserve was gone the
    /// next time the app opened.
    ///
    /// Walked newest-first and stopped as soon as the window is full, so a
    /// long chain costs no more to restore than a single session does.
    static func restoreChain(cwd: String, sessionIds: [String]) -> Restored {
        var chunks: [[Message]] = []
        var context: Int? = nil
        var truncated = false
        var total = 0
        for (i, sid) in sessionIds.reversed().enumerated() where !sid.isEmpty {
            let r = restore(cwd: cwd, sessionId: sid)
            // Only the newest session's usage describes the model's CURRENT
            // context. An older one's figure is pre-compaction and would put
            // the gauge back where the compact just took it from.
            if i == 0 { context = r.contextTokens }
            if r.truncated { truncated = true }
            if r.messages.isEmpty { continue }
            chunks.append(r.messages)
            total += r.messages.count
            if total >= maxMessages { truncated = true; break }
        }
        var out = Array(chunks.reversed().joined())
        if out.count > maxMessages {
            out.removeFirst(out.count - maxMessages)
            truncated = true
        }
        return Restored(messages: out, contextTokens: context, truncated: truncated)
    }

    /// Kept for callers that only want the history.
    static func load(cwd: String, sessionId: String) -> [Message] {
        restore(cwd: cwd, sessionId: sessionId).messages
    }

    /// Last known context size for a session, read from its transcript's
    /// final assistant entry (each carries `message.usage` for that API
    /// call: input + cache read + cache creation = the model's context on
    /// that call). Lets restored tabs show a real gauge immediately
    /// instead of sitting empty until their first live turn.
    static func lastContextTokens(cwd: String, sessionId: String) -> Int? {
        restore(cwd: cwd, sessionId: sessionId).contextTokens
    }

    /// Walk the last `maxBytes` of a file line by line, newest-relevant part
    /// only, holding one chunk at a time. Returns true when the head of the
    /// file was skipped.
    ///
    /// Every line is handled inside its own autorelease pool. That is the
    /// whole point: `JSONSerialization` hands back autoreleased Foundation
    /// objects, and without a pool per line they all stay alive until the
    /// enclosing run-loop pass ends — which, during a 25-tab restore, was
    /// never, until the memory was gone.
    private static func enumerateTailLines(path: String,
                                           maxBytes: Int,
                                           _ body: (Data) -> Void) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        var truncated = false
        var start: UInt64 = 0
        if size > UInt64(maxBytes) {
            start = size - UInt64(maxBytes)
            truncated = true
        }
        guard (try? handle.seek(toOffset: start)) != nil else { return false }

        // Starting mid-file lands in the middle of a record; drop through to
        // the next newline before parsing anything.
        var skipPartial = truncated
        var buffer = Data()
        while true {
            let chunk = (try? handle.read(upToCount: 1 << 20)) ?? Data()
            if chunk.isEmpty { break }
            buffer.append(chunk)
            while let nl = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[buffer.startIndex..<nl])
                buffer.removeSubrange(buffer.startIndex...nl)
                if skipPartial { skipPartial = false; continue }
                if line.isEmpty { continue }
                autoreleasepool { body(line) }
            }
        }
        if !skipPartial, !buffer.isEmpty {
            autoreleasepool { body(buffer) }
        }
        return truncated
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

    private static func parseUser(_ obj: [String: Any],
                                  askUserQuestionIds: Set<String>) -> Message? {
        guard let msg = obj["message"] as? [String: Any] else { return nil }
        // When present, tags every tool_result in this user message as
        // a subagent's tool feedback so the renderer can nest it under
        // its parent Task card on transcript restore.
        let parentToolUseId = obj["parent_tool_use_id"] as? String
        var blocks: [ContentBlock] = []
        var isToolResultsOnly = true

        if let s = msg["content"] as? String {
            // Plain-string user content (the typical "you typed a prompt" case).
            if let notice = harnessNoticeText(s) {
                return Message(role: .system, blocks: [.text(id: UUID(), text: notice)])
            }
            let cleaned = sanitizeUserText(s)
            if !cleaned.isEmpty {
                blocks.append(.text(id: UUID(), text: cleaned))
                isToolResultsOnly = false
            }
        } else if let arr = msg["content"] as? [[String: Any]] {
            for c in arr {
                let ct = c["type"] as? String
                if ct == "text", let t = c["text"] as? String {
                    if let notice = harnessNoticeText(t) {
                        // System row, not an amber user bubble — leave
                        // isToolResultsOnly alone so the role stays .system.
                        blocks.append(.text(id: UUID(), text: notice))
                        continue
                    }
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
                    // Skip the AskUserQuestion auto-deny result (see load()).
                    if askUserQuestionIds.contains(toolUseId) { continue }
                    // Inline images (e.g. Read on a screenshot) render inline.
                    let images = ClaudeBridge.imageParts(c["content"])
                    for img in images {
                        blocks.append(.image(id: UUID(), data: img.data, mediaType: img.mediaType))
                    }
                    let isError = c["is_error"] as? Bool ?? false
                    let text = flattenToolResultContent(c["content"])
                    if images.isEmpty || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        blocks.append(.toolResult(id: UUID(),
                                                  toolUseId: toolUseId,
                                                  content: text,
                                                  isError: isError,
                                                  parentToolUseId: parentToolUseId))
                    }
                }
            }
        }

        if blocks.isEmpty { return nil }
        // tool_result-only "user" lines render as system blocks so they sit
        // visually distinct from the human-typed prompts.
        let role: MessageRole = isToolResultsOnly ? .system : .user
        return Message(role: role, blocks: blocks)
    }

    /// True when a restored "user" line is actually our injected orchestrator
    /// board-wake prompt (sent visible:false live). Matches the stable marker
    /// prefix we emit in AgentManager.deliverOrchestratorPing — a control
    /// string we control, not model output.
    private static func isBoardWakeUser(_ obj: [String: Any]) -> Bool {
        guard let msg = obj["message"] as? [String: Any] else { return false }
        let text: String
        if let s = msg["content"] as? String {
            text = s
        } else if let arr = msg["content"] as? [[String: Any]],
                  let first = arr.first(where: { ($0["type"] as? String) == "text" }),
                  let t = first["text"] as? String {
            text = t
        } else {
            return false
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("[Board update")
    }

    /// True for our injected orchestrator catch-up brief.
    private static func isCatchUpUser(_ obj: [String: Any]) -> Bool {
        guard let msg = obj["message"] as? [String: Any] else { return false }
        let text: String
        if let s = msg["content"] as? String {
            text = s
        } else if let arr = msg["content"] as? [[String: Any]],
                  let first = arr.first(where: { ($0["type"] as? String) == "text" }),
                  let t = first["text"] as? String {
            text = t
        } else {
            return false
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("[Orchestrator catch-up")
    }

    private static func parseAssistant(_ obj: [String: Any], boardWake: Bool = false) -> Message? {
        guard let msg = obj["message"] as? [String: Any],
              let content = msg["content"] as? [[String: Any]]
        else { return nil }
        // Carries through restore so subagent tool_use blocks nest
        // under their parent Task card just like in a live session.
        let parentToolUseId = obj["parent_tool_use_id"] as? String
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
                                           input: input,
                                           parentToolUseId: parentToolUseId))
                }
            default:
                break
            }
        }
        if blocks.isEmpty { return nil }
        return Message(role: .assistant, blocks: blocks, fromBoardWake: boardWake)
    }

    /// Harness-injected "user" lines the user never typed — e.g. the
    /// <task-notification> block Claude Code injects when a background
    /// command finishes. Returns a compact human-readable line to show
    /// as a muted system row, or nil when the text is a real prompt.
    private static func harnessNoticeText(_ raw: String) -> String? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.hasPrefix("<task-notification>") else { return nil }
        if let start = s.range(of: "<summary>"),
           let end = s.range(of: "</summary>"),
           start.upperBound <= end.lowerBound {
            let summary = s[start.upperBound..<end.lowerBound]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return "Background task: \(summary)"
        }
        return "Background task update"
    }

    /// Strip the synthetic tags claude code wraps system reminders and IDE
    /// notifications in. They're noise to the user.
    private static func sanitizeUserText(_ raw: String) -> String {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("<") && s.contains("system-reminder") { return "" }
        if s.hasPrefix("<command-") { return "" }
        if s.hasPrefix("<local-command-stdout>") { return "" }
        // Our injected plumbing prompts (sent visible:false live) — drop
        // them on restore; their assistant reply stays visible.
        if s.hasPrefix("[Orchestrator catch-up") { return "" }
        if s.hasPrefix("[The ManyAgents app restarted") { return "" }
        // The rolling auto-compact's reseed. Dispatched invisibly live, so it
        // has to be dropped here too or it comes back as a wall of amber the
        // next time the app opens.
        if s.hasPrefix("[Context auto-compacted") { return "" }
        return s
    }

    private static func flattenToolResultContent(_ value: Any?) -> String {
        let raw: String
        if let s = value as? String {
            raw = s
        } else if let arr = value as? [[String: Any]] {
            raw = arr.compactMap { item in
                item["type"] as? String == "text" ? item["text"] as? String : nil
            }.joined(separator: "\n")
        } else {
            raw = ""
        }
        // Strip claude's internal wrapper tags so they don't render as raw
        // pseudo-XML in the transcript. Shared helper lives on ClaudeBridge.
        return ClaudeBridge.cleanToolWrapperTags(raw)
    }
}
