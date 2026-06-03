import Foundation
import Combine

/// Detects whether the local `claude` CLI is installed and authenticated.
/// ManyAgents leans on Claude Code's auth (subscription OAuth or API key)
/// instead of managing its own — so if the user hasn't run `claude login`
/// yet, every spawn would fail silently. We surface the state up front via
/// an onboarding gate.
@MainActor
final class ClaudeReadiness: ObservableObject {
    enum State: Equatable {
        case checking
        case ready
        case missingBinary
        case notAuthenticated
    }

    @Published private(set) var state: State = .checking
    @Published private(set) var claudePath: String?

    func refresh() {
        state = .checking
        Task.detached { [weak self] in
            let result = Self.probe()
            await MainActor.run {
                self?.claudePath = result.path
                self?.state = result.state
            }
        }
    }

    // MARK: - Probe

    nonisolated private static func probe() -> (state: State, path: String?) {
        guard let path = ClaudeBridge.resolveClaudePath() else {
            return (.missingBinary, nil)
        }
        // Heuristic auth checks — cheap, no API calls.
        // 1. `~/.claude/.credentials.json` for OAuth tokens
        // 2. macOS keychain item Claude Code uses for Max subscriptions
        // 3. ANTHROPIC_API_KEY env var
        // If any of those is present, we treat the install as logged in.
        let home = NSHomeDirectory()
        let credPaths = [
            "\(home)/.claude/.credentials.json",
            "\(home)/.claude/credentials.json"
        ]
        for credPath in credPaths {
            if FileManager.default.fileExists(atPath: credPath) {
                return (.ready, path)
            }
        }
        if ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"]?.isEmpty == false {
            return (.ready, path)
        }
        // Keychain probe — `security find-generic-password` returns 0 if the
        // item exists. Anthropic stores Max creds as a generic password under
        // the service name "Claude Code-credentials".
        if keychainHasItem(service: "Claude Code-credentials") {
            return (.ready, path)
        }
        return (.notAuthenticated, path)
    }

    nonisolated private static func keychainHasItem(service: String) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-s", service]
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        do {
            try p.run()
            p.waitUntilExit()
            return p.terminationStatus == 0
        } catch {
            return false
        }
    }
}
