import Foundation

/// Turns the tail of an agent's message into a line that says what is
/// actually being asked.
///
/// The raw text is whatever the agent happened to end on, which is often
/// the last third of a paragraph — accurate, and useless in a 300pt column
/// where you're trying to work out whether this one needs you now. So a
/// cheap model reads it and writes the ask.
///
/// Through the `claude` CLI rather than the API: the app already resolves
/// and runs that binary, it carries the user's own auth, and Haiku on a
/// two-line prompt is about as small as a model call gets. No API key to
/// store, nothing new to configure.
enum AttentionSummarizer {

    /// Below this the text is already a readable question and a model call
    /// would cost more than it adds.
    static let minimumLengthToSummarize = 180

    private static let model = "claude-haiku-4-5"

    /// One at a time. These arrive in bursts — a board of tabs all
    /// finishing together — and a dozen concurrent CLI launches would cost
    /// more in process spawns than the summaries are worth.
    private static let queue = DispatchQueue(label: "manyagents.attention.summarize")

    /// The ask, and the agent's own suggested default if it stated one —
    /// which it usually does, buried in the paragraph the row truncates.
    /// That line is what turns a row into a yes/no rather than a trip to
    /// the transcript to work out what was being proposed.
    struct Result {
        let ask: String
        let recommendation: String?
    }

    static func summarize(_ text: String, completion: @escaping (Result?) -> Void) {
        guard text.count >= minimumLengthToSummarize,
              let claude = ClaudeBridge.resolveClaudePath()
        else { completion(nil); return }

        queue.async {
            let prompt = """
            Below is the end of a message an AI coding agent sent its user. \
            The user is looking at a list of things waiting on them and needs \
            to know at a glance what this one wants.

            Reply in exactly this shape and nothing else:

            ASK: one sentence, at most 18 words, saying what the agent needs \
            from the user. Start with the subject or a verb — never "The agent" \
            or "This message". No quotes.
            DEFAULT: what the agent said it would do or recommends, at most 14 \
            words. Write NONE if it did not suggest one.

            If nothing is actually being asked of the user, reply with exactly: \
            NONE

            ---
            \(text.prefix(2000))
            """

            let p = Process()
            p.executableURL = URL(fileURLWithPath: claude)
            p.arguments = ["-p", prompt,
                           "--model", model,
                           "--output-format", "text",
                           // No tools, no MCP, no project context: this is a
                           // text transform and anything else is latency and
                           // a chance for it to wander off.
                           // Must be a well-formed config, not "{}" — the
                           // CLI rejects that with "mcpServers: Invalid
                           // input" and the summary silently never arrives.
                           "--strict-mcp-config", "--mcp-config", #"{"mcpServers":{}}"#]
            let out = Pipe()
            p.standardOutput = out
            p.standardError = Pipe()
            // Inherit the login PATH the same way sessions do — a GUI app
            // launched from Finder has almost none.
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = ClaudeBridge.userPath
            p.environment = env

            guard (try? p.run()) != nil else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            // Bounded: a summary that hasn't arrived in 25 seconds is worth
            // less than the raw text already on screen.
            let deadline = DispatchWorkItem { if p.isRunning { p.terminate() } }
            queue.asyncAfter(deadline: .now() + 25, execute: deadline)
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            deadline.cancel()

            let raw = (String(data: data, encoding: .utf8) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard p.terminationStatus == 0, !raw.isEmpty, raw != "NONE" else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            func field(_ key: String) -> String? {
                guard let line = raw.split(separator: "\n")
                    .first(where: { $0.uppercased().hasPrefix(key) })
                else { return nil }
                let value = line.drop(while: { $0 != ":" }).dropFirst()
                    .trimmingCharacters(in: .whitespaces)
                return (value.isEmpty || value.uppercased() == "NONE") ? nil : value
            }
            // Guard against the model ignoring the brief — a "summary"
            // longer than what it summarised is worse than nothing.
            guard let ask = field("ASK"), ask.count < min(text.count, 200) else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            let rec = field("DEFAULT").map { $0.count < 200 ? $0 : String($0.prefix(200)) }
            DispatchQueue.main.async { completion(Result(ask: ask, recommendation: rec)) }
        }
    }
}
