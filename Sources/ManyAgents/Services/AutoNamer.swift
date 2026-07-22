import Foundation
import Combine

/// Generates a 2-4 word tab title for each agent once they've had a real
/// exchange. Reuses the `claude` CLI for the actual call — whatever auth
/// the user has set up for Claude Code (subscription OAuth, API key, etc.)
/// "just works" without ManyAgents needing to manage its own credentials.
@MainActor
final class AutoNamer: ObservableObject {
    private weak var manager: AgentManager?
    private var observation: AnyCancellable?
    private var inflight: Set<UUID> = []

    private static let minimumUserPromptsBeforeNaming = 2

    func attach(manager: AgentManager) {
        self.manager = manager
        observation = manager.objectWillChange
            .debounce(for: .milliseconds(600), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.scan() }
    }

    private func scan() {
        guard let manager else { return }
        for session in manager.sessions {
            if !shouldName(session) { continue }
            if inflight.contains(session.id) { continue }
            guard let (userText, assistantText) = extractContext(session) else { continue }
            inflight.insert(session.id)
            session.isAutoNaming = true
            Task.detached { [sid = session.id] in
                let title = Self.requestTitle(userText: userText,
                                              assistantText: assistantText)
                await MainActor.run {
                    self.inflight.remove(sid)
                    let live = manager.sessions.first(where: { $0.id == sid })
                    live?.isAutoNaming = false
                    guard let title, !title.isEmpty, let live,
                          live.aiTitle == nil || live.aiTitle?.isEmpty == true
                    else { return }
                    live.aiTitle = title
                }
            }
        }
    }

    private func shouldName(_ session: AgentSession) -> Bool {
        if let t = session.aiTitle, !t.isEmpty { return false }
        let userPrompts = session.messages.filter { $0.role == .user && !$0.flatText.isEmpty }
        let assistantText = session.messages
            .filter { $0.role == .assistant }
            .reduce("") { $0 + $1.flatText }
        return userPrompts.count >= Self.minimumUserPromptsBeforeNaming
            && !assistantText.isEmpty
    }

    private func extractContext(_ session: AgentSession) -> (String, String)? {
        let lastUser = session.messages.last(where: { $0.role == .user })?.flatText
        let lastAssistant = session.messages.last(where: { $0.role == .assistant })?.flatText
        guard let u = lastUser, !u.isEmpty,
              let a = lastAssistant, !a.isEmpty else { return nil }
        return (String(u.prefix(800)), String(a.prefix(800)))
    }

    // MARK: - Title generation via the claude CLI

    /// Synchronous on a background task — spawn `claude -p` with the
    /// prompt, capture stdout, trim and return. No API key juggling: we
    /// inherit whatever auth Claude Code is using on this machine.
    nonisolated private static func requestTitle(userText: String,
                                                 assistantText: String) -> String? {
        guard let claudePath = ClaudeBridge.resolveClaudePath() else { return nil }
        let prompt = """
        Generate a 2-4 word Title-Case label for this conversation, suitable \
        as a tab name. Return ONLY the title — no quotes, no period, no \
        explanation. Examples: Refactor Auth Service, iBeacon Detection, \
        Memory Lookup Bug.

        ---
        User: \(userText)

        Assistant: \(assistantText)
        """
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: claudePath)
        process.arguments = [
            "-p", prompt,
            "--model", "claude-haiku-4-5-20251001",
            "--output-format", "text",
            // Use a project-less /tmp cwd so the call doesn't accidentally
            // pull in any local memory or project context. The title only
            // needs the prompt + response.
        ]
        process.currentDirectoryURL = URL(fileURLWithPath: NSTemporaryDirectory())
        process.standardOutput = stdout
        process.standardError = stderr
        process.environment = ProcessInfo.processInfo.environment

        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = stdout.fileHandleForReading.readDataToEndOfFile()
            guard let raw = String(data: data, encoding: .utf8) else { return nil }
            return cleanTitle(raw)
        } catch {
            return nil
        }
    }

    nonisolated private static func cleanTitle(_ raw: String) -> String {
        var t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Some `-p` runs prefix with a "Result:" or similar — keep only the
        // last non-empty line, which is almost always the bare title.
        if let lastLine = t.split(separator: "\n").last {
            t = String(lastLine).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if (t.hasPrefix("\"") && t.hasSuffix("\"")) || (t.hasPrefix("'") && t.hasSuffix("'")) {
            t = String(t.dropFirst().dropLast())
        }
        if t.count > 36 {
            t = String(t.prefix(36)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return t
    }
}
