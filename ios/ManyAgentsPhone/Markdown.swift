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
        case code(String?, String)
    }

    static func parse(_ raw: String) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []
        var bullets: [String] = []
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

        for line in raw.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                if inCode {
                    blocks.append(.code(codeLang, codeLines.joined(separator: "\n")))
                    codeLines = []; codeLang = nil; inCode = false
                } else {
                    flushParagraph(); flushBullets()
                    let lang = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                    codeLang = lang.isEmpty ? nil : lang
                    inCode = true
                }
                continue
            }
            if inCode { codeLines.append(line); continue }

            if trimmed.isEmpty { flushParagraph(); flushBullets(); continue }

            if trimmed.hasPrefix("#") {
                flushParagraph(); flushBullets()
                let hashes = trimmed.prefix { $0 == "#" }.count
                blocks.append(.heading(hashes,
                    String(trimmed.dropFirst(hashes)).trimmingCharacters(in: .whitespaces)))
                continue
            }
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                flushParagraph()
                bullets.append(String(trimmed.dropFirst(2)))
                continue
            }
            flushBullets()
            paragraph.append(trimmed)
        }
        if inCode, !codeLines.isEmpty { blocks.append(.code(codeLang, codeLines.joined(separator: "\n"))) }
        flushParagraph(); flushBullets()
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
