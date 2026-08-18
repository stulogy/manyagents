import SwiftUI
import AppKit

/// Claude-Code-style transcript layout. Everything flows left, each turn
/// led by a colored bullet (`●` for the assistant, semantically tinted;
/// `›` for the user). No chat bubbles. Tool calls render as inline
/// `ToolName(args)` lines with indented output beneath, matching the
/// `└` corner glyph the TUI uses.
struct MessageView: View {
    let message: Message
    /// Map of Task tool_use_id → child messages spawned by that subagent.
    /// ConversationView builds this dictionary up-front; we look up by
    /// the Task's own toolUseId when we encounter its block so the
    /// nested-card renderer can show every subagent step in place.
    /// Defaults to empty so the type stays drop-in.
    var subagentChildren: [String: [Message]] = [:]
    /// Tool-use ids of Task/Agent (sub-agent) calls. A tool result whose id is
    /// in here is a sub-agent report and gets markdown-formatted; all other
    /// results (Bash/Grep/Read/…) render monospace.
    var subagentToolUseIds: Set<String> = []
    /// Outcome of each file-edit tool call (Edit/Write/…), keyed by its
    /// tool_use id: `true` = errored, `false` = succeeded. Built across
    /// messages by ConversationView (tool_use and its result live in
    /// separate messages). A *successful* edit's verbose result row is
    /// suppressed and shown as a ✓ on the tool card instead; errors like
    /// "File has not been read yet" still render as their own row.
    var fileEditOutcomes: [String: Bool] = [:]
    /// tool_use ids of orchestrator housekeeping calls (set_notes, board
    /// reads…). Their tool_use renders as a grey marker; their results
    /// are suppressed entirely.
    var housekeepingToolUseIds: Set<String> = []
    /// AskUserQuestion answers the user has given this session, keyed by the
    /// question's tool_use id. Lets us render a permanent "you chose X" card
    /// where the (otherwise skipped) AskUserQuestion tool_use sits, so the
    /// decision stays in the transcript after the live picker chip clears.
    var answeredQuestions: [String: AgentSession.AnsweredAsk] = [:]
    /// cwd of the owning session — passed through to MarkdownText so
    /// relative file paths in code spans (`notes/foo.html`) can be
    /// resolved against the project root and autolinked.
    var sessionCwd: String? = nil
    /// Source-session id used by the "Send to →" hand-off button.
    /// nil disables the action (e.g. transcript-only message views
    /// where there's no owning session to hand off from).
    var sessionId: UUID? = nil
    /// Active ⌘F query — matching substrings in this message's text get a
    /// highlight background. Empty when find is closed.
    var highlight: String = ""
    /// True when this message is the one the find bar is currently parked on,
    /// so it gets a framed background to stand out from other matches.
    var isCurrentMatch: Bool = false
    @EnvironmentObject private var manager: AgentManager
    @State private var hover = false
    @State private var copyConfirmed = false
    /// Set when the user clicks an inline image to open the zoom view.
    @State private var zoomedImage: ZoomedImage?

