import Foundation

/// Claude Code injects `<task-notification>` blocks into the conversation
/// when a background agent finishes. They are addressed to the model, not
/// to the user: the `<result>` inside is the subagent's full raw report,
/// file paths and all. It must never reach the transcript as body text.
///
/// One implementation, used by both the live bridge and the transcript
/// loader, so live and restored history agree — and so there's a single
/// place to fix when the harness changes shape.
enum HarnessNotice {

    private static let open  = "<task-notification>"
    private static let close = "</task-notification>"

    /// Strip every notification block out of `raw`, returning whatever
    /// real text is left plus a one-line summary per block removed.
    ///
    /// Matching is by CONTAINMENT, not prefix: when one of these is
    /// queued while a turn is in flight it can arrive concatenated with
    /// the user's own typed prompt, and a prefix test misses that case —
    /// which is how a 5,000-character subagent report ends up rendered
    /// as if the user had pasted it.
    static func rewrite(_ raw: String) -> (text: String, notices: [String]) {
        var remaining = raw
        var notices: [String] = []
        while let start = remaining.range(of: open) {
            guard let end = remaining.range(of: close,
                                            range: start.upperBound..<remaining.endIndex)
            else {
                // Unterminated — a truncated or still-streaming block.
                // Everything from the open tag on is harness plumbing.
                notices.append(summary(of: String(remaining[start.lowerBound...])))
                remaining = String(remaining[..<start.lowerBound])
                break
            }
            notices.append(summary(of: String(remaining[start.lowerBound..<end.upperBound])))
            remaining.replaceSubrange(start.lowerBound..<end.upperBound, with: "")
        }
        return (remaining.trimmingCharacters(in: .whitespacesAndNewlines), notices)
    }

    /// True when `raw` carries a notification anywhere in it.
    static func contains(_ raw: String) -> Bool {
        raw.contains(open)
    }

    /// The muted one-liner we show in place of a block. Keeps the status
    /// when it isn't a plain success, so a failed background agent still
    /// reads as a failure without spilling its report.
    static func summary(of block: String) -> String {
        let summary = tag("summary", in: block) ?? "update"
        let status = tag("status", in: block)
        if let status, status != "completed" {
            return "Background task (\(status)): \(summary)"
        }
        return "Background task: \(summary)"
    }

    private static func tag(_ name: String, in block: String) -> String? {
        guard let start = block.range(of: "<\(name)>"),
              let end = block.range(of: "</\(name)>",
                                    range: start.upperBound..<block.endIndex)
        else { return nil }
        let value = block[start.upperBound..<end.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
