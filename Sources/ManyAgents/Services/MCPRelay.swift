import Foundation
import Network

/// In-process server that exposes a "dispatch another agent" API to
/// coordinator sessions over a Unix domain socket. The MCP subprocess
/// (ManyAgents launched with --mcp-stdio) connects to this socket, auths
/// with a per-launch random token, and translates JSON-RPC tool calls
/// from claude into single-line JSON requests against this relay.
///
/// Why a Unix socket and not HTTP: the only client is a sibling
/// subprocess on the same machine, the request shapes are tiny, and
/// line-delimited JSON skips every line of HTTP-header parsing.
@MainActor
final class MCPRelay {
    static let shared = MCPRelay()

    /// Path of the active socket, if running. Coordinator sessions hand
    /// this to the MCP subprocess via env / args so it knows where to
    /// connect. Lives under /tmp/manyagents/relay-<pid>.sock to keep
    /// system temp dirs tidy on quit.
    private(set) var socketPath: String?

    /// Random token rotated each launch — the MCP subprocess includes
    /// it as its first auth message. Without it, anything that finds
    /// the socket can poke our API. Not strong against root, but
    /// adequate for "no rando script on this Mac can talk to it."
    private(set) var authToken: String?

    /// Weak handle to the manager so we don't tangle ownership. Set
    /// when the relay is wired in by AgentManager at app start.
    weak var manager: AgentManager?

    private var listener: NWListener?
    private var connections: [ObjectIdentifier: ClientConnection] = [:]

    private init() {}

    // MARK: - Lifecycle

    /// Attach the manager whose sessions the relay's operations target.
    /// Called once by AgentManager.init so any session can later just
    /// call `startIfNeeded()` without needing to plumb a manager ref.
    func attach(manager: AgentManager) {
        self.manager = manager
    }