    var body: some View {
        // Skip the row entirely when every block is empty/skipped —
        // otherwise the marker renders as an orphan colored dot with
        // nothing beside it.
        if isRenderableEmpty {
            EmptyView()
        } else {
            ZStack(alignment: .topTrailing) {
                HStack(alignment: .top, spacing: 10) {
                    marker
                        .frame(width: 14, alignment: .center)
                        .padding(.top, 3)
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(message.blocks) { block in
                            blockView(block)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // Reserve a gutter at the trailing edge so the hover
                    // toolbar (overlaid top-right) never sits on top of a
                    // full-width first line. Sized to the compact icon
                    // toolbar; static so hovering doesn't reflow the text.
                    .padding(.trailing, 36)
                }
                // Always in the tree, just invisible when not hovering —
                // so it can't disappear out from under the cursor mid-
                // click. opacity + allowsHitTesting toggle together.
                copyButton
                    .opacity(hover ? 1 : 0)
                    .allowsHitTesting(hover)
                    .animation(.easeOut(duration: 0.12), value: hover)
            }
            // Make the entire row's frame hit-testable for hover, not
            // just the text glyphs. Without this the cursor leaving a
            // wrapped line's trailing whitespace flips hover off and
            // takes the button with it before the user can click.
            .contentShape(Rectangle())
            .onHover { h in
                hover = h
                if !h { copyConfirmed = false }
            }
            // Frame the message the find bar is currently parked on.
            .padding(isCurrentMatch ? 8 : 0)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.brandOrange.opacity(isCurrentMatch ? 0.10 : 0))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.brandOrange.opacity(isCurrentMatch ? 0.45 : 0), lineWidth: 1)
            )
            .animation(.easeOut(duration: 0.15), value: isCurrentMatch)
            .sheet(item: $zoomedImage) { z in
                ImageZoomView(data: z.data)
            }
        }
    }

    @ViewBuilder
    private var copyButton: some View {
        Button {
            copyMessageToClipboard()
            withAnimation(.easeOut(duration: 0.12)) { copyConfirmed = true }
            // Reset the checkmark after a short beat so the user gets
            // visual confirmation without the icon staying changed.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                withAnimation(.easeOut(duration: 0.12)) { copyConfirmed = false }
            }
        } label: {
            Image(systemName: copyConfirmed ? "checkmark" : "doc.on.doc")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(copyConfirmed ? .green : .secondary)
                .frame(width: 22, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor).opacity(0.9))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .stroke(Color.primary.opacity(0.12), lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
        .help(copyConfirmed ? "Copied" : "Copy this message")
        .padding(.top, 2)
        .padding(.trailing, 2)
    }

    /// Concatenate the message's content into a clean copyable text
    /// representation. Skips empty thinking blocks, formats tool calls
    /// and results inline so the copied text reads like a transcript.
    private func copyMessageToClipboard() {
        var pieces: [String] = []
        for block in message.blocks {
            switch block {
            case .text(_, let t):
                let trimmed = t.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { pieces.append(trimmed) }
            case .thinking(_, let t):
                let trimmed = t.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { pieces.append("[thinking] \(trimmed)") }
            case .toolUse(_, _, let name, let input, _):
                let summary = input.compactMap { (k, v) -> String? in
                    guard let s = v.stringValue, !s.isEmpty else { return nil }
                    return "\(k): \(s)"
                }.joined(separator: ", ")
                pieces.append(summary.isEmpty ? "[\(name)]" : "[\(name)] \(summary)")
            case .toolResult(_, _, let content, let isError, _):
                let prefix = isError ? "[error] " : ""
                pieces.append(prefix + content.trimmingCharacters(in: .whitespacesAndNewlines))
            case .image:
                pieces.append("[image]")
            }
        }
        let text = pieces.joined(separator: "\n\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private var isRenderableEmpty: Bool {
        // Silent orchestrator board-checks: a wake turn that took no action
        // (no tool_use — just "holding…" narration) is housekeeping, not
        // conversation. Hide it entirely so it never floods the transcript.
        // Wake turns that DID act (send_to_agent etc.) still render.
        if message.fromBoardWake && !message.hasToolUse { return true }
        return message.blocks.allSatisfy { block in
            switch block {
            case .text(_, let t):     return t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case .thinking(_, let t): return t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case .toolUse(_, let id, let name, _, _):
                // An unanswered AskUserQuestion renders nothing (the live
                // picker owns it), so a message holding only one is empty.
                // Every other tool_use renders a card → never empty.
                return name == "AskUserQuestion" && answeredQuestions[id] == nil
            case .toolResult(_, let id, let c, _, _):
                // Suppressed edit-success results render nothing, so a
                // message holding only one must count as empty — otherwise
                // it leaves an orphan marker dot with nothing beside it.
                if fileEditOutcomes[id] == false { return true }
                if housekeepingToolUseIds.contains(id) { return true }
                if Self.isBackgroundLaunchMetadata(c) { return true }
                return c.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case .image:              return false
            }
        }
    }

    // MARK: - Marker

    @ViewBuilder
    private var marker: some View {
        switch message.role {
        case .user:
            Text("›")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Color.brandOrange)
        case .assistant:
            Circle()
                .fill(markerColor)
                .frame(width: 8, height: 8)
        case .system:
            Image(systemName: "circle.dotted")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
    }

    /// Semantic color for the assistant bullet — defaults to white for
    /// plain prose; shifts to a tool tint or thinking-purple based on
    /// what the message actually contains.
    private var markerColor: Color {
        var hasTool = false
        var hasThinking = false
        var hasText = false
        for block in message.blocks {
            switch block {
            case .toolUse:
                hasTool = true
            case .thinking(_, let t):
                // Only count thinking blocks with actual content — empty
                // ones tint the marker purple while rendering nothing.
                if !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    hasThinking = true
                }
            case .text(_, let t):
                if !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    hasText = true
                }
            default:
                break
            }
        }
        if hasTool { return Color.activeHighlight }
        if hasThinking && !hasText { return .purple }
        return .white
    }

    /// True when this tool_use is the "dispatch a subagent" tool. Claude
    /// Code used to call it `Task`; recent versions (≥2.1.144) renamed
    /// to `Agent`. We accept either name, and also fall back to checking
    /// for the `subagent_type` input key so a future rename still works.
    static func isSubagentTool(name: String, input: [String: AnyCodable]) -> Bool {
        if name == "Task" || name == "Agent" { return true }
        return input["subagent_type"]?.stringValue?.isEmpty == false
    }

    /// File-mutating tools whose success confirmation ("…updated
    /// successfully") is noise the tool card already conveys — we fold a
    /// successful result into a ✓ on the card rather than a separate row.
    static func isFileEditTool(_ name: String) -> Bool {
        name == "Edit" || name == "Write" || name == "MultiEdit" || name == "NotebookEdit"
    }

    /// Detection lives on MCPConnectors (AgentSession uses it too for the
    /// composer banner); kept as a pass-through so call sites read local.
    static func mcpAuthNeededServer(in content: String) -> String? {
        MCPConnectors.authNeededServer(in: content)
    }

    /// The subagent/background-agent launch acknowledgment — pure internal
    /// orchestration metadata (agent id, SendMessage instructions) that the
    /// Task/Agent card already represents. Hidden from the transcript.
    static func isBackgroundLaunchMetadata(_ content: String) -> Bool {
        content.contains("Async agent launched successfully")
            || content.contains("This tool result is internal metadata")
    }

    /// Classify an injected user-role message into a banner (label, body).
    /// nil = a real typed prompt (renders as the amber bubble).
    static func syntheticUserBanner(_ text: String) -> (label: String, body: String)? {
        let label: String
        if text.hasPrefix("[Compacted from prior conversation") {
            label = "Conversation compacted"
        } else if text.hasPrefix("[Message from orchestrator") {
            label = "Message from Orchestrator"
        } else if text.hasPrefix("[Message from tab") {
            // Worker pinged the orchestrator (notify_orchestrator).
            let name = text.split(separator: "\"").dropFirst().first.map(String.init)
            label = name.map { "Message from \($0)" } ?? "Message from a tab"
        } else if text.hasPrefix("[Tab \"") {
            // Auto-report: a dispatched worker tab finished its work and the
            // manager woke the orchestrator once to check on it.
            let name = text.split(separator: "\"").dropFirst().first.map(String.init)
            label = name.map { "\($0) stopped" } ?? "A dispatched tab stopped"
        } else {
            return nil
        }
        let body: String = {
            guard let close = text.range(of: "]") else { return text }
            return String(text[close.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }()
        return (label, body)
    }

    /// Grey-marker label for orchestrator housekeeping tools; nil for
    /// tools that keep their full card (send_to_agent, new_agent,
    /// open_preview — real actions worth auditing).
    static func housekeepingLabel(_ name: String) -> String? {
        switch name {
        case "mcp__manyagents__set_notes":     return "Orchestrator updated its notes"
        case "mcp__manyagents__list_agents":   return "Orchestrator checked the board"
        case "mcp__manyagents__read_agent":    return "Orchestrator read a tab"
        case "mcp__manyagents__mute_agent":    return "Orchestrator muted a tab"
        case "mcp__manyagents__unmute_agent":  return "Orchestrator unmuted a tab"
        case "mcp__manyagents__send_to_agent": return "Orchestrator messaged a tab"
        case "mcp__manyagents__new_agent":     return "Orchestrator started a tab"
        case "mcp__manyagents__rename_agent":  return "Orchestrator renamed a tab"
        case "mcp__manyagents__compact_agent": return "Orchestrator compacted a tab"
        case "mcp__manyagents__close_agent":   return "Orchestrator closed a tab"
        case "mcp__manyagents__notify_orchestrator": return "Pinged the orchestrator"
        default: return nil
        }
    }

    // MARK: - Block rendering

    @ViewBuilder
    private func blockView(_ block: ContentBlock) -> some View {
        switch block {
        case .text(_, let text):
            switch message.role {
            case .user:
                if let synthetic = Self.syntheticUserBanner(text) {
                    // Injected user-role text (compaction seed, inter-tab
                    // orchestrator message) is plumbing, not something the
                    // user typed — one grey banner, content behind a toggle,
                    // never an amber bubble.
                    SyntheticUserRow(label: synthetic.label, content: synthetic.body)
                } else {
                Text(SearchHighlight.attributed(text, query: highlight))
                    .userTextStyle()
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.brandOrange.opacity(0.18))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(Color.brandOrange.opacity(0.28), lineWidth: 0.5)
                    )
                }
            case .assistant:
                // Block-level markdown — headings, code blocks, lists,
                // blockquotes, inline code, links. Inline `code` spans
                // get a tinted monospace treatment so they actually
                // look like code in flowing text.
                VStack(alignment: .leading, spacing: 6) {
                    MarkdownText(raw: text, sessionCwd: sessionCwd, highlight: highlight)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let url = localhostURL(in: text) {
                        Button {
                            // User-initiated (they clicked the pill), so
                            // focusing the browser is expected.
                            if let id = sessionId {
                                manager.previewURLs[id] = url
                            }
                            manager.previewActive = true
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "globe")
                                    .font(.system(size: 10, weight: .semibold))
                                Text("Open \(url.host ?? "localhost"):\(url.port.map(String.init) ?? "") in Preview")
                                    .font(.system(size: 11, weight: .medium))
                            }
                            .foregroundStyle(Color.brandOrange)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .background(
                                Capsule().fill(Color.brandOrange.opacity(0.12))
                            )
                            .overlay(Capsule().strokeBorder(Color.brandOrange.opacity(0.3), lineWidth: 0.5))
                        }
                        .buttonStyle(.plain)
                    }
                }
            case .system:
                if text.hasPrefix("⚠") {
                    // Turn-error notice (AgentSession.appendErrorNotice) —
                    // the red tab dot alone left the user guessing what broke.
                    Text(SearchHighlight.attributed(text, query: highlight))
                        .font(AppFont.mono(11.5))
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.red.opacity(0.08)))
                } else {
                    Text(SearchHighlight.attributed(text, query: highlight))
                        .font(AppFont.mono(11.5))
                        .foregroundStyle(.secondary)
                }
            }
        case .thinking(_, let text):
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // Italic dim line, "*"-prefixed in the spirit of the TUI's
                // "* Cogitated for 3m 37s" status format.
                HStack(alignment: .top, spacing: 6) {
                    Text("✻")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.purple.opacity(0.8))
                        .padding(.top, 1)
                    Text(text)
                        .font(AppFont.assistantProse(13))
                        .italic()
                        .lineSpacing(3)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .multilineTextAlignment(.leading)
                }
            }
        case .toolUse(_, let toolUseId, let name, let input, _):
            // Orchestrator housekeeping renders as a one-line grey marker —
            // the user wants to SEE that an event happened without the
            // under-the-hood payload. Works for live and restored
            // transcripts alike because it's pure rendering.
            if let label = Self.housekeepingLabel(name) {
                HStack(spacing: 6) {
                    Image(systemName: "brain.head.profile")
                        .font(.system(size: 10, weight: .semibold))
                    Text(label)
                        .font(.system(size: 11.5, weight: .medium))
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(Color.primary.opacity(0.05)))
            } else if name == "AskUserQuestion" {
                // While pending, the live picker (below the conversation)
                // owns the question — render nothing here. Once answered,
                // leave a permanent record of the choice in the transcript.
                if let answered = answeredQuestions[toolUseId] {
                    AnsweredQuestionCard(state: answered.state, answer: answered.answer)
                } else {
                    EmptyView()
                }
            } else if Self.isSubagentTool(name: name, input: input) {
                // Subagent dispatch tool — claude code calls this
                // "Task" historically, "Agent" in recent versions
                // (≥2.1.144). Either way, the input carries
                // `subagent_type`, `description`, and `prompt`. Render
                // the parent card whether or not children are bucketed
                // yet — we want the "what was dispatched" header to
                // appear even before the subagent has streamed any
                // child activity.
                TaskExpansionCard(
                    input: input,
                    children: subagentChildren[toolUseId] ?? [],
                    sessionId: sessionId
                )
            } else {
                // For file-edit tools, fold a successful result into a ✓
                // on the card (succeeded: true). `nil` for pending edits,
                // edit errors, and every non-edit tool — those are
                // unaffected.
                ToolUseCard(toolName: name, input: input,
                            succeeded: fileEditOutcomes[toolUseId] == false ? true : nil)
            }
        case .toolResult(_, let toolUseId, let content, let isError, _):
            // A successful file-edit result ("…updated successfully") is
            // redundant with the tool card's ✓ — suppress it. Edit *errors*
            // (isError → outcome true) and all non-edit results still render.
            if fileEditOutcomes[toolUseId] == false || housekeepingToolUseIds.contains(toolUseId)
                || Self.isBackgroundLaunchMetadata(content) {
                // The subagent/background-launch ack is internal plumbing
                // ("Async agent launched successfully… agentId… SendMessage
                // …") — the Task/Agent card above already shows the dispatch,
                // so hide the raw metadata dump.
                EmptyView()
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ToolResultRow(content: content, isError: isError, sessionCwd: sessionCwd,
                                  isSubagentResult: subagentToolUseIds.contains(toolUseId))
                    // An MCP server refused for lack of auth — offer the fix
                    // inline instead of the dead-end "run /mcp" instruction
                    // (headless sessions have no /mcp).
                    if let server = Self.mcpAuthNeededServer(in: content) {
                        MCPAuthorizeButton(serverName: server)
                    }
                }
            }
        case .image(_, let data, _):
            if let img = NSImage(data: data) {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: 480, maxHeight: 360)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(Color.primary.opacity(0.15), lineWidth: 0.5)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .onTapGesture { zoomedImage = ZoomedImage(data: data) }
                    .onHover { NSCursor.pointingHand.set(); if !$0 { NSCursor.arrow.set() } }
                    .help("Click to zoom")
            }
        }
    }

    /// Tool output is the noisiest part of most conversations — long psql
    /// dumps, file reads, test output. We render it indented under the
    /// `└` corner like the TUI does, but collapse anything beyond a few
    /// lines behind a disclosure so the assistant's actual insight stays
    /// visible without scrolling past walls of data.
    private struct ToolResultRow: View {
        let content: String
        let isError: Bool
        var sessionCwd: String? = nil
        /// True only when this result came from a Task/Agent sub-agent — those
        /// are markdown prose reports worth formatting. Everything else stays
        /// monospace, so shell output (e.g. `=== banner ===` lines, `#`
        /// comments) isn't parsed into giant setext/ATX headings.
        var isSubagentResult: Bool = false
        @State private var expanded = false
        @State private var showingReportSheet = false

        private var rendersAsMarkdown: Bool { isSubagentResult && !isError }

        // Line budget — short multi-line output passes through; longer
        // collapses to the first few lines.
        private static let collapsedLineCount = 3
        private static let alwaysExpandLineThreshold = 5

        // Character budget — catches `gh pr view --json` and similar
        // one-fat-line outputs that the line budget alone misses. Any
        // content over `alwaysExpandCharThreshold` chars gets clipped
        // to `collapsedCharBudget` chars regardless of line count.
        private static let collapsedCharBudget = 400
        private static let alwaysExpandCharThreshold = 800

        private var lines: [String] {
            content.components(separatedBy: "\n")
        }

        private var exceedsLineBudget: Bool {
            lines.count > Self.alwaysExpandLineThreshold
        }

        private var exceedsCharBudget: Bool {
            content.count > Self.alwaysExpandCharThreshold
        }

        /// Truncate by lines first (preserves vertical structure for
        /// multi-line dumps), then by chars (catches single-fat-line
        /// JSON / minified blobs). Either trigger fires the disclosure.
        ///
        /// On expand, single-line JSON payloads (e.g. `gh pr view --json`)
        /// are re-serialised pretty-printed so they're actually readable.
        /// The collapsed preview stays the dense inline form — more info
        /// per pixel when you're just glancing at it.
        private var visibleText: String {
            if expanded {
                return Self.prettyPrintedJSON(content) ?? content
            }
            var trimmed = content
            if exceedsLineBudget {
                trimmed = lines.prefix(Self.collapsedLineCount).joined(separator: "\n")
            }
            if exceedsCharBudget && trimmed.count > Self.collapsedCharBudget {
                trimmed = String(trimmed.prefix(Self.collapsedCharBudget))
            }
            return trimmed
        }

        /// Re-serialise a JSON string with indentation. Returns nil if
        /// the input isn't JSON, so the caller can fall back to raw.
        /// Skips multi-MB payloads to avoid stutter on the render path.
        private static func prettyPrintedJSON(_ s: String) -> String? {
            guard s.count < 256_000 else { return nil }
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let first = trimmed.first, first == "{" || first == "[" else { return nil }
            guard let data = trimmed.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data, options: []),
                  let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted])
            else { return nil }
            return String(data: pretty, encoding: .utf8)
        }

        /// Compact "N more lines" / "Nk more chars" label so the user
        /// knows what's hiding without having to expand to check.
        private var hiddenSummary: String {
            let visibleLen = visibleText.count
            let hiddenChars = max(0, content.count - visibleLen)
            if exceedsLineBudget {
                let hiddenLines = max(0, lines.count - Self.collapsedLineCount)
                return "\(hiddenLines) more line\(hiddenLines == 1 ? "" : "s")"
            }
            if hiddenChars == 0 { return "" }
            if hiddenChars < 1000 { return "\(hiddenChars) more chars" }
            return String(format: "%.1fk more chars", Double(hiddenChars) / 1000)
        }

        private var shouldShowDisclosure: Bool {
            !expanded && (exceedsLineBudget || exceedsCharBudget)
        }

        /// Fallback when a tool returns no content but did set isError —
        /// otherwise the row renders as just a `└` with nothing next to
        /// it, and the failure becomes invisible.
        private var displayText: String {
            let v = visibleText
            if v.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return isError ? "(tool error — no detail returned)" : "(empty)"
            }
            return v
        }

        /// Markdown counterpart to `visibleText`: when collapsed and over
        /// budget, render only the first few lines as a teaser. Truncate by
        /// line only (never mid-character) so the preview's markdown still
        /// parses cleanly.
        private var markdownPreview: String {
            guard !expanded, exceedsLineBudget || exceedsCharBudget else { return content }
            return lines.prefix(Self.collapsedLineCount).joined(separator: "\n")
        }

        /// Expand-button text. Reports get a friendlier "Show full report"
        /// with the size hint appended; raw output keeps the bare hint.
        private var expandLabel: String {
            guard rendersAsMarkdown else { return hiddenSummary }
            let hint = hiddenSummary
            return hint.isEmpty ? "Show full report" : "Show full report · \(hint)"
        }

        /// Expand / collapse pill, shared by the markdown and raw-output
        /// branches so both fold long content the same way.
        @ViewBuilder
        private var disclosureControls: some View {
            if shouldShowDisclosure {
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { expanded = true }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                        Text(expandLabel)
                            .font(.system(size: 10.5, weight: .medium))
                    }
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.primary.opacity(0.05)))
                }
                .buttonStyle(.plain)
                .help("Show full output")
            } else if expanded && (exceedsLineBudget || exceedsCharBudget) {
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { expanded = false }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.up")
                            .font(.system(size: 9, weight: .semibold))
                        Text("Collapse")
                            .font(.system(size: 10.5, weight: .medium))
                    }
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.primary.opacity(0.05)))
                }
                .buttonStyle(.plain)
            }
        }

        var body: some View {
            HStack(alignment: .top, spacing: 6) {
                Text("└")
                    .font(AppFont.mono(13))
                    .foregroundStyle(isError ? .red.opacity(0.75) : .secondary.opacity(0.6))
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 4) {
                    if rendersAsMarkdown {
                        // Subagent reports are often two screens tall — keep
                        // only a teaser in the transcript and open the full
                        // thing in a focused modal (never dump it inline).
                        MarkdownText(raw: markdownPreview, sessionCwd: sessionCwd)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if shouldShowDisclosure {
                            reportButton
                        }
                    } else {
                        Text(displayText)
                            .font(AppFont.mono(12))
                            .foregroundStyle(isError ? .red : .secondary)
                            .lineSpacing(2)
                            .multilineTextAlignment(.leading)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        disclosureControls
                    }
                }
            }
            .sheet(isPresented: $showingReportSheet) {
                ReportSheet(markdown: content, sessionCwd: sessionCwd)
            }
        }

        /// Pill under a report teaser that opens the full report in a modal.
        private var reportButton: some View {
            Button { showingReportSheet = true } label: {
                HStack(spacing: 4) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 9, weight: .semibold))
                    Text(hiddenSummary.isEmpty ? "Read full report" : "Read full report · \(hiddenSummary)")
                        .font(.system(size: 10.5, weight: .medium))
                }
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.primary.opacity(0.05)))
            }
            .buttonStyle(.plain)
            .help("Open the full report in a window")
        }
    }

    /// Focused modal reading view for a long sub-agent report — keeps the
    /// transcript clean while giving the full markdown a scrollable surface.
    private struct ReportSheet: View {
        let markdown: String
        var sessionCwd: String? = nil
        @Environment(\.dismiss) private var dismiss
        @State private var copied = false

        var body: some View {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "doc.text")
                        .foregroundStyle(Color.brandOrange)
                    Text("Report")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(markdown, forType: .string)
                        withAnimation { copied = true }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                            withAnimation { copied = false }
                        }
                    } label: {
                        Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(copied ? .green : .secondary)
                    }
                    .buttonStyle(.plain)
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                Divider()
                ScrollView {
                    MarkdownText(raw: markdown, sessionCwd: sessionCwd)
                        .padding(18)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
            }
            .frame(width: 720, height: 580)
        }
    }

    private func asAttributed(_ raw: String) -> AttributedString {
        if let parsed = try? AttributedString(markdown: raw,
                                              options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            return parsed
        }
        return AttributedString(raw)
    }

    /// Parent card for a Task tool_use (subagent dispatch). Renders the
    /// prompt one-liner up top, then a collapsible disclosure of every
    /// child block produced by the subagent (its own tool calls + their
    /// results + any prose it streamed). Without this, those child
    /// blocks sprawl as disconnected top-level rows because the renderer
    /// has no idea they belong together.
    private struct TaskExpansionCard: View {
        let input: [String: AnyCodable]
        /// Messages whose blocks all belong to this Task (parent_tool_use_id
        /// matches). Ordered as they arrived from the stream.
        let children: [Message]
        /// User-controlled expansion. nil = "follow the running auto-
        /// expand behavior"; non-nil = "user clicked, honor it." Stops
        /// the card from collapsing under the user's mouse when the
        /// session flips status mid-streaming.
        @State private var userExpansion: Bool?
        /// Auto-expand while session is running so the user can watch
        /// subagent activity without clicking. Falls back to false
        /// (collapsed) when the session is idle / waiting / errored.
        @EnvironmentObject private var manager: AgentManager
        var sessionId: UUID?

        private var sessionRunning: Bool {
            guard let sessionId,
                  let s = manager.sessions.first(where: { $0.id == sessionId })
            else { return false }
            return s.status == .running
        }

        private var expanded: Bool {
            // Collapsed by default — the header shows the subagent + step count;
            // click to expand. (Previously auto-expanded while the session ran,
            // which dumped dozens of nested steps into the transcript.)
            userExpansion ?? false
        }

        /// One-line prompt summary pulled from the standard Task input keys.
        private var prompt: String {
            // claude code's Task tool takes `description` (short) and
            // `prompt` (the actual subagent instruction). Prefer the
            // description for the header; fall back to the first line of
            // prompt.
            if let d = input["description"]?.stringValue, !d.isEmpty {
                return d
            }
            if let p = input["prompt"]?.stringValue, !p.isEmpty {
                return p.components(separatedBy: "\n").first ?? p
            }
            return "Subagent task"
        }

        private var subagentName: String {
            input["subagent_type"]?.stringValue ?? "Agent"
        }

        /// Flat list of (toolUse, matching toolResult?) pairs across all
        /// child messages — what the subagent actually did, ordered.
        /// Used for the step count + the expanded body.
        private var steps: [SubagentStep] {
            var out: [SubagentStep] = []
            // Index toolResults by toolUseId so we can match in a single
            // pass without an O(N²) lookup.
            var resultByToolUse: [String: (content: String, isError: Bool)] = [:]
            for msg in children {
                for block in msg.blocks {
                    if case .toolResult(_, let id, let content, let isError, _) = block {
                        resultByToolUse[id] = (content, isError)
                    }
                }
            }
            for msg in children {
                for block in msg.blocks {
                    switch block {
                    case .toolUse(_, let toolUseId, let name, let bInput, _):
                        let result = resultByToolUse[toolUseId]
                        out.append(SubagentStep(
                            id: block.id,
                            kind: .tool(name: name, input: bInput, result: result)
                        ))
                    case .text(_, let t):
                        let trimmed = t.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty {
                            out.append(SubagentStep(id: block.id, kind: .text(trimmed)))
                        }
                    case .thinking(_, let t):
                        let trimmed = t.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty {
                            out.append(SubagentStep(id: block.id, kind: .thinking(trimmed)))
                        }
                    default:
                        break
                    }
                }
            }
            return out
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 0) {
                header
                if expanded && !steps.isEmpty {
                    Divider().background(Color.primary.opacity(0.06))
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(steps) { step in
                            StepRow(step: step)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.activeHighlight.opacity(0.35), lineWidth: 0.5)
            )
        }

        private var header: some View {
            Button {
                withAnimation(.easeOut(duration: 0.15)) {
                    userExpansion = !(userExpansion ?? expanded)
                }
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Image(systemName: "network")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.activeHighlight)
                        Text(subagentName)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.activeHighlight)
                        Text(prompt)
                            .font(.system(size: 12))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if sessionRunning && !expanded {
                            // tiny pulse so a running collapsed card
                            // doesn't read as "done."
                            Circle()
                                .fill(Color.activeHighlight)
                                .frame(width: 5, height: 5)
                                .opacity(0.9)
                        }
                        if !steps.isEmpty {
                            Text("\(steps.count) step\(steps.count == 1 ? "" : "s")")
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundStyle(.tertiary)
                        }
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                    // Inline "what's it doing right now" line — only
                    // when collapsed, only when there's actually a
                    // current step worth surfacing. Means a collapsed
                    // running subagent still telegraphs progress
                    // ("running Bash: pnpm test") without a click.
                    if !expanded, let preview = currentStepPreview {
                        Text(preview)
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.leading, 20)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
            .buttonStyle(.plain)
        }

        /// "running <ToolName>: <one-liner arg>" pulled from the most
        /// recent tool step, or "<thinking text…>" / "<assistant text…>"
        /// if the latest step is a thought rather than a tool call.
        /// nil when there's no step yet (header alone tells the story).
        private var currentStepPreview: String? {
            guard let last = steps.last else { return nil }
            switch last.kind {
            case .tool(let name, let input, _):
                let arg = StepRow.firstStringValue(input)
                if arg.isEmpty { return "running \(name)" }
                return "\(name): \(arg)"
            case .text(let t):
                return "\(t.prefix(80))"
            case .thinking(let t):
                return "thinking: \(t.prefix(70))"
            }
        }

        /// One pair of (subagent action, optional result) rendered inside
        /// the expanded panel. Kept compact — the user has already opted
        /// into seeing detail, but it should still read as "summary",
        /// not as a full transcript turn.
        private struct StepRow: View {
            let step: SubagentStep
            @State private var resultExpanded = false

            var body: some View {
                switch step.kind {
                case .tool(let name, let input, let result):
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Image(systemName: iconName(for: name))
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .frame(width: 12)
                            Text(name)
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .foregroundStyle(.primary)
                            Text(oneLine(input))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            if let r = result, r.isError {
                                Text("error")
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundStyle(.red)
                            }
                        }
                        if let r = result {
                            ResultPeek(content: r.content, isError: r.isError)
                                .padding(.leading, 18)
                        }
                    }
                case .text(let t):
                    HStack(alignment: .top, spacing: 6) {
                        Text("·")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .frame(width: 12)
                        Text(t)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                case .thinking(let t):
                    HStack(alignment: .top, spacing: 6) {
                        Text("✻")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.purple.opacity(0.7))
                            .frame(width: 12)
                        Text(t)
                            .font(.system(size: 11))
                            .italic()
                            .foregroundStyle(.tertiary)
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }

            private func iconName(for tool: String) -> String {
                switch tool {
                case "Bash":              return "terminal"
                case "Read":              return "doc.text"
                case "Edit", "MultiEdit": return "pencil"
                case "Write":             return "square.and.pencil"
                case "Grep", "Glob":      return "magnifyingglass"
                case "WebFetch", "WebSearch": return "globe"
                default:                  return "wrench.adjustable"
                }
            }

            /// Compact one-line summary of a tool's args. Prefers
            /// `command`, then `file_path`, then `pattern`, then first
            /// string value found. Long values truncated mid-string.
            private func oneLine(_ input: [String: AnyCodable]) -> String {
                Self.firstStringValue(input)
            }

            /// Reusable helper — exposed so the parent card's inline
            /// "current step" preview can build the same one-liner.
            static func firstStringValue(_ input: [String: AnyCodable]) -> String {
                let priority = ["command", "file_path", "path", "pattern", "url", "query", "description"]
                for key in priority {
                    if let s = input[key]?.stringValue, !s.isEmpty {
                        return s
                    }
                }
                for (_, v) in input {
                    if let s = v.stringValue, !s.isEmpty { return s }
                }
                return ""
            }
        }

        private struct ResultPeek: View {
            let content: String
            let isError: Bool
            @State private var expanded = false

            private static let collapsedLines = 2

            private var lines: [String] {
                content.components(separatedBy: "\n")
            }

            var body: some View {
                let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(expanded
                             ? content
                             : lines.prefix(Self.collapsedLines).joined(separator: "\n"))
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(isError ? .red : .secondary)
                            .lineSpacing(1.5)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                        if lines.count > Self.collapsedLines {
                            Button {
                                withAnimation(.easeOut(duration: 0.12)) { expanded.toggle() }
                            } label: {
                                Text(expanded
                                     ? "Collapse"
                                     : "\(lines.count - Self.collapsedLines) more lines")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(.tertiary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    /// One unit of subagent activity used by TaskExpansionCard.
    private struct SubagentStep: Identifiable {
        let id: UUID
        let kind: Kind

        enum Kind {
            case tool(name: String, input: [String: AnyCodable],
                      result: (content: String, isError: Bool)?)
            case text(String)
            case thinking(String)
        }
    }
}

/// Extracts the first localhost / 127.0.0.1 URL from a text block so the
/// conversation can surface a one-tap "Open in Preview" button.
private func localhostURL(in text: String) -> URL? {
    let pattern = #"https?://(localhost|127\.0\.0\.1)(:\d+)?(/\S*)?"#
    guard let regex = try? NSRegularExpression(pattern: pattern),
          let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
          let range = Range(match.range, in: text)
    else { return nil }
    return URL(string: String(text[range]))
}

/// Identifiable wrapper so an inline image can drive a `.sheet(item:)`.
struct ZoomedImage: Identifiable {
    let id = UUID()
    let data: Data
}

/// Click-to-zoom viewer for an inline chat image. Pinch / scroll to zoom,
/// drag to pan when zoomed in, double-click to toggle 1×/2×, Esc or Done to
/// close, Copy to put it on the clipboard.
private struct ImageZoomView: View {
    let data: Data
    @Environment(\.dismiss) private var dismiss
    @State private var scale: CGFloat = 1
    @State private var steady: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var steadyOffset: CGSize = .zero
    @State private var copied = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "photo")
                    .foregroundStyle(Color.brandOrange)
                Text("Image")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button {
                    if let img = NSImage(data: data) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.writeObjects([img])
                    }
                    withAnimation { copied = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                        withAnimation { copied = false }
                    }
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(copied ? .green : .secondary)
                }
                .buttonStyle(.plain)
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            Divider()
            imageArea
        }
        .frame(width: 920, height: 720)
    }

    @ViewBuilder
    private var imageArea: some View {
        if let img = NSImage(data: data) {
            Image(nsImage: img)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .scaleEffect(scale)
                .offset(offset)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black.opacity(0.15))
                .clipped()
                .contentShape(Rectangle())
                .gesture(
                    MagnificationGesture()
                        .onChanged { v in scale = max(1, min(8, steady * v)) }
                        .onEnded { _ in
                            steady = scale
                            if scale <= 1 { offset = .zero; steadyOffset = .zero }
                        }
                )
                .simultaneousGesture(
                    DragGesture()
                        .onChanged { v in
                            guard scale > 1 else { return }
                            offset = CGSize(width: steadyOffset.width + v.translation.width,
                                            height: steadyOffset.height + v.translation.height)
                        }
                        .onEnded { _ in steadyOffset = offset }
                )
                .onTapGesture(count: 2) {
                    withAnimation(.easeOut(duration: 0.2)) {
                        if scale > 1 { scale = 1; steady = 1; offset = .zero; steadyOffset = .zero }
                        else { scale = 2; steady = 2 }
                    }
                }
        } else {
            Text("Couldn't load image.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// Inline "authorize this MCP server" affordance shown under a tool
/// result that reported an authentication-required failure. Runs the
/// CLI's own `claude mcp login` flow via MCPConnectors; on success the
/// session's process is recycled (AgentManager listens for the auth
/// notification), so the user just sends their next message.
struct MCPAuthorizeButton: View {
    let serverName: String
    @ObservedObject private var connectors = MCPConnectors.shared

    private var isRunning: Bool { connectors.loginInFlight == serverName }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                // Tap toggles: idle → start the flow; running → cancel it
                // (the browser attempt errored, or wrong account — let the
                // user bail instead of waiting out the watcher).
                if isRunning {
                    MCPConnectors.shared.cancelLogin()
                } else {
                    MCPConnectors.shared.login(serverName)
                }
            } label: {
                HStack(spacing: 5) {
                    if isRunning {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "key.fill")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    Text(isRunning ? "Authorizing \(serverName)… (click to cancel)" : "Authorize \(serverName)")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(Color.brandOrange)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color.brandOrange.opacity(0.12)))
                .overlay(Capsule().strokeBorder(Color.brandOrange.opacity(0.3), lineWidth: 0.5))
            }
            .buttonStyle(.plain)
            .disabled(connectors.loginInFlight != nil)
            .help("Runs the claude CLI's sign-in for this MCP server; the token is stored in your keychain and shared with every session.")
            if !isRunning, let msg = connectors.lastLoginMessage,
               connectors.lastLoginSucceeded != nil {
                Text(msg)
                    .font(.system(size: 10.5))
                    .foregroundStyle(connectors.lastLoginSucceeded == true ? Color.green : Color.secondary)
                    .lineLimit(3)
                    .textSelection(.enabled)
            }
        }
    }
}

