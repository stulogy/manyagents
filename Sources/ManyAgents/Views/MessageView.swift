import SwiftUI

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
    /// cwd of the owning session — passed through to MarkdownText so
    /// relative file paths in code spans (`notes/foo.html`) can be
    /// resolved against the project root and autolinked.
    var sessionCwd: String? = nil
    /// Source-session id used by the "Send to →" hand-off button.
    /// nil disables the action (e.g. transcript-only message views
    /// where there's no owning session to hand off from).
    var sessionId: UUID? = nil
    @State private var hover = false
    @State private var copyConfirmed = false
    @State private var showingHandOff = false

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
                }
                // Always in the tree, just invisible when not hovering —
                // so it can't disappear out from under the cursor mid-
                // click. opacity + allowsHitTesting toggle together.
                HStack(spacing: 6) {
                    if canHandOff {
                        handOffButton
                    }
                    copyButton
                }
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
        }
    }

    /// Only show the hand-off action on assistant prose — handing off
    /// user messages or pure-tool-output rows isn't a useful gesture
    /// (the user can already retype, the tool output isn't reply-shaped).
    private var canHandOff: Bool {
        guard sessionId != nil, message.role == .assistant else { return false }
        return !flatAssistantText.isEmpty
    }

    /// Plain text payload that the hand-off picker pre-fills with —
    /// concatenated visible text from this assistant message, stripped
    /// of thinking blocks and tool noise.
    private var flatAssistantText: String {
        var pieces: [String] = []
        for block in message.blocks {
            if case .text(_, let t) = block {
                let trimmed = t.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { pieces.append(trimmed) }
            }
        }
        return pieces.joined(separator: "\n\n")
    }

    @ViewBuilder
    private var handOffButton: some View {
        Button {
            showingHandOff = true
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "arrow.turn.up.right")
                    .font(.system(size: 10, weight: .semibold))
                Text("Send to")
                    .font(.system(size: 10.5, weight: .semibold))
            }
            .foregroundStyle(Color.brandOrange)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(0.85))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .stroke(Color.brandOrange.opacity(0.35), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .help("Hand off this reply as a prompt to another open agent")
        .popover(isPresented: $showingHandOff, arrowEdge: .top) {
            if let sid = sessionId {
                HandOffSheet(
                    sourceSessionId: sid,
                    initialPayload: flatAssistantText,
                    onClose: { showingHandOff = false }
                )
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
            HStack(spacing: 4) {
                Image(systemName: copyConfirmed ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 10, weight: .semibold))
                Text(copyConfirmed ? "Copied" : "Copy")
                    .font(.system(size: 10.5, weight: .semibold))
            }
            .foregroundStyle(copyConfirmed ? .green : .secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(0.85))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .stroke(Color.primary.opacity(0.12), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .help("Copy this message")
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
        message.blocks.allSatisfy { block in
            switch block {
            case .text(_, let t):     return t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case .thinking(_, let t): return t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case .toolUse:            return false
            case .toolResult(_, _, let c, _, _):
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

    // MARK: - Block rendering

    @ViewBuilder
    private func blockView(_ block: ContentBlock) -> some View {
        switch block {
        case .text(_, let text):
            switch message.role {
            case .user:
                Text(text)
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
            case .assistant:
                // Block-level markdown — headings, code blocks, lists,
                // blockquotes, inline code, links. Inline `code` spans
                // get a tinted monospace treatment so they actually
                // look like code in flowing text.
                MarkdownText(raw: text, sessionCwd: sessionCwd)
                    .frame(maxWidth: .infinity, alignment: .leading)
            case .system:
                Text(text)
                    .font(AppFont.mono(11.5))
                    .foregroundStyle(.secondary)
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
            // AskUserQuestion is rendered as a native picker below the
            // conversation, so skip the raw tool-use card here to avoid
            // double-rendering the same prompt.
            if name == "AskUserQuestion" {
                EmptyView()
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
                ToolUseCard(toolName: name, input: input)
            }
        case .toolResult(_, _, let content, let isError, _):
            ToolResultRow(content: content, isError: isError)
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
        @State private var expanded = false

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

        var body: some View {
            HStack(alignment: .top, spacing: 6) {
                Text("└")
                    .font(AppFont.mono(13))
                    .foregroundStyle(isError ? .red.opacity(0.75) : .secondary.opacity(0.6))
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 4) {
                    Text(displayText)
                        .font(AppFont.mono(12))
                        .foregroundStyle(isError ? .red : .secondary)
                        .lineSpacing(2)
                        .multilineTextAlignment(.leading)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if shouldShowDisclosure {
                        Button {
                            withAnimation(.easeOut(duration: 0.15)) { expanded = true }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 9, weight: .semibold))
                                Text(hiddenSummary)
                                    .font(.system(size: 10.5, weight: .medium))
                            }
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(
                                Capsule().fill(Color.primary.opacity(0.05))
                            )
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
                            .background(
                                Capsule().fill(Color.primary.opacity(0.05))
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
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
            if let u = userExpansion { return u }
            return sessionRunning
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
