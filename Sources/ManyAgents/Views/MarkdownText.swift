import SwiftUI
import AppKit

/// Block-level markdown renderer for assistant prose. SwiftUI's built-in
/// AttributedString markdown only handles inline syntax (bold, italic,
/// code spans, links) — it strips heading prefixes, fenced code blocks,
/// and lists entirely. We parse the block structure ourselves and let
/// AttributedString do the inline pass per paragraph.
struct MarkdownText: View {
    let raw: String
    /// Working directory of the session this text belongs to. Used to
    /// resolve relative file paths inside code spans (e.g.
    /// `notes/quiz_mockup.html`) so we can autolink them. nil → only
    /// absolute paths and http(s) URLs get autolinked.
    var sessionCwd: String? = nil
    /// Active ⌘F query. When non-empty, matching substrings get a highlight
    /// background across every inline run (and inside code blocks).
    var highlight: String = ""

    private var blocks: [MdBlock] { MdBlock.parse(raw) }

    var body: some View {
        // One flexible frame for the whole document, not one per block.
        // Pairing `.frame(maxWidth: .infinity)` with `.fixedSize` on every
        // paragraph made each block its own _FlexFrameLayout; a long
        // transcript then spent minutes in sizeThatFits recursion and the
        // window stopped responding. The VStack's own leading alignment
        // does the same job for free.
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // SwiftUI's default openURL on macOS doesn't reliably handle
        // file:// URLs (it's geared toward http schemes / Universal Links).
        // Route every link click through NSWorkspace so .html opens in
        // the browser, .swift in Xcode, a directory in Finder, etc.
        .environment(\.openURL, OpenURLAction { url in
            NSWorkspace.shared.open(url)
            return .handled
        })
    }

    @ViewBuilder
    private func view(for block: MdBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(inline(text, size: headingSize(level)))
                .font(.system(size: headingSize(level), weight: .semibold))
                .padding(.top, level <= 2 ? 4 : 2)
                // Same reason as the list rows below: without this a
                // scroll-proposed height wins over the text's own and the
                // line gets cut with an ellipsis instead of wrapping.
                .fixedSize(horizontal: false, vertical: true)
        case .paragraph(let text):
            Text(inline(text))
                .assistantTextStyle()
                .fixedSize(horizontal: false, vertical: true)
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
                            // Fill the row so long items wrap instead of
                            // truncating to one line with an ellipsis.
                            .fixedSize(horizontal: false, vertical: true)
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
                            // Fill the row so long items wrap instead of
                            // truncating to one line with an ellipsis.
                            .fixedSize(horizontal: false, vertical: true)
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
                    CodeCopyButton(code: code)
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
                    Text(SearchHighlight.attributed(code, query: highlight))
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
            // One continuous bar down the whole quote, with its paragraphs
            // (split on the blank lines the parser preserved as "\n\n")
            // spaced out. Soft line breaks inside a paragraph collapse to
            // spaces so wrapped email lines read as prose.
            HStack(alignment: .top, spacing: 0) {
                Rectangle()
                    .fill(Color.brandOrange.opacity(0.6))
                    .frame(width: 3)
                VStack(alignment: .leading, spacing: 8) {
                    let paras = text.components(separatedBy: "\n\n")
                        .map { $0.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                    ForEach(Array(paras.enumerated()), id: \.offset) { _, para in
                        Text(inline(para))
                            .assistantTextStyle()
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.leading, 10)
            }
        case .divider:
            Rectangle()
                .fill(Color.primary.opacity(0.10))
                .frame(height: 1)
                .padding(.vertical, 4)
        case .table(let header, let rows):
            tableView(header: header, rows: rows)
        }
    }

    @ViewBuilder
    private func tableView(header: [String], rows: [[String]]) -> some View {
        let columnCount = max(header.count, rows.map(\.count).max() ?? 0)
        VStack(alignment: .leading, spacing: 0) {
            // Header row.
            HStack(alignment: .top, spacing: 0) {
                ForEach(0..<columnCount, id: \.self) { i in
                    Text(inline(i < header.count ? header[i] : "", size: 12.5))
                        .font(.system(size: 12.5, weight: .semibold))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                }
            }
            .background(Color.primary.opacity(0.05))
            .overlay(
                Rectangle()
                    .fill(Color.primary.opacity(0.12))
                    .frame(height: 0.5)
                    .frame(maxHeight: .infinity, alignment: .bottom)
            )
            // Body rows.
            ForEach(Array(rows.enumerated()), id: \.offset) { ridx, row in
                HStack(alignment: .top, spacing: 0) {
                    ForEach(0..<columnCount, id: \.self) { i in
                        Text(inline(i < row.count ? row[i] : "", size: 12.5))
                            .font(.system(size: 12.5))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                    }
                }
                .background(ridx % 2 == 0 ? Color.clear : Color.primary.opacity(0.025))
                .overlay(
                    Rectangle()
                        .fill(Color.primary.opacity(0.08))
                        .frame(height: 0.5)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor).opacity(0.4))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: return 19
        case 2: return 17
        case 3: return 15.5
        default: return 14.5
        }
    }

    /// Detect URLs and file paths inside a code span. Returns a URL we
    /// should attach as `.link`, or nil if the span is just code text.
    /// Resolution order:
    ///   * http(s) URLs — always
    ///   * absolute file paths (/, ~) — if the file actually exists
    ///   * relative file paths — joined against sessionCwd, if that file
    ///     actually exists
    /// We intentionally check existence so we don't autolink things like
    /// `foo/bar` that are just code identifiers with a slash.
    private func autolinkURL(from raw: String) -> URL? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if s.hasPrefix("http://") || s.hasPrefix("https://") {
            return URL(string: s)
        }
        let fm = FileManager.default
        if s.hasPrefix("/") {
            return fm.fileExists(atPath: s) ? URL(fileURLWithPath: s) : nil
        }
        if s.hasPrefix("~/") {
            let expanded = NSString(string: s).expandingTildeInPath
            return fm.fileExists(atPath: expanded) ? URL(fileURLWithPath: expanded) : nil
        }
        // Relative path — needs the session cwd to resolve. Skip if we
        // weren't given one, and require the file to actually exist so
        // we don't false-positive on every code identifier with a slash.
        if let cwd = sessionCwd, s.contains("/") || s.contains(".") {
            let joined = (cwd as NSString).appendingPathComponent(s)
            if fm.fileExists(atPath: joined) {
                return URL(fileURLWithPath: joined)
            }
        }
        return nil
    }

