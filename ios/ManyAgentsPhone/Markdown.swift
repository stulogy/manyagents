import SwiftUI

/// Just enough markdown for a transcript, and no more.
///
/// Agents write headings, bullets, fenced code and inline `code`, and on a
/// phone the fenced code is the part that matters — it has to be
/// monospaced and horizontally scrollable rather than wrapped into soup.
/// Everything else falls back to AttributedString's own markdown parsing,
/// which handles bold, italic, links and inline code for free.
struct Markdown: View {
    let raw: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(Self.parse(raw).enumerated()), id: \.offset) { _, block in
                switch block {
                case .code(let lang, let code):
                    CodeBlock(language: lang, code: code)
                case .heading(let level, let text):
                    Text(inline(text))
                        .font(.system(size: level <= 1 ? 19 : (level == 2 ? 17 : 15),
                                      weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                case .ordered(let items):
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(items.enumerated()), id: \.offset) { idx, item in
                            HStack(alignment: .top, spacing: 7) {
                                Text("\(idx + 1).")
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                                Text(inline(item)).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                case .bullet(let items):
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                            HStack(alignment: .top, spacing: 7) {
                                Text("•").foregroundStyle(.secondary)
                                Text(inline(item)).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                case .paragraph(let text):
                    Text(inline(text))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func inline(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s,
                               options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(s)
    }

    // MARK: - Parsing

    enum Block {
        case paragraph(String)
        case heading(Int, String)
        case bullet([String])
        /// Rendered with a running count, not the digits in the source —
        /// agents write "1." for every item as often as they number them.
        case ordered([String])
        case code(String?, String)
    }

    /// "1. " / "12. " → the text after it.
    static func orderedItem(_ s: String) -> String? {
        var digits = 0
        for c in s { if c.isNumber { digits += 1; if digits > 3 { return nil } } else { break } }
        guard digits > 0 else { return nil }
        let after = s.index(s.startIndex, offsetBy: digits)
        guard after < s.endIndex, s[after] == ".",
              s.index(after: after) < s.endIndex,
              s[s.index(after: after)] == " " else { return nil }
        return String(s[s.index(after, offsetBy: 2)...])
    }

    static func parse(_ raw: String) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []
        var bullets: [String] = []
        var ordered: [String] = []
        var codeLines: [String] = []
        var codeLang: String?
        var inCode = false

        func flushParagraph() {
            let text = paragraph.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            if !text.isEmpty { blocks.append(.paragraph(text)) }
            paragraph = []
        }
        func flushBullets() {
            if !bullets.isEmpty { blocks.append(.bullet(bullets)); bullets = [] }
        }
        func flushOrdered() {
            if !ordered.isEmpty { blocks.append(.ordered(ordered)); ordered = [] }
        }

        for line in raw.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                if inCode {
                    blocks.append(.code(codeLang, codeLines.joined(separator: "\n")))
                    codeLines = []; codeLang = nil; inCode = false
                } else {
                    flushParagraph(); flushBullets(); flushOrdered()
                    let lang = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                    codeLang = lang.isEmpty ? nil : lang
                    inCode = true
                }
                continue
            }
            if inCode { codeLines.append(line); continue }

            if trimmed.isEmpty {
                // A blank line inside a list is spacing, not a terminator:
                // ending the list here restarted the numbering at 1 on
                // every item.
                flushParagraph()
                continue
            }

            if trimmed.hasPrefix("#") {
                flushParagraph(); flushBullets(); flushOrdered()
                let hashes = trimmed.prefix { $0 == "#" }.count
                blocks.append(.heading(hashes,
                    String(trimmed.dropFirst(hashes)).trimmingCharacters(in: .whitespaces)))
                continue
            }
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                flushParagraph(); flushOrdered()
                bullets.append(String(trimmed.dropFirst(2)))
                continue
            }
            if let item = orderedItem(trimmed) {
                flushParagraph(); flushBullets()
                ordered.append(item)
                continue
            }
            flushBullets(); flushOrdered()
            paragraph.append(trimmed)
        }
        if inCode, !codeLines.isEmpty { blocks.append(.code(codeLang, codeLines.joined(separator: "\n"))) }
        flushParagraph(); flushBullets(); flushOrdered()
        return blocks
    }
}

/// Monospaced, scrolls sideways rather than wrapping, and can be copied —
/// the three things that make code on a phone usable at all.
struct CodeBlock: View {
    let language: String?
    let code: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let language {
                Text(language)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.top, 6)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(size: 12.5, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.07)))
    }
}
