import SwiftUI

/// Claude-Code-style transcript layout. Everything flows left, each turn
/// led by a colored bullet (`●` for the assistant, semantically tinted;
/// `›` for the user). No chat bubbles. Tool calls render as inline
/// `ToolName(args)` lines with indented output beneath, matching the
/// `└` corner glyph the TUI uses.
struct MessageView: View {
    let message: Message

    var body: some View {
        // Skip the row entirely when every block is empty/skipped —
        // otherwise the marker renders as an orphan colored dot with
        // nothing beside it.
        if isRenderableEmpty {
            EmptyView()
        } else {
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
        }
    }

    private var isRenderableEmpty: Bool {
        message.blocks.allSatisfy { block in
            switch block {
            case .text(_, let t):     return t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case .thinking(_, let t): return t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case .toolUse:            return false
            case .toolResult(_, _, let c, _):
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
                MarkdownText(raw: text)
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
        case .toolUse(_, _, let name, let input):
            // AskUserQuestion is rendered as a native picker below the
            // conversation, so skip the raw tool-use card here to avoid
            // double-rendering the same prompt.
            if name == "AskUserQuestion" {
                EmptyView()
            } else {
                ToolUseCard(toolName: name, input: input)
            }
        case .toolResult(_, _, let content, let isError):
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

        private static let collapsedLineCount = 3
        private static let alwaysExpandThreshold = 5

        private var lines: [String] {
            content.components(separatedBy: "\n")
        }

        private var visibleText: String {
            if expanded || lines.count <= Self.alwaysExpandThreshold {
                return content
            }
            return lines.prefix(Self.collapsedLineCount).joined(separator: "\n")
        }

        private var hiddenLineCount: Int {
            max(0, lines.count - Self.collapsedLineCount)
        }

        private var shouldShowDisclosure: Bool {
            lines.count > Self.alwaysExpandThreshold && !expanded
        }

        var body: some View {
            HStack(alignment: .top, spacing: 6) {
                Text("└")
                    .font(AppFont.mono(13))
                    .foregroundStyle(isError ? .red.opacity(0.75) : .secondary.opacity(0.6))
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 4) {
                    Text(visibleText)
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
                                Text("\(hiddenLineCount) more line\(hiddenLineCount == 1 ? "" : "s")")
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
                    } else if expanded && lines.count > Self.alwaysExpandThreshold {
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
}
