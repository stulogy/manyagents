import Foundation

/// Recognizes a Bash call that is really a file edit.
///
/// Sessions are told to change files with Edit and Write, and mostly do.
/// But a bulk change across several files is genuinely more convenient as
/// one script, so it still happens — and then the transcript shows a wall
/// of `python3 - <<'PY'` where a file change belongs, which is the least
/// readable thing in the conversation and says nothing about which files
/// moved.
///
/// This doesn't stop that; it reads it. When a command is clearly writing
/// files, the card can name them and put the script away.
enum ShellEdit {

    struct Summary {
        /// Files the script appears to write, in the order they appear.
        let paths: [String]
        /// "python3", "sed", "cat" — what did the writing.
        let via: String
    }

    /// nil when the command isn't recognizably a file write. Deliberately
    /// conservative: labelling a `grep` as an edit is worse than leaving a
    /// real edit looking like a shell command.
    static func summarize(_ command: String) -> Summary? {
        guard let via = writer(in: command) else { return nil }
        let paths = filePaths(in: command)
        guard !paths.isEmpty else { return nil }
        return Summary(paths: paths, via: via)
    }

    /// What kind of write this is, if any.
    private static func writer(in command: String) -> String? {
        // In-place stream editors: the -i flag is the whole tell.
        if command.range(of: #"\bsed\s+(-[a-zA-Z]*\s+)*-i\b"#, options: .regularExpression) != nil
            || command.range(of: #"\bsed\s+-i\b"#, options: .regularExpression) != nil {
            return "sed"
        }
        if command.range(of: #"\bperl\s+-[a-zA-Z]*i"#, options: .regularExpression) != nil {
            return "perl"
        }
        // Redirection into a file, and tee. `>` alone is too broad — it's
        // how output gets saved for reading too — so require cat/printf/echo
        // on the left, which is how a file actually gets authored.
        if command.range(of: #"\b(cat|printf|echo)\b[^|\n]*>>?\s*\S"#, options: .regularExpression) != nil {
            return "cat"
        }
        if command.range(of: #"\btee\s+(-a\s+)?\S"#, options: .regularExpression) != nil {
            return "tee"
        }
        // A script interpreter only counts when the script writes something.
        // `python3 - <<PY` that reads and prints is not an edit.
        let interpreters = ["python3", "python", "node", "ruby", "perl"]
        guard let interpreter = interpreters.first(where: {
            command.range(of: "\\b\($0)\\b", options: .regularExpression) != nil
        }) else { return nil }
        let writes = [
            #"open\([^)]*['"][rwa]?\+?w"#,   // open(p, 'w') / 'a' / 'r+'
            #"\.write\("#,
            #"write_text\("#,
            #"writeFileSync"#,
            #"\bFile\.write\b"#,
        ]
        let writesSomething = writes.contains {
            command.range(of: $0, options: .regularExpression) != nil
        }
        return writesSomething ? interpreter : nil
    }

    /// Path-shaped tokens in the command. A path here is a bare or quoted
    /// run of path characters with a file extension — enough to pick
    /// 'app/approvals/DecisionDrawer.tsx' out of a script without dragging
    /// in the CSS values sitting beside it.
    static func filePaths(in command: String) -> [String] {
        let pattern = #"[~./A-Za-z0-9_$@+-]*[/A-Za-z0-9_-]+\.[A-Za-z0-9]{1,8}"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = command as NSString
        var seen = Set<String>()
        var out: [String] = []
        for m in re.matches(in: command, range: NSRange(location: 0, length: ns.length)) {
            let raw = ns.substring(with: m.range)
            guard isPlausiblePath(raw), !seen.contains(raw) else { continue }
            seen.insert(raw)
            out.append(raw)
            if out.count == 8 { break }
        }
        return out
    }

    /// Filters the near-misses: the interpreter's own name, version-shaped
    /// numbers, and domains.
    private static func isPlausiblePath(_ s: String) -> Bool {
        guard let dot = s.lastIndex(of: ".") else { return false }
        let ext = String(s[s.index(after: dot)...])
        // "0.13.7" and "1.5" are versions, not files.
        guard !ext.allSatisfy(\.isNumber) else { return false }
        let stem = String(s[s.startIndex..<dot])
        guard !stem.isEmpty else { return false }
        // A bare name with no directory has to look like a real file
        // extension; otherwise "self.write" and "os.path" qualify.
        if !s.contains("/") {
            return knownExtensions.contains(ext.lowercased())
        }
        // Web addresses aren't files being edited.
        if s.contains("://") || stem.hasPrefix("www") { return false }
        return true
    }

    private static let knownExtensions: Set<String> = [
        "swift", "ts", "tsx", "js", "jsx", "mjs", "cjs", "py", "rb", "go", "rs",
        "java", "kt", "c", "h", "cpp", "hpp", "m", "mm", "cs", "php", "sh", "zsh",
        "bash", "json", "yml", "yaml", "toml", "xml", "plist", "html", "css",
        "scss", "sass", "md", "mdx", "txt", "sql", "env", "lock", "gradle",
        "xcconfig", "entitlements", "storyboard", "xib", "podspec", "cfg", "ini",
    ]
}
