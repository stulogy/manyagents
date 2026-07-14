import Foundation

/// Wraps `claude mcp list` / `claude mcp login` so MCP servers that need
/// OAuth (notably claude.ai connectors like Google Drive) can be
/// authenticated from inside ManyAgents. Our sessions drive claude
/// headlessly, where the TUI's /mcp flow doesn't exist — but the CLI
/// stores MCP tokens in the macOS keychain shared across all modes, so
/// one successful `claude mcp login` here fixes every session.
@MainActor
final class MCPConnectors: ObservableObject {
    static let shared = MCPConnectors()

    struct Server: Identifiable {
        enum Status: Equatable {
            case connected
            case needsAuth
            case failed(String)
        }
        let name: String
        let detail: String     // url or command line
        let status: Status
        var id: String { name }
    }

    @Published private(set) var servers: [Server] = []
    @Published private(set) var refreshing = false
    /// Name of the server whose `claude mcp login` is currently running.
    @Published private(set) var loginInFlight: String?
    /// Trailing output of the last login attempt — surfaced verbatim so
    /// connector-specific guidance (e.g. "authorize on claude.ai") reaches
    /// the user instead of dying in a pipe.
    @Published private(set) var lastLoginMessage: String?
    @Published private(set) var lastLoginSucceeded: Bool?

    /// Fires after a login attempt finishes successfully. AgentManager
    /// listens and recycles idle session processes so they reconnect to
    /// the newly-authorized server.
    static let authChanged = Notification.Name("ManyAgents.mcpAuthChanged")

    private init() {}

    // MARK: - List

    func refresh() {
        guard !refreshing else { return }
        refreshing = true
        runClaude(["mcp", "list"], timeout: 60) { [weak self] _, output in
            guard let self else { return }
            self.servers = Self.parseList(output)
            self.refreshing = false
        }
    }

    /// Parses `claude mcp list` lines of the shape
    ///   `<name>: <detail> - <status>`
    /// splitting on the LAST " - " so URLs containing dashes survive.
    static func parseList(_ output: String) -> [Server] {
        output.split(separator: "\n").compactMap { rawLine in
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)
            guard let colon = line.range(of: ": "),
                  let dash = line.range(of: " - ", options: .backwards),
                  colon.upperBound <= dash.lowerBound
            else { return nil }
            let name = String(line[..<colon.lowerBound])
            let detail = String(line[colon.upperBound..<dash.lowerBound])
            let statusText = String(line[dash.upperBound...])
            let status: Server.Status
            if statusText.localizedCaseInsensitiveContains("needs authentication") {
                status = .needsAuth
            } else if statusText.contains("✓") || statusText.localizedCaseInsensitiveContains("connected") {
                status = .connected
            } else {
                status = .failed(statusText)
            }
            return Server(name: name, detail: detail, status: status)
        }
    }

    // MARK: - Login

    /// Run `claude mcp login <name>`. The CLI owns the flow: for plain
    /// OAuth servers it opens the browser and catches the callback; for
    /// claude.ai connectors whose identity provider only accepts
    /// claude.ai's redirect it prints guidance instead — either way we
    /// surface the outcome and re-list.
    func login(_ name: String) {
        guard loginInFlight == nil else { return }
        loginInFlight = name
        lastLoginMessage = nil
        lastLoginSucceeded = nil
        runClaude(["mcp", "login", name], timeout: 300) { [weak self] code, output in
            guard let self else { return }
            self.loginInFlight = nil
            self.lastLoginSucceeded = code == 0
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            self.lastLoginMessage = trimmed.isEmpty
                ? (code == 0 ? "Authenticated." : "Login failed (exit \(code)).")
                : String(trimmed.suffix(400))
            if code == 0 {
                NotificationCenter.default.post(name: Self.authChanged, object: nil)
            }
            self.refreshing = false
            self.refresh()
        }
    }

    // MARK: - Process plumbing

    /// Run the claude CLI with `args`, calling back on main with the exit
    /// code and combined stdout+stderr. Kills the process at `timeout`.
    private func runClaude(_ args: [String], timeout: TimeInterval,
                           completion: @escaping @MainActor (Int32, String) -> Void) {
        guard let claudePath = ClaudeBridge.resolveClaudePath() else {
            completion(-1, "claude binary not found on PATH")
            return
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: claudePath)
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = ClaudeBridge.userPath
        env["NO_COLOR"] = "1"
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        p.standardInput = FileHandle.nullDevice

        // Read continuously so a chatty child can't fill the pipe and
        // stall. All buffer access is serialized on ioQueue — the
        // readability and termination handlers fire on different threads.
        let ioQueue = DispatchQueue(label: "mcp.cli-io")
        var collected = Data()
        pipe.fileHandleForReading.readabilityHandler = { h in
            let chunk = h.availableData
            ioQueue.async { collected.append(chunk) }
        }

        let watchdog = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)

        p.terminationHandler = { proc in
            watchdog.cancel()
            pipe.fileHandleForReading.readabilityHandler = nil
            let rest = pipe.fileHandleForReading.readDataToEndOfFile()
            let code = proc.terminationStatus
            ioQueue.async {
                collected.append(rest)
                let text = String(data: collected, encoding: .utf8) ?? ""
                DispatchQueue.main.async {
                    completion(code, text)
                }
            }
        }
        do { try p.run() } catch {
            watchdog.cancel()
            completion(-1, "failed to launch claude: \(error.localizedDescription)")
        }
    }
}