    /// Inline pass — bold, italic, code spans, links — with code spans
    /// styled so they actually look like code (monospace + tinted bg).
    /// `size` must match the surrounding text's point size: SwiftUI draws a
    /// code span's background blob at that run's own font metrics, so a
    /// hardcoded size inside a larger line (body, headings) leaves the blob
    /// vertically misaligned. Matching the context size keeps the baseline
    /// and box height in step with the rest of the line.
    private func inline(_ text: String, size: CGFloat = 14.5) -> AttributedString {
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
        // monospace face (at the surrounding text's size, so the bg blob
        // lines up) with a faint background fill. Then autolink any span
        // that looks like a URL or a file path so Cmd-clicking it opens in
        // the default app — Finder for directories, the user's editor for
        // files, browser for http(s).
        for run in str.runs {
            if run.inlinePresentationIntent?.contains(.code) == true {
                str[run.range].font = .system(size: size, weight: .medium, design: .monospaced)
                str[run.range].foregroundColor = Color.brandOrange
                str[run.range].backgroundColor = Color.brandOrange.opacity(0.12)
                let spanText = String(str[run.range].characters)
                if let url = autolinkURL(from: spanText) {
                    str[run.range].link = url
                    str[run.range].underlineStyle = .single
                }
            } else if run.link != nil {
                // Markdown link from `[text](url)` — give it the brand
                // accent + underline so it actually reads as a link.
                str[run.range].foregroundColor = Color.activeHighlight
                str[run.range].underlineStyle = .single
            }
        }
        // Find highlight goes on last so it sits over code/link styling.
        SearchHighlight.apply(highlight, to: &str)
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
    case table(header: [String], rows: [[String]])

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

            // GFM pipe table — a header row followed by a separator row
            // (e.g. `|---|---|`), then contiguous data rows. The outer
            // pipes are optional, as they are on GitHub: a table written
            // `ID | Request` / `--- | ---` used to render as prose.
            if Self.startsTable(lines, at: i) {
                let header = parseTableRow(line)
                var rowData: [[String]] = []
                i += 2
                while i < lines.count, isTableCell(lines[i]) {
                    rowData.append(parseTableRow(lines[i]))
                    i += 1
                }
                blocks.append(.table(header: header, rows: rowData))
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

            // Blockquote. Group EVERY consecutive `>` line — including bare
            // `>` lines (blank lines inside the quote, common in quoted
            // emails) — into one continuous quote. Keep blank lines as
            // paragraph breaks ("\n") so the renderer can space paragraphs;
            // a bare `>` no longer leaks out as a literal ">" character, and
            // the quote no longer fragments into one bar per paragraph.
            if trimmed.hasPrefix(">") {
                var body: [String] = []
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    guard t.hasPrefix(">") else { break }
                    var stripped = String(t.dropFirst())          // drop ">"
                    if stripped.hasPrefix(" ") { stripped.removeFirst() }  // and one space
                    body.append(stripped)
                    i += 1
                }
                blocks.append(.quote(body.joined(separator: "\n")))
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

            // Paragraph — gather consecutive non-empty lines.
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
                if Self.isTableRow(lines[i]) { break }
                if Self.startsTable(lines, at: i) { break }
                paraLines.append(nextTrim)
                i += 1
            }
            // Every line keeps its own line, the way chat clients render
            // markdown rather than the way the spec does. An agent that
            // emits a list of rows one per line means them as rows: strict
            // soft-wrapping collapsed a 30-line triage table into a single
            // run-on paragraph nobody could read.
            blocks.append(.paragraph(paraLines.joined(separator: "\n")))
        }
        return blocks
    }

    private static func bulletItem(_ s: String) -> String? {
        for prefix in ["- ", "* ", "+ "] where s.hasPrefix(prefix) {
            return String(s.dropFirst(prefix.count))
        }
        return nil
    }

    private static func isTableRow(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        return t.hasPrefix("|") && t.contains("|") && t.count >= 3
    }

    /// A line that COULD be a table row without the outer pipes. Far too
    /// loose on its own — plenty of prose contains a pipe — so it only ever
    /// counts next to a separator row (see `startsTable`) or once a table is
    /// already underway.
    private static func isTableCell(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, t.contains("|") else { return false }
        return true
    }

    /// Is there a table starting at `idx`? A candidate header line with a
    /// separator directly under it. This is the ONLY thing that promotes a
    /// pipe-bearing line to a table row, which keeps prose safe.
    private static func startsTable(_ lines: [String], at idx: Int) -> Bool {
        guard idx + 1 < lines.count else { return false }
        return isTableCell(lines[idx]) && isTableSeparator(lines[idx + 1])
    }

    /// `|---|:---:|---:|` style separator — pipes, dashes, optional
    /// colons for alignment, possibly with whitespace.
    private static func isTableSeparator(_ line: String) -> Bool {
        var t = line.trimmingCharacters(in: .whitespaces)
        // A pipe is what separates this from a `---` divider or a run of
        // dashes under a heading, so require one either way.
        guard t.contains("|"), t.count >= 3 else { return false }
        if t.hasPrefix("|") { t.removeFirst() }
        if t.hasSuffix("|") { t.removeLast() }
        let cells = t.split(separator: "|", omittingEmptySubsequences: false)
        guard !cells.isEmpty else { return false }
        for cell in cells {
            let c = cell.trimmingCharacters(in: .whitespaces)
            guard !c.isEmpty else { return false }
            // Each cell must be only `-` and optional leading/trailing `:`.
            let body = c.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            guard !body.isEmpty,
                  body.allSatisfy({ $0 == "-" })
            else { return false }
        }
        return true
    }

    private static func parseTableRow(_ line: String) -> [String] {
        var t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("|") { t.removeFirst() }
        if t.hasSuffix("|") { t.removeLast() }
        return t.split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
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

/// Copy-to-clipboard button for a fenced code block's header.
private struct CodeCopyButton: View {
    let code: String
    @State private var copied = false

    var body: some View {
        Button {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(code, forType: .string)
            withAnimation(.easeOut(duration: 0.12)) { copied = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                withAnimation(.easeOut(duration: 0.12)) { copied = false }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 9, weight: .semibold))
                Text(copied ? "Copied" : "Copy")
                    .font(.system(size: 10, weight: .semibold))
            }
            .foregroundStyle(copied ? Color.green : Color.secondary)
        }
        .buttonStyle(.plain)
        .help("Copy code")
    }
}