    /// Start the relay if it isn't running already. Returns the socket
    /// path so the caller can use it when writing the mcp.json config.
    @discardableResult
    func startIfNeeded() throws -> String {
        if let existing = socketPath, listener != nil { return existing }

        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("manyagents", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        // Unix socket paths are capped at sun_path = 104 bytes on macOS.
        // PID + uuid suffix keeps us well under that even with long temp
        // prefixes, and rotates per-launch so stale sockets don't clash.
        let path = tmpDir.appendingPathComponent("relay-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString.prefix(8)).sock").path
        try? FileManager.default.removeItem(atPath: path)

        // NWEndpoint.unix is iOS/macOS 13+ — fine for our minimum target.
        let endpoint = NWEndpoint.unix(path: path)
        let params = NWParameters(tls: nil, tcp: NWProtocolTCP.Options())
        params.requiredLocalEndpoint = endpoint
        params.allowLocalEndpointReuse = true

        let listener = try NWListener(using: params)
        listener.newConnectionHandler = { [weak self] nwc in
            DispatchQueue.main.async {
                self?.accept(nwc)
            }
        }
        listener.start(queue: .main)

        self.listener = listener
        self.socketPath = path
        self.authToken = randomToken()
        return path
    }

    func stop() {
        listener?.cancel()
        listener = nil
        connections.values.forEach { $0.close() }
        connections.removeAll()
        if let p = socketPath {
            try? FileManager.default.removeItem(atPath: p)
        }
        socketPath = nil
        authToken = nil
    }

    // MARK: - Connection handling

    private func accept(_ raw: NWConnection) {
        let conn = ClientConnection(raw: raw, relay: self)
        connections[ObjectIdentifier(conn)] = conn
        conn.start()
    }

    fileprivate func drop(_ conn: ClientConnection) {
        connections.removeValue(forKey: ObjectIdentifier(conn))
    }

    private func randomToken() -> String {
        // 24 bytes of crypto-random → base64url → 32-ish chars.
        var bytes = [UInt8](repeating: 0, count: 24)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let data = Data(bytes)
        return data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: - Request dispatch

    fileprivate func handle(_ req: [String: Any]) async -> [String: Any] {
        let id = req["id"] as? String ?? ""
        guard let op = req["op"] as? String else {
            return ["id": id, "ok": false, "error": "missing op"]
        }
        switch op {
        case "list_agents":
            return await listAgents(req: req, id: id)
        case "read_agent":
            return await readAgent(req: req, id: id)
        case "new_agent":
            return await newAgent(req: req, id: id)
        case "dispatch":
            return await dispatch(req: req, id: id)
        case "set_notes":
            return await setNotes(req: req, id: id)
        case "mute_agent":
            return await setMuted(req: req, id: id, muted: true)
        case "unmute_agent":
            return await setMuted(req: req, id: id, muted: false)
        case "permission_prompt":
            return await permissionPrompt(req: req, id: id)
        case "open_preview":
            return await openPreview(req: req, id: id)
        default:
            return ["id": id, "ok": false, "error": "unknown op: \(op)"]
        }
    }

    @MainActor
    private func openPreview(req: [String: Any], id: String) async -> [String: Any] {
        guard let mgr = manager,
              let urlStr = req["url"] as? String,
              let url = URL(string: urlStr)
        else { return ["id": id, "ok": false, "error": "missing or invalid url"] }
        // Store under the CALLING tab's id (per-tab, no cross-tab fight).
        let sourceUUID = (req["source_session_id"] as? String).flatMap(UUID.init(uuidString:))
        let targetId = sourceUUID ?? mgr.activeSessionId
        if let targetId {
            mgr.previewURLs[targetId] = url
        }
        // Only steal focus into the browser when the ACTIVE tab is the one
        // that called it — a background agent stores its URL silently and
        // you see it when you switch to that tab, instead of yanking you
        // away from whatever you're reading.
        if targetId == mgr.activeSessionId {
            mgr.previewActive = true
        }
        return ["id": id, "ok": true, "url": urlStr]
    }

    // MARK: - Permission prompt

    /// Surface a permission request from claude as a banner on the
    /// owning session, then suspend until the user taps Allow / Deny.
    /// Replies allow/deny in the relay protocol; MCPStdioServer
    /// translates those into the `{behavior: ...}` JSON claude wants.
    @MainActor
    private func permissionPrompt(req: [String: Any], id: String) async -> [String: Any] {
        guard let mgr = manager else { return ["id": id, "ok": false, "error": "manager unavailable"] }
        guard let sourceIdStr = req["source_session_id"] as? String,
              let sourceUUID = UUID(uuidString: sourceIdStr),
              let session = mgr.sessions.first(where: { $0.id == sourceUUID })
        else { return ["id": id, "ok": false, "error": "unknown source session"] }
        let toolName = req["tool_name"] as? String ?? "Unknown"
        let rawInput = req["tool_input"] as? [String: Any] ?? [:]
        let typed = rawInput.mapValues(AnyCodable.from)

        // Stash on the session so the UI picker can render it. Resolve
        // when the user taps Allow / Deny via session.respondToPermission.
        let pending = AgentSession.PendingPermission(
            id: id,
            toolName: toolName,
            toolInput: typed,
            createdAt: Date()
        )
        session.pendingPermission = pending

        let decision = await awaitPermissionDecision(session: session, requestId: id)
        return [
            "id": id,
            "ok": true,
            "decision": decision.allow ? "allow" : "deny",
            "message": decision.message ?? ""
        ]
    }

    /// Suspend until the user resolves this permission request via
    /// `session.respondToPermission(allow:message:)`. Times out at
    /// 30 minutes — well beyond a sane wait, but bounds the relay.
    @MainActor
    private func awaitPermissionDecision(session: AgentSession, requestId: String) async -> (allow: Bool, message: String?) {
        await withCheckedContinuation { (cont: CheckedContinuation<(Bool, String?), Never>) in
            var resumed = false
            let cancellable = session.permissionDecisions
                .filter { $0.requestId == requestId }
                .prefix(1)
                .sink { decision in
                    if !resumed {
                        resumed = true
                        cont.resume(returning: (decision.allow, decision.message))
                    }
                }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1800) {
                if !resumed {
                    resumed = true
                    cancellable.cancel()
                    // Default to deny on timeout — safer than allow.
                    cont.resume(returning: (false, "Permission prompt timed out."))
                }
            }
        }
    }

    @MainActor
    private func listAgents(req: [String: Any], id: String) async -> [String: Any] {
        guard let mgr = manager else { return ["id": id, "ok": false, "error": "manager unavailable"] }
        let sourceUUID = (req["source_session_id"] as? String).flatMap(UUID.init(uuidString:))
        let orch = sourceUUID.flatMap { uid in mgr.sessions.first { $0.id == uid } }
        // The board: the other open tabs IN THE ORCHESTRATOR'S OWN PROJECT,
        // except hidden ones. Muted tabs stay listed (flagged). Tabs in other
        // projects are never surfaced.
        let orchCwd = orch?.cwd
        let visible = mgr.sessions.filter { s in
            guard s.id != sourceUUID, !s.hiddenFromOrchestrator else { return false }
            return orchCwd == nil || s.cwd == orchCwd
        }
        let agents: [[String: Any]] = visible
            .map { s -> [String: Any] in
                [
                    "id": s.id.uuidString,
                    "project": ProjectNaming.name(forCwd: s.cwd),
                    "cwd": s.cwd,
                    "title": s.boardTitle,
                    "status": statusString(s.status),
                    "muted": orch?.mutedTabIds.contains(s.id) ?? false,
                    "latest": s.latestSnippet
                ]
            }
        return ["id": id, "ok": true, "agents": agents]
    }

    /// Peek at a tab's recent transcript without dispatching to it — the
    /// orchestrator's "read/refresh" primitive.
    @MainActor
    private func readAgent(req: [String: Any], id: String) async -> [String: Any] {
        guard let mgr = manager else { return ["id": id, "ok": false, "error": "manager unavailable"] }
        guard let targetIdStr = req["agent_id"] as? String,
              let targetUUID = UUID(uuidString: targetIdStr),
              let target = mgr.sessions.first(where: { $0.id == targetUUID })
        else { return ["id": id, "ok": false, "error": "unknown agent_id"] }
        let tail = target.messages.suffix(14).map { m -> String in
            let role: String
            switch m.role {
            case .assistant: role = "assistant"
            case .user:      role = "user"
            case .system:    role = "system"
            }
            return "[\(role)] \(m.flatText)"
        }.joined(separator: "\n\n")
        return [
            "id": id, "ok": true,
            "agent_id": targetIdStr,
            "title": target.aiTitle ?? target.displayName,
            "status": statusString(target.status),
            "transcript_tail": tail
        ]
    }

    /// Create a new tab to work in — or REUSE an existing empty tab in the
    /// same project (no messages, nothing queued) so blank tabs don't pile
    /// up. Never reuses a tab that has history. Optionally sends a first
    /// prompt. Doesn't steal the user's focus.
    @MainActor
    private func newAgent(req: [String: Any], id: String) async -> [String: Any] {
        guard let mgr = manager else { return ["id": id, "ok": false, "error": "manager unavailable"] }
        // Default to the ORCHESTRATOR's own cwd so the new tab lands in
        // the same project (a tab in that row), not a fresh top-level
        // project. A subdir cwd (e.g. a worktree) groups as its own
        // project because the sidebar keys projects by exact cwd — which
        // fragmented spawned agents out of the orchestrator's project.
        var sourceCwd: String? = nil
        if let sidStr = req["source_session_id"] as? String,
           let sid = UUID(uuidString: sidStr),
           let src = mgr.sessions.first(where: { $0.id == sid }) {
            sourceCwd = src.cwd
        }
        let requested = req["cwd"] as? String
        let cwd = (requested?.isEmpty == false ? requested : nil) ?? sourceCwd
        guard let cwd else {
            return ["id": id, "ok": false, "error": "no cwd and no source session to default from"]
        }
        let prompt = (req["prompt"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        // Prefer an existing EMPTY tab in this project.
        let reusable = mgr.sessions.first {
            $0.cwd == cwd && !$0.isCoordinator && $0.messages.isEmpty && $0.pendingPrompts.isEmpty
        }
        let target: AgentSession
        let reused: Bool
        if let r = reusable {
            target = r
            reused = true
        } else {
            let prevActive = mgr.activeSessionId
            target = mgr.spawn(cwd: cwd)
            mgr.activeSessionId = prevActive   // spawn focuses the new tab; don't steal focus
            reused = false
        }

        if !prompt.isEmpty {
            // Anti-loop: suppress the wake for the specific turn this prompt
            // causes (a reused/new tab is idle, so it's the very next one).
            target.suppressedOrchestratorTurns.insert(target.completedTurns + 1)
            if let orchUUID = (req["source_session_id"] as? String).flatMap(UUID.init(uuidString:)),
               let orch = mgr.sessions.first(where: { $0.id == orchUUID }) {
                target.send("[Message from orchestrator \"\(orch.aiTitle ?? orch.displayName)\"]\n\n\(prompt)")
            } else {
                target.send(prompt)
            }
        }
        return ["id": id, "ok": true, "agent_id": target.id.uuidString, "reused": reused, "cwd": cwd]
    }

    /// Write the orchestrator's running "thinking" note.
    @MainActor
    private func setNotes(req: [String: Any], id: String) async -> [String: Any] {
        guard let mgr = manager else { return ["id": id, "ok": false, "error": "manager unavailable"] }
        guard let sourceUUID = (req["source_session_id"] as? String).flatMap(UUID.init(uuidString:)),
              let orch = mgr.sessions.first(where: { $0.id == sourceUUID })
        else { return ["id": id, "ok": false, "error": "unknown source session"] }
        orch.orchestratorNotes = req["notes"] as? String ?? ""
        return ["id": id, "ok": true]
    }

    /// Soft-mute / unmute a tab so its completions stop (or resume) waking
    /// the orchestrator. Mute keeps the tab on the board for reference.
    @MainActor
    private func setMuted(req: [String: Any], id: String, muted: Bool) async -> [String: Any] {
        guard let mgr = manager else { return ["id": id, "ok": false, "error": "manager unavailable"] }
        guard let sourceUUID = (req["source_session_id"] as? String).flatMap(UUID.init(uuidString:)),
              let orch = mgr.sessions.first(where: { $0.id == sourceUUID })
        else { return ["id": id, "ok": false, "error": "unknown source session"] }
        guard let targetUUID = (req["agent_id"] as? String).flatMap(UUID.init(uuidString:))
        else { return ["id": id, "ok": false, "error": "unknown agent_id"] }
        if muted { orch.mutedTabIds.insert(targetUUID) }
        else { orch.mutedTabIds.remove(targetUUID) }
        return ["id": id, "ok": true, "agent_id": targetUUID.uuidString, "muted": muted]
    }

    @MainActor
    private func dispatch(req: [String: Any], id: String) async -> [String: Any] {
        guard let mgr = manager else { return ["id": id, "ok": false, "error": "manager unavailable"] }
        guard let targetIdStr = req["agent_id"] as? String,
              let targetUUID = UUID(uuidString: targetIdStr),
              let target = mgr.sessions.first(where: { $0.id == targetUUID })
        else { return ["id": id, "ok": false, "error": "unknown agent_id — that tab may have been closed; call list_agents for current ids"] }
        guard let prompt = req["prompt"] as? String,
              !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return ["id": id, "ok": false, "error": "empty prompt"] }

        let wait = req["wait_for_result"] as? Bool ?? true
        let sourceIdStr = req["source_session_id"] as? String
        let sourceUUID = sourceIdStr.flatMap(UUID.init(uuidString:))

        // If the target was busy when this dispatch lands, its queue
        // already has work ahead of ours. We need to wait for those
        // turn-completions to drain BEFORE the one that belongs to
        // our prompt. Snapshot before send() so the count's right.
        let turnsAhead = (target.status == .running ? 1 : 0)
                       + target.pendingPrompts.count

        // Surface this dispatch in the Orchestrator panel.
        let recordId = mgr.recordDispatchStart(coordinatorId: sourceUUID,
                                               target: target, prompt: prompt)

        // Anti-loop: the turn-completion OUR prompt causes must not wake
        // the orchestrator back — it captures the reply here directly.
        // Indexed past the in-flight/queued turns so those still ping.
        target.suppressedOrchestratorTurns.insert(target.completedTurns + turnsAhead + 1)
        // Tag provenance so the receiving tab knows it's the orchestrator
        // talking, then send it as a normal user turn.
        if let src = sourceUUID, let s = mgr.sessions.first(where: { $0.id == src }) {
            target.send("[Message from orchestrator \"\(s.aiTitle ?? s.displayName)\"]\n\n\(prompt)")
        } else {
            target.send(prompt)
        }

        if !wait {
            mgr.recordDispatchEnd(recordId, success: true)
            return ["id": id, "ok": true, "agent_id": targetIdStr, "status": "dispatched"]
        }

        // Skip `turnsAhead` completions, then capture the one
        // belonging to our prompt.
        let reply = await awaitTurnCompletion(on: target, skip: turnsAhead)
        mgr.recordDispatchEnd(recordId, success: reply != nil)
        return [
            "id": id,
            "ok": true,
            "agent_id": targetIdStr,
            "reply": reply ?? "",
            "status": statusString(target.status)
        ]
    }

    /// Suspends until the (skip+1)-th `.turnCompleted` from `target` —
    /// i.e. wait through any in-flight + already-queued turns, then
    /// capture the one our dispatch caused. Times out at 10 minutes
    /// so a hung agent doesn't pin a coordinator's tool call forever.
    @MainActor
    private func awaitTurnCompletion(on target: AgentSession, skip: Int) async -> String? {
        await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            var resumed = false
            let cancellable = target.turnCompleted
                .dropFirst(skip)
                .prefix(1)
                .sink { text in
                    if !resumed {
                        resumed = true
                        cont.resume(returning: text)
                    }
                }
            // Belt-and-braces timeout. The cancellable is captured by
            // the work item so it stays alive until either path fires.
            DispatchQueue.main.asyncAfter(deadline: .now() + 600) {
                if !resumed {
                    resumed = true
                    cancellable.cancel()
                    cont.resume(returning: nil)
                }
            }
        }
    }

    private func statusString(_ status: AgentStatus) -> String {
        switch status {
        case .idle:    return "idle"
        case .running: return "running"
        case .waiting: return "waiting"
        case .error:   return "error"
        }
    }
}

// MARK: - Per-connection state

@MainActor
private final class ClientConnection {
    private let raw: NWConnection
    private weak var relay: MCPRelay?
    private var buffer = Data()
    private var authenticated = false

