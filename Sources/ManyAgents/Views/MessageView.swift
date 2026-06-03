import SwiftUI

/// Claude-Code-style transcript layout. Everything flows left, each turn
/// led by a colored bullet (`●` for the assistant, semantically tinted;
/// `›` for the user). No chat bubbles. Tool calls render as inline
/// `ToolName(args)` lines with indented output beneath, matching the
/// `└` corner glyph the TUI uses.
struct MessageView: View {
    let message: Message

    var body: some View {
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
            case .toolUse:  hasTool = true
            case .thinking: hasThinking = true
            case .text:     hasText = true
            default:        break
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
                Text(asAttributed(text))
                    .assistantTextStyle()
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
            ToolUseCard(toolName: name, input: input)
        case .toolResult(_, _, let content, let isError):
            // Indented under the tool call with the └ corner — same shape
            // as the TUI's tool-output collapse hint.
            HStack(alignment: .top, spacing: 6) {
                Text("└")
                    .font(AppFont.mono(13))
                    .foregroundStyle(isError ? .red.opacity(0.75) : .secondary.opacity(0.6))
                    .padding(.top, 1)
                Text(content)
                    .font(AppFont.mono(12))
                    .foregroundStyle(isError ? .red : .secondary)
                    .lineSpacing(2)
                    .multilineTextAlignment(.leading)
                    .lineLimit(10)
                    .textSelection(.enabled)
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
