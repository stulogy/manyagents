import SwiftUI

/// Shared helpers for the in-conversation find (⌘F): paint a background behind
/// every case-insensitive occurrence of the active query inside an
/// `AttributedString`. Used by both `MarkdownText` (assistant prose) and
/// `MessageView` (plain user / system text).
enum SearchHighlight {
    /// Background for a matched run. Black foreground keeps it readable on the
    /// yellow regardless of light/dark mode.
    static let background = Color.yellow.opacity(0.55)

    /// Paint every occurrence of `query` in `str`. No-op for an empty query.
    static func apply(_ query: String, to str: inout AttributedString) {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        let full = String(str.characters)
        var cursor = full.startIndex
        while let r = full.range(of: q, options: .caseInsensitive,
                                 range: cursor..<full.endIndex) {
            let loOffset = full.distance(from: full.startIndex, to: r.lowerBound)
            let hiOffset = full.distance(from: full.startIndex, to: r.upperBound)
            let lo = str.index(str.startIndex, offsetByCharacters: loOffset)
            let hi = str.index(str.startIndex, offsetByCharacters: hiOffset)
            str[lo..<hi].backgroundColor = background
            str[lo..<hi].foregroundColor = .black
            if r.upperBound == r.lowerBound { break }   // guard zero-width
            cursor = r.upperBound
        }
    }

    /// Build a highlighted `AttributedString` from plain text.
    static func attributed(_ text: String, query: String) -> AttributedString {
        var s = AttributedString(text)
        apply(query, to: &s)
        return s
    }
}