    init(raw: NWConnection, relay: MCPRelay) {
        self.raw = raw
        self.relay = relay
    }

    func start() {
        raw.stateUpdateHandler = { [weak self] state in
            DispatchQueue.main.async {
                switch state {
                case .failed, .cancelled:
                    self?.close()
                default:
                    break
                }
            }
        }
        raw.start(queue: .main)
        receive()
    }

    func close() {
        raw.cancel()
        relay?.drop(self)
    }

    private func receive() {
        raw.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let data, !data.isEmpty {
                    self.buffer.append(data)
                    self.drainLines()
                }
                if isComplete || error != nil {
                    self.close()
                    return
                }
                self.receive()
            }
        }
    }

    /// Pull complete LF-terminated JSON lines out of the buffer; one
    /// request per line, one response per line.
    private func drainLines() {
        while let nl = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer.prefix(upTo: nl)
            buffer.removeSubrange(buffer.startIndex...nl)
            if lineData.isEmpty { continue }
            handleLine(Data(lineData))
        }
    }

    private func handleLine(_ line: Data) {
        guard let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else {
            send(["ok": false, "error": "invalid json"])
            return
        }
        let op = obj["op"] as? String ?? ""

        // First message MUST be auth.
        if !authenticated {
            guard op == "auth",
                  let token = obj["token"] as? String,
                  token == relay?.authToken
            else {
                send(["id": obj["id"] as? String ?? "", "ok": false, "error": "unauthorized"])
                close()
                return
            }
            authenticated = true
            send(["id": obj["id"] as? String ?? "", "ok": true])
            return
        }

        // Authenticated requests run on main; reply asynchronously.
        Task { @MainActor [weak self] in
            guard let self else { return }
            let reply = await self.relay?.handle(obj) ?? ["ok": false, "error": "relay gone"]
            self.send(reply)
        }
    }

    private func send(_ dict: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: []) else { return }
        var out = data
        out.append(0x0A)  // newline terminator
        raw.send(content: out, completion: .contentProcessed { _ in })
    }
}
