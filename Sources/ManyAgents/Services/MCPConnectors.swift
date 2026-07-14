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

    /// Detects a tool result complaining that an MCP server needs
    /// authentication and extracts the quoted server name, e.g.
    ///   This is a claude.ai MCP connector. Ask the user to run /mcp and
    ///   select "claude.ai Google Drive" to authenticate.
    /// Returns nil when the text isn't an MCP auth complaint or no name
    /// can be recovered. Pure string work — callable from any context.
    nonisolated static func authNeededServer(in content: String) -> String? {
        let lower = content.lowercased()
        // "authenticat…" covers authenticate/authentication; "authoriz…"
        // covers the CLI's expired-token wording: MCP server "X" requires
        // re-authorization (token expired).
        guard lower.contains("authenticat") || lower.contains("authoriz"),
              lower.contains("mcp"),
              let open = content.range(of: "\""),
              let close = content.range(of: "\"", range: open.upperBound..<content.endIndex)
        else { return nil }
        let name = String(content[open.upperBound..<close.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty || name.count > 80 ? nil : name
    }

    private init() {}

    // MARK: - List

    func refresh() {
        guard !refreshing else { return }
        refreshing = true
        // Stale outcome messages from an earlier flow just add noise
        // once statuses are re-verified. Keep them only mid-login.
        if loginInFlight == nil {
            lastLoginMessage = nil
            lastLoginSucceeded = nil
        }
        runClaude(["mcp", "list"], timeout: 60) { [weak self] _, output in
            guard let self else { return }
            self.servers = Self.parseList(output)
            // `mcp list` is only trusted for ENUMERATION. Its statuses can
            // be flat wrong — it reported ✔ Connected for claude.ai
            // connectors that `mcp get` (and claude.ai itself) said needed
            // authentication. Verify every server with the per-server query.
            let names = self.servers.map(\.name)
            guard !names.isEmpty else { self.refreshing = false; return }
            var remaining = names.count
            for name in names {
                let finish: @MainActor (Server.Status?) -> Void = { [weak self] status in
                    guard let self else { return }
                    if let status,
                       let idx = self.servers.firstIndex(where: { $0.name == name }) {
                        let s = self.servers[idx]
                        self.servers[idx] = Server(name: s.name, detail: s.detail, status: status)
                    }
                    remaining -= 1
                    if remaining == 0 { self.refreshing = false }
                }
                if name.hasPrefix("claude.ai"), self.loginInFlight != name {
                    // Purge the CLI's cached token BEFORE checking. The
                    // cache goes stale when the connector is disconnected
                    // ON claude.ai and makes every status query claim
                    // Connected. A valid grant re-derives instantly from
                    // the claude.ai account, so this is loss-free; a
                    // revoked one finally reads Needs authentication.
                    // (Skipped mid-login so we never purge a fresh token.)
                    self.runClaude(["mcp", "logout", name], timeout: 60) { _, _ in
                        self.fetchStatus(name, completion: finish)
                    }
                } else {
                    self.fetchStatus(name, completion: finish)
                }
            }
        }
    }

    /// True status of one server via `claude mcp get` — the reliable
    /// signal. nil when the output couldn't be parsed.
    private func fetchStatus(_ name: String,
                             completion: @escaping @MainActor (Server.Status?) -> Void) {
        runClaude(["mcp", "get", name], timeout: 60) { _, output in
            completion(Self.parseGetStatus(output))
        }
    }

    nonisolated static func parseGetStatus(_ output: String) -> Server.Status? {
        guard let line = output.split(separator: "\n")
            .first(where: { $0.contains("Status:") }) else { return nil }
        let s = String(line)
        if s.localizedCaseInsensitiveContains("needs authentication") { return .needsAuth }
        if s.contains("✔") || s.localizedCaseInsensitiveContains("connected") { return .connected }
        let detail = s.replacingOccurrences(of: "Status:", with: "")
            .trimmingCharacters(in: .whitespaces)
        return .failed(detail.isEmpty ? "Unknown status" : detail)
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

    /// Run `claude mcp login <name>`. The CLI owns the flow, but for
    /// claude.ai connectors it only HANDS OFF to the browser and exits —
    /// "Once authorized on claude.ai, the connector will be available the
    /// next time you start Claude Code." Exit 0 therefore does NOT mean
    /// authorized. We poll the health list until the server actually
    /// flips to connected before declaring success (and recycling
    /// session processes), instead of trusting the exit code.
    /// Bumped on every login start AND on cancel. Poll/login callbacks
    /// carry the generation they were started under and bail out when it
    /// no longer matches — cancellation without cancellation tokens.
    private var loginGeneration = 0
    /// The running `claude mcp login` process, kept so Cancel can kill
    /// a flow that's still waiting (regular OAuth callback servers).
    private var loginProcess: Process?

    /// Name of the server whose `claude mcp logout` is currently running.
    @Published private(set) var logoutInFlight: String?

    /// Clear stored OAuth credentials for a server via `claude mcp
    /// logout`, then VERIFY against the health list — for claude.ai
    /// connectors the grant lives on the claude.ai account, so the CLI
    /// re-derives credentials immediately and logout is a no-op. Say so
    /// instead of falsely reporting "disconnected".
    func logout(_ name: String) {
        guard logoutInFlight == nil, loginInFlight == nil else { return }
        logoutInFlight = name
        runClaude(["mcp", "logout", name], timeout: 60) { [weak self] code, output in
            guard let self else { return }
            self.fetchStatus(name) { [weak self] status in
                guard let self else { return }
                self.logoutInFlight = nil
                if let status,
                   let idx = self.servers.firstIndex(where: { $0.name == name }) {
                    let s = self.servers[idx]
                    self.servers[idx] = Server(name: s.name, detail: s.detail, status: status)
                }
                let stillConnected = status == .connected
                if stillConnected {
                    self.lastLoginSucceeded = false
                    self.lastLoginMessage = "\(name) is managed on claude.ai (link below)."
                } else if code == 0 {
                    self.lastLoginSucceeded = true
                    self.lastLoginMessage = "\(name) disconnected."
                } else {
                    self.lastLoginSucceeded = false
                    let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
                    self.lastLoginMessage = trimmed.isEmpty
                        ? "Disconnect failed (exit \(code))."
                        : String(trimmed.suffix(400))
                }
            }
        }
    }

    /// Abort the in-flight authorization watch — the browser flow errored
    /// or the user changed their mind. Everything re-enables immediately.
    func cancelLogin() {
        guard loginInFlight != nil else { return }
        loginGeneration += 1
        loginProcess?.terminate()
        loginProcess = nil
        loginInFlight = nil
        lastLoginSucceeded = false
        lastLoginMessage = "Authorization canceled. You can retry any time."
        refresh()
    }

    func login(_ name: String) {
        guard loginInFlight == nil else { return }
        loginGeneration += 1
        let gen = loginGeneration
        loginInFlight = name
        lastLoginMessage = nil
        lastLoginSucceeded = nil
        loginProcess = runClaude(["mcp", "login", name], timeout: 300) { [weak self] code, output in
            guard let self, gen == self.loginGeneration else { return }
            self.loginProcess = nil
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            let handedOffToBrowser = trimmed.localizedCaseInsensitiveContains("authoriz")
                || trimmed.localizedCaseInsensitiveContains("claude.ai")
            if code == 0 || handedOffToBrowser {
                self.lastLoginMessage = "Finish the sign-in in your browser — watching for \(name) to come online…"
                self.pollUntilConnected(name, generation: gen)
            } else {
                self.loginInFlight = nil
                self.lastLoginSucceeded = false
                self.lastLoginMessage = trimmed.isEmpty
                    ? "Login failed (exit \(code))."
                    : String(trimmed.suffix(400))
                self.refresh()
            }
        }
    }

    /// Re-check `claude mcp list` every few seconds until `name` reports
    /// connected (success: notify + stop), the user cancels (generation
    /// mismatch), or ~3 minutes pass (give up with guidance). Runs while
    /// the user completes the browser flow.
    private func pollUntilConnected(_ name: String, generation: Int, attempt: Int = 0) {
        guard generation == loginGeneration else { return }
        guard attempt < 30 else {
            loginInFlight = nil
            lastLoginSucceeded = false
            lastLoginMessage = "Still waiting on \(name). Finish the authorization in the browser, then refresh here."
            refresh()
            return
        }
        fetchStatus(name) { [weak self] status in
            guard let self, generation == self.loginGeneration else { return }
            if let status,
               let idx = self.servers.firstIndex(where: { $0.name == name }) {
                let s = self.servers[idx]
                self.servers[idx] = Server(name: s.name, detail: s.detail, status: status)
            }
            if status == .connected {
                self.loginInFlight = nil
                self.lastLoginSucceeded = true
                self.lastLoginMessage = "\(name) authorized. Sessions reconnect on their next message."
                NotificationCenter.default.post(name: Self.authChanged, object: nil)
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
                    self?.pollUntilConnected(name, generation: generation, attempt: attempt + 1)
                }
            }
        }
    }

    // MARK: - Process plumbing

    /// Run the claude CLI with `args`, calling back on main with the exit
    /// code and combined stdout+stderr. Kills the process at `timeout`.
    /// Returns the Process so callers can terminate it early (Cancel).
    @discardableResult
    private func runClaude(_ args: [String], timeout: TimeInterval,
                           completion: @escaping @MainActor (Int32, String) -> Void) -> Process? {
        guard let claudePath = ClaudeBridge.resolveClaudePath() else {
            completion(-1, "claude binary not found on PATH")
            return nil
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
            return nil
        }
        return p
    }
}