/// Unmissable authorize banner shown above the composer while a tool
/// result reports an MCP server needing authorization. The inline
/// MCPAuthorizeButton under the tool result remains as the in-context
/// affordance; this is the one the user actually sees.
struct MCPAuthBanner: View {
    @ObservedObject var session: AgentSession
    let serverName: String
    @ObservedObject private var connectors = MCPConnectors.shared

    private var isRunning: Bool { connectors.loginInFlight == serverName }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "key.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.brandOrange)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(serverName) needs your authorization")
                    .font(.system(size: 12.5, weight: .semibold))
                Text(isRunning
                     ? (connectors.lastLoginMessage ?? "Finish the sign-in in your browser…")
                     : "The agent can't use this connector until you approve it in your browser.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 10)
            if isRunning {
                ProgressView().controlSize(.small)
                Button("Cancel") {
                    MCPConnectors.shared.cancelLogin()
                }
                .controlSize(.small)
            } else {
                Button("Authorize") {
                    MCPConnectors.shared.login(serverName)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.brandOrange)
                .controlSize(.small)
                .disabled(connectors.loginInFlight != nil)
            }
            Button {
                session.pendingMCPAuthServer = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Dismiss")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.brandOrange.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.brandOrange.opacity(0.35), lineWidth: 1)
        )
    }
}

/// One grey banner for any injected user-role message (compaction seed,
/// inter-tab orchestrator message) — never an amber "you typed this"
/// bubble. Content sits behind a Show toggle.
struct SyntheticUserRow: View {
    let label: String
    let content: String
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "brain.head.profile")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(label)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                if !content.isEmpty {
                    Button(expanded ? "Hide" : "Show") {
                        withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.brandOrange)
                }
            }
            if expanded && !content.isEmpty {
                Text(content)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
    }
}
