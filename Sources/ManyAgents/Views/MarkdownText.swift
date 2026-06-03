import SwiftUI

/// Block-level markdown renderer for assistant prose. SwiftUI's built-in
/// AttributedString markdown only handles inline syntax (bold, italic,
/// code spans, links) — it strips heading prefixes, fenced code blocks,
/// and lists entirely. We parse the block structure ourselves and let
/// AttributedString do the inline pass per paragraph.
struct MarkdownText: View {
    let raw: String

    private var blocks: [MdBlock] { MdBlock.parse(raw) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
    }

    @ViewBuilder
    private func view(for block: MdBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(inline(text))
                .font(.system(size: headingSize(level), weight: .semibold))
                .padding(.top, level <= 2 ? 4 : 2)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .paragraph(let text):
            Text(inline(text))
                .assistantTextStyle()
                .frame(maxWidth: .infinity, alignment: .leading)
        case .bulletList(let items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .top, spacing: 8) {
                        Text("•")
                            .font(AppFont.assistantProse())
                            .foregroundStyle(.secondary)
                            .frame(width: 10, alignment: .leading)
                        Text(inline(item))
                            .assistantTextStyle()
                    }
                }
            }
            .padding(.leading, 4)
        case .orderedList(let items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { idx, item in
                    HStack(alignment: .top, spacing: 8) {
                        Text("\(idx + 1).")
                            .font(AppFont.assistantProse())
                            .foregroundStyle(.secondary)
                            .frame(width: 20, alignment: .leading)
                        Text(inline(item))
                            .assistantTextStyle()
                    }
                }
            }
            .padding(.leading, 4)
        case .codeBlock(let lang, let code):
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left.forwardslash.chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                    Text(lang?.isEmpty == false ? lang! : "code")
                        .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.tertiary)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Color.primary.opacity(0.04))
                .overlay(
                    Rectangle()
                        .fill(Color.primary.opacity(0.10))
                        .frame(height: 0.5)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                )
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(code)
                        .font(.system(size: 12.5, design: .monospaced))
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 12)
                        .frame(minWidth: 0, alignment: .topLeading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor).opacity(0.5))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.primary.opacity(0.15), lineWidth: 1)
            )
        case .quote(let text):
            HStack(spacing: 0) {
                Rectangle()
                    .fill(Color.brandOrange.opacity(0.6))
                    .frame(width: 3)
                Text(inline(text))
                    .assistantTextStyle()
                    .foregroundStyle(.secondary)
                    .padding(.leading, 10)
            }
        case .divider:
            Rectangle()
                .fill(Color.primary.opacity(0.10))
                .frame(height: 1)
                .padding(.vertical, 4)
        }
    }

    private func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: return 19
        case 2: return 17
        case 3: return 15.5
        default: return 14.5
        }
    }

    /// Inline pass — bold, italic, code spans, links — with code spans
    /// styled so they actually look like code (monospace + tinted bg).
    private func inline(_ text: String) -> AttributedString {
        var str: AttributedString
        if let parsed = try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace,
                           failurePolicy: .returnPartiallyParsedIfPossible)
        ) {
            str = parsed
        } else {
            str = AttributedString(text)
        }
        // Inline code spans live on `inlinePresentationIntent` (not the
        // block-level `presentationIntent`). Tint them orange in a
        // monospace face with a faint background fill.
        for run in str.runs {
            if run.inlinePresentationIntent?.contains(.code) == true {
                str[run.range].font = .system(size: 12.5, weight: .medium, design: .monospaced)
                str[run.range].foregroundColor = Color.brandOrange
                str[run.range].backgroundColor = Color.brandOrange.opacity(0.12)
            }
        }
        return str
    }
}

/// Minimal block-level markdown parser. Recognizes: ATX headings (`# … ######`),
/// fenced code blocks (``` and ~~~), bullet lists (`- ` / `* ` / `+ `),
/// ordered lists (`1. `), blockquotes (`> `), horizontal rules (`---`),
/// and paragraphs. Anything else falls through as paragraph text.
enum MdBlock {
    case heading(level: Int, text: String)
    case paragraph(String)
    case bulletList([String])
    case orderedList([String])
    case codeBlock(language: String?, code: String)
    case quote(String)
    case divider

    static func parse(_ raw: String) -> [MdBlock] {
        var blocks: [MdBlock] = []
        var lines = raw.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var i = 0

        func isFence(_ s: String) -> (Bool, String?) {
            let t = s.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("```") {
                let lang = String(t.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                return (true, lang.isEmpty ? nil : lang)
            }
            if t.hasPrefix("~~~") {
                let lang = String(t.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                return (true, lang.isEmpty ? nil : lang)
            }
            return (false, nil)
        }

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Fenced code block.
            let (fence, lang) = isFence(line)
            if fence {
                var body: [String] = []
                i += 1
                while i < lines.count {
                    let (closing, _) = isFence(lines[i])
                    if closing { i += 1; break }
                    body.append(lines[i])
                    i += 1
                }
                blocks.append(.codeBlock(language: lang, code: body.joined(separator: "\n")))
                continue
            }

            // Horizontal rule.
            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                blocks.append(.divider)
                i += 1
                continue
            }

            // ATX heading.
            if trimmed.hasPrefix("#") {
                var level = 0
                for c in trimmed { if c == "#" { level += 1 } else { break } }
                if level >= 1 && level <= 6,
                   trimmed.count > level,
                   trimmed[trimmed.index(trimmed.startIndex, offsetBy: level)] == " " {
                    let text = String(trimmed.dropFirst(level + 1))
                    blocks.append(.heading(level: min(level, 4),
                                           text: text.trimmingCharacters(in: .whitespaces)))
                    i += 1
                    continue
                }
            }

            // Blockquote.
            if trimmed.hasPrefix("> ") {
                var body: [String] = [String(trimmed.dropFirst(2))]
                i += 1
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("> ") {
                    body.append(String(lines[i].trimmingCharacters(in: .whitespaces).dropFirst(2)))
                    i += 1
                }
                blocks.append(.quote(body.joined(separator: " ")))
                continue
            }

            // Bullet list.
            if let item = bulletItem(trimmed) {
                var items: [String] = [item]
                i += 1
                while i < lines.count,
                      let nxt = bulletItem(lines[i].trimmingCharacters(in: .whitespaces)) {
                    items.append(nxt)
                    i += 1
                }
                blocks.append(.bulletList(items))
                continue
            }

            // Ordered list.
            if let item = orderedItem(trimmed) {
                var items: [String] = [item]
                i += 1
                while i < lines.count,
                      let nxt = orderedItem(lines[i].trimmingCharacters(in: .whitespaces)) {
                    items.append(nxt)
                    i += 1
                }
                blocks.append(.orderedList(items))
                continue
            }

            // Paragraph — join consecutive non-empty lines.
            if trimmed.isEmpty { i += 1; continue }
            var paraLines: [String] = [trimmed]
            i += 1
            while i < lines.count {
                let nextTrim = lines[i].trimmingCharacters(in: .whitespaces)
                if nextTrim.isEmpty { break }
                // Stop if the next line starts a different block type.
                if nextTrim.hasPrefix("#") { break }
                if nextTrim.hasPrefix("> ") { break }
                if isFence(lines[i]).0 { break }
                if bulletItem(nextTrim) != nil { break }
                if orderedItem(nextTrim) != nil { break }
                paraLines.append(nextTrim)
                i += 1
            }
            blocks.append(.paragraph(paraLines.joined(separator: " ")))
        }
        return blocks
    }

    private static func bulletItem(_ s: String) -> String? {
        for prefix in ["- ", "* ", "+ "] where s.hasPrefix(prefix) {
            return String(s.dropFirst(prefix.count))
        }
        return nil
    }

    private static func orderedItem(_ s: String) -> String? {
        // "1. " / "2. " / "10. " — at most 3 digits to avoid false positives.
        var digits = 0
        for c in s {
            if c.isNumber { digits += 1; if digits > 3 { return nil } }
            else { break }
        }
        guard digits > 0 else { return nil }
        let after = s.index(s.startIndex, offsetBy: digits)
        guard after < s.endIndex, s[after] == ".",
              s.index(after: after) < s.endIndex,
              s[s.index(after: after)] == " "
        else { return nil }
        return String(s[s.index(after, offsetBy: 2)...])
    }
}
