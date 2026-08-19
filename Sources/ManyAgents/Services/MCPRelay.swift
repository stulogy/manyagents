import Foundation
import Combine
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
        // Board ops act on other tabs — orchestrator-only. Hard gate here
        // (not just in the advertised tool list) so a stale MCP subprocess
        // or a tab that lost the hat mid-conversation can't keep driving
        // the board.
        let boardOps: Set<String> = [
            "list_agents", "read_agent", "new_agent", "dispatch",
            "set_notes", "mute_agent", "unmute_agent",
            "rename_agent", "compact_agent", "close_agent"
        ]
        if boardOps.contains(op), let denied = await denyUnlessOrchestrator(req: req, id: id) {
            return denied
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
        case "notify_orchestrator":
            return await notifyOrchestrator(req: req, id: id)
        case "rename_agent":
            return await renameAgent(req: req, id: id)
        case "compact_agent":
            return await compactAgent(req: req, id: id)
        case "close_agent":
            return await closeAgent(req: req, id: id)
        default:
            return ["id": id, "ok": false, "error": "unknown op: \(op)"]
        }
    }

    /// nil when the calling session wears the orchestrator hat; an error
    /// payload otherwise. Board ops must come from the current orchestrator —
    /// every other tab is a worker and reaches it via notify_orchestrator.
    @MainActor
    private func denyUnlessOrchestrator(req: [String: Any], id: String) async -> [String: Any]? {
        guard let mgr = manager else { return ["id": id, "ok": false, "error": "manager unavailable"] }
        guard let sourceUUID = (req["source_session_id"] as? String).flatMap(UUID.init(uuidString:)),
              let source = mgr.sessions.first(where: { $0.id == sourceUUID }),
              source.isCoordinator
        else {
            return ["id": id, "ok": false,
                    "error": "orchestrator-only tool: this tab is not the project's orchestrator. Use notify_orchestrator to reach it."]
        }
        return nil
    }

    /// Rename any tab (the orchestrator naming a spawned tab, or fixing a
    /// bad auto-name). AutoNamer leaves named tabs alone, so it sticks.
    @MainActor
    private func renameAgent(req: [String: Any], id: String) async -> [String: Any] {
        guard let mgr = manager else { return ["id": id, "ok": false, "error": "manager unavailable"] }
        guard let targetUUID = (req["agent_id"] as? String).flatMap(UUID.init(uuidString:)),
              let target = mgr.sessions.first(where: { $0.id == targetUUID })
        else { return ["id": id, "ok": false, "error": "unknown agent_id"] }
        guard let title = (req["title"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty
        else { return ["id": id, "ok": false, "error": "empty title"] }
        // The orchestrator itself keeps its fixed role name.
        if target.isCoordinator { return ["id": id, "ok": false, "error": "can't rename the orchestrator tab"] }
        target.aiTitle = String(title.prefix(40))
        return ["id": id, "ok": true]
    }

    /// Compact a target tab's conversation (real teardown + reseed, not a
    /// "/compact" text message — which the CLI doesn't process and just
    /// makes the agent write a summary). Fails if the tab is mid-turn.
    @MainActor
    private func compactAgent(req: [String: Any], id: String) async -> [String: Any] {
        guard let mgr = manager else { return ["id": id, "ok": false, "error": "manager unavailable"] }
        guard let targetUUID = (req["agent_id"] as? String).flatMap(UUID.init(uuidString:)),
              let target = mgr.sessions.first(where: { $0.id == targetUUID })
        else { return ["id": id, "ok": false, "error": "unknown agent_id"] }
        if target.isCompacting { return ["id": id, "ok": true, "note": "already compacting"] }
        target.compact()
        // compact() no-ops if the tab is running/busy — report that honestly.
        guard target.isCompacting else {
            return ["id": id, "ok": false, "error": "tab is mid-turn — wait for it to finish, then compact"]
        }
        return ["id": id, "ok": true]
    }

    /// Close a target tab. Transcript stays on disk (recoverable via Resume).
    @MainActor
    private func closeAgent(req: [String: Any], id: String) async -> [String: Any] {
        guard let mgr = manager else { return ["id": id, "ok": false, "error": "manager unavailable"] }
        guard let targetUUID = (req["agent_id"] as? String).flatMap(UUID.init(uuidString:)),
              let target = mgr.sessions.first(where: { $0.id == targetUUID })
        else { return ["id": id, "ok": false, "error": "unknown agent_id"] }
        let sourceUUID = (req["source_session_id"] as? String).flatMap(UUID.init(uuidString:))
        if target.id == sourceUUID { return ["id": id, "ok": false, "error": "you can't close yourself"] }
        mgr.close(target)
        return ["id": id, "ok": true]
    }

    /// A worker tab pings the orchestrator, waking it to take a turn.
    /// Fire-and-forget (no wait_for_result) — the worker carries on. The
    /// board digest rides along on the dispatch, so the orchestrator wakes
    /// with fresh context.
    @MainActor
    private func notifyOrchestrator(req: [String: Any], id: String) async -> [String: Any] {
        guard let mgr = manager else { return ["id": id, "ok": false, "error": "manager unavailable"] }
        guard let message = (req["message"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !message.isEmpty
        else { return ["id": id, "ok": false, "error": "empty message"] }
        // Route to the orchestrator that DISPATCHED this tab, else the one in
        // its own project — never to some unrelated session's orchestrator.
        // The dispatch link matters: a tab spawned into another repo has no
        // orchestrator "in this project", so its report used to die at the
        // relay with an error while the orchestrator waited for it.
        let sourceUUID = (req["source_session_id"] as? String).flatMap(UUID.init(uuidString:))
        guard let sender = sourceUUID.flatMap({ uid in mgr.sessions.first { $0.id == uid } }) else {
            return ["id": id, "ok": false, "error": "unknown source session"]
        }
        guard let orch = mgr.reportTarget(for: sender) else {
            return ["id": id, "ok": false, "error": "no orchestrator to report to — nobody dispatched this tab and no orchestrator is designated in its project"]
        }
        // Don't let the orchestrator ping itself.
        if sender.id == orch.id {
            return ["id": id, "ok": false, "error": "you are the orchestrator"]
        }
        let name = sender.aiTitle ?? sender.displayName
        // Steered into the orchestrator's RUNNING turn when it's busy (it
        // reads the ping at its next step) — a queued ping used to sit
        // undelivered behind a long orchestrator turn.
        let delivery = orch.deliverNow("[Message from tab \"\(name)\" — it pinged you and needs a turn]\n\n\(message)")
        return ["id": id, "ok": true,
                "delivery": delivery.steered ? "injected_into_running_turn" : "started_a_turn"]
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
    /// `session.respondToPermission(allow:message:)`. Times out at 24
    /// minutes — well beyond a sane wait, but bounds the relay, and lands
    /// inside the MCP client's own wait so claude gets a real deny rather
    /// than having the tool call aborted under it.
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
            DispatchQueue.main.asyncAfter(deadline: .now() + 1440) {
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
        //
        // Compared by project ROOT so tabs the orchestrator spawned into git
        // worktrees stay on its board. Matching raw cwds dropped them: it
        // created six worktree tabs and then could not see a single one of
        // them, having to track them by id from memory.
        // Plus any tab this orchestrator dispatched itself: new_agent accepts
        // a cwd in another repo, and such a tab used to vanish from the board
        // the moment it was created — list_agents answered "No other open
        // tabs" about a tab the orchestrator had just spawned.
        let orchRoot = orch?.projectRoot
        let visible = mgr.sessions.filter { s in
            guard s.id != sourceUUID, !s.hiddenFromOrchestrator else { return false }
            if s.reportToOrchestratorId != nil, s.reportToOrchestratorId == sourceUUID { return true }
            return orchRoot == nil || s.projectRoot == orchRoot
        }
        let agents: [[String: Any]] = visible
            .map { s -> [String: Any] in
                [
                    "id": s.id.uuidString,
                    "project": ProjectNaming.name(forCwd: s.projectRoot),
                    "cwd": s.cwd,
                    // Where the tab sits inside the project — a worktree or a
                    // nested repo — so parallel tabs are distinguishable.
                    "at": ProjectNaming.subprojectLabel(forCwd: s.cwd),
                    // Flags a dispatched tab living in a different repo, so
                    // the orchestrator reads it as an outpost rather than as
                    // one more tab in its own project.
                    "outside": orchRoot != nil && s.projectRoot != orchRoot,
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
    /// A short, human tab title derived from a task prompt: strip any
    /// `[Message from ...]` wrapper, take the first line, drop trailing
    /// punctuation, and cap the length. Used when the orchestrator spawns a
    /// worker without naming it, so the tab reads as the task rather than the
    /// worker's opening sentence.
    static func titleFromPrompt(_ prompt: String) -> String {
        var s = prompt
        if s.hasPrefix("["), let close = s.range(of: "]") {
            s = String(s[close.upperBound...])
        }
        let firstLine = s.split(whereSeparator: \.isNewline).first.map(String.init) ?? s
        let trimmed = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
        let clean = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: ".:!?- "))
        return String(clean.prefix(40))
    }

    /// same project (no messages, nothing queued) so blank tabs don't pile
    /// up. Never reuses a tab that has history. Optionally sends a first
    /// prompt. Doesn't steal the user's focus.
    @MainActor
    private func newAgent(req: [String: Any], id: String) async -> [String: Any] {
        guard let mgr = manager else { return ["id": id, "ok": false, "error": "manager unavailable"] }
        // Default to the ORCHESTRATOR's own cwd so the new tab lands in
        // the same project (a tab in that row), not a fresh top-level
        // project. An explicit worktree cwd is fine now: worktrees resolve
        // to the same project root, so such a tab stays on the board and
        // nests under the project in the sidebar instead of fragmenting
        // out of it.
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

        // Orchestrator-chosen title — set it so AutoNamer leaves it alone
        // and the tab shows the name the orchestrator intended. When the
        // orchestrator omits a title, derive one from the task prompt rather
        // than letting AutoNamer name the tab from the worker's rambling first
        // line ("I'm reading the context and will pre..."). A task-derived name
        // is always more useful, and the orchestrator can rename_agent later.
        if let title = (req["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !title.isEmpty {
            target.aiTitle = String(title.prefix(40))
        } else if !prompt.isEmpty {
            target.aiTitle = Self.titleFromPrompt(prompt)
        }
        // The tab belongs to whoever spawned it, task or no task: that link is
        // what keeps it on the orchestrator's board and lets it ping back when
        // it sits outside the orchestrator's own project.
        let orchUUID = (req["source_session_id"] as? String).flatMap(UUID.init(uuidString:))
        target.reportToOrchestratorId = orchUUID
        if !prompt.isEmpty {
            // Spawned with a task → auto-report back to the orchestrator
            // when it finishes (new_agent doesn't wait).
            target.pendingOrchestratorReport = true
            let promptId: UUID
            if let orchUUID, let orch = mgr.sessions.first(where: { $0.id == orchUUID }) {
                promptId = target.send("[Message from orchestrator \"\(orch.aiTitle ?? orch.displayName)\"]\n\n\(prompt)")
            } else {
                promptId = target.send(prompt)
            }
            // Anti-loop: the turn this prompt causes must not ALSO reach the
            // orchestrator via the board digest — the auto-report covers it.
            target.suppressedPromptIds.insert(promptId)
        }
        // Tell the caller when the tab landed in a different repo — an
        // orchestrator that passes a cwd from a note or a file path deserves
        // to hear that it just opened an outpost, not a tab next door.
        let sourceRoot = sourceCwd.map { ProjectNaming.projectRoot(forCwd: $0) }
        let targetRoot = ProjectNaming.projectRoot(forCwd: cwd)
        return ["id": id, "ok": true, "agent_id": target.id.uuidString, "reused": reused,
                "cwd": cwd, "project": ProjectNaming.name(forCwd: targetRoot),
                "outside": sourceRoot != nil && sourceRoot != targetRoot]
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

        // Fire-and-forget by default: the orchestrator must not sit inside a
        // blocked tool call while a tab works — the tab auto-reports when its
        // turn ends. Waiting is opt-in for quick questions only.
        let wait = req["wait_for_result"] as? Bool ?? false
        let sourceIdStr = req["source_session_id"] as? String
        let sourceUUID = sourceIdStr.flatMap(UUID.init(uuidString:))

        // Surface this dispatch in the Orchestrator panel.
        let recordId = mgr.recordDispatchStart(coordinatorId: sourceUUID,
                                               target: target, prompt: prompt)

        // Fire-and-forget dispatch (not waiting for the reply) → have the
        // tab auto-report to the orchestrator when it finishes. (The
        // wait_for_result path captures the reply synchronously instead.)
        if !wait {
            target.pendingOrchestratorReport = true
            target.reportToOrchestratorId = sourceUUID
        }
        // Tag provenance so the receiving tab knows it's the orchestrator
        // talking, then deliver it NOW: steered into the tab's running turn
        // when it's busy (it reads the message at its next tool boundary)
        // instead of queuing behind the whole turn — a queued "stop what
        // you're doing" used to sit unread while the tab kept working and
        // the orchestrator, seeing the dispatch succeed, assumed it knew.
        let source = sourceUUID.flatMap { uid in mgr.sessions.first { $0.id == uid } }
        let outgoing: String
        if let source {
            outgoing = "[Message from orchestrator \"\(source.aiTitle ?? source.displayName)\"]\n\n\(prompt)"
        } else {
            outgoing = prompt
        }
        // `interrupt`: a control message ("stand down") can't wait for a long
        // tool call to return, so kill the turn and deliver it as the next one.
        let interrupt = req["interrupt"] as? Bool ?? false
        let delivery: (coveringPromptId: UUID?, steered: Bool)
        if interrupt, target.status == .running || target.bridge.isBusy {
            delivery = (target.deliverInterrupting(outgoing), false)
        } else {
            delivery = target.deliverNow(outgoing)
        }
        // Anti-loop: the turn that carries OUR prompt must not wake the
        // orchestrator back through the board digest — it's captured here
        // directly (or by the auto-report). When steered, that's the LIVE
        // turn; when sent, the fresh prompt's own turn.
        if let coveringId = delivery.coveringPromptId {
            target.suppressedPromptIds.insert(coveringId)
        }

        if !wait {
            mgr.recordDispatchEnd(recordId, success: true)
            var result: [String: Any] = ["id": id, "ok": true, "agent_id": targetIdStr, "status": "dispatched"]
            if interrupt {
                result["note"] = "Interrupted that tab's turn and delivered your message as its next turn — it starts reading it now. Its previous work stopped where it stood; expect its reply to reflect that."
            } else if delivery.steered {
                result["note"] = "That tab is MID-TURN: your message was injected into its running turn and it will read it at its next step — but it has NOT read or acted on it yet. If it's stuck in a long tool call (a build, a test run) that step can be minutes away, so for anything it must comply with, either re-send with interrupt true or confirm via its ping / read_agent before assuming it stopped."
            }
            return result
        }

        // Steered into a live turn: that turn's end is NOT reliably the answer
        // to our message (the CLI may run it as a fresh turn instead), and the
        // old behavior — block, then hand back whatever text landed — either
        // burned the full 10 minutes against a busy tab or returned a stale
        // reply. Don't pretend to wait: report the delivery and let the tab's
        // own ping carry the answer.
        if delivery.steered {
            if let coveringId = delivery.coveringPromptId {
                target.suppressedPromptIds.remove(coveringId)
            }
            target.pendingOrchestratorReport = true
            target.reportToOrchestratorId = sourceUUID
            mgr.recordDispatchEnd(recordId, success: true)
            return [
                "id": id, "ok": true, "agent_id": targetIdStr,
                "status": "delivered_mid_turn", "reply": "",
                "note": "That tab was already mid-turn, so waiting would have blocked you without getting an answer. Your message is injected into its running turn and it reads it at its next step; it pings you when it stops. End your turn. If it must obey NOW, re-send with interrupt true."
            ]
        }

        let outcome = await awaitTurnEnd(on: target,
                                         promptId: delivery.coveringPromptId,
                                         bailForInterjectionsOn: source)
        if case .interjected = outcome {
            // A message just landed in the WAITER's own context — it can only
            // read it once this tool call returns, so return now. The tab keeps
            // working; make sure its eventual stop still reaches the board.
            if let coveringId = delivery.coveringPromptId {
                target.suppressedPromptIds.remove(coveringId)
            }
            target.pendingOrchestratorReport = true
            target.reportToOrchestratorId = sourceUUID
            mgr.recordDispatchEnd(recordId, success: true)
            return [
                "id": id, "ok": true, "agent_id": targetIdStr,
                "status": "still_running", "reply": "",
                "note": "Stopped waiting because a message arrived FOR YOU while you were blocked — it is in your context now; read and act on it this turn. The tab is still working and pings you when it stops."
            ]
        }
        guard case .ended(let end) = outcome else {
            // Still going after the timeout. Never leave the orchestrator on a
            // silent dead end: drop the suppression so the eventual end reaches
            // the board, and arm the auto-report so the tab wakes the
            // orchestrator itself when it finally stops.
            if let coveringId = delivery.coveringPromptId {
                target.suppressedPromptIds.remove(coveringId)
            }
            target.pendingOrchestratorReport = true
            target.reportToOrchestratorId = sourceUUID
            mgr.recordDispatchEnd(recordId, success: false)
            return [
                "id": id, "ok": true, "agent_id": targetIdStr,
                "status": "still_running", "reply": "",
                "note": "Waited 10 minutes and the tab is STILL working — this is not a failure. You'll be pinged automatically when it stops, so don't block on it or re-send: go do other work."
            ]
        }
        if end.interrupted {
            // The user cut in (force-send / answered a question). Our prompt's
            // turn is gone, but the tab carries on — arm the report so its next
            // stop still reaches the orchestrator.
            target.pendingOrchestratorReport = true
            target.reportToOrchestratorId = sourceUUID
            mgr.recordDispatchEnd(recordId, success: false)
            return [
                "id": id, "ok": true, "agent_id": targetIdStr,
                "status": "interrupted", "reply": end.text,
                "note": "The user interrupted that turn. You'll be pinged when the tab next stops."
            ]
        }
        mgr.recordDispatchEnd(recordId, success: end.status != .error)
        if end.status == .error {
            return [
                "id": id, "ok": false, "agent_id": targetIdStr,
                "status": "error",
                "error": "that tab's turn ended with an error and it did NOT do the work: \(end.text)"
            ]
        }
        return [
            "id": id,
            "ok": true,
            "agent_id": targetIdStr,
            "reply": end.text,
            "status": statusString(target.status)
        ]
    }

    /// How a blocking wait on a dispatched turn resolved.
    private enum WaitOutcome {
        case ended(AgentSession.TurnEnd)
        case timedOut
        /// A message was steered into the WAITER's running turn while it sat
        /// in this tool call. It can only read that message once the call
        /// returns — so the wait aborts instead of keeping the waiter deaf.
        case interjected
    }

    /// Suspends until the turn covering the delivery ends — cleanly, on an
    /// error, or by interruption. `promptId` nil means the delivery was
    /// steered into a CLI-initiated turn with no app-side id: the NEXT turn
    /// end is the one that covers it. Times out at 10 minutes so a
    /// long-running tab doesn't pin a coordinator's tool call forever; the
    /// caller turns that into an auto-report instead. If a message lands in
    /// `waiter`'s own turn meanwhile, resolves `.interjected` immediately.
    ///
    /// Matched by prompt id rather than by counting turn completions: turns
    /// that error emit no completion, so the old count-and-skip arithmetic
    /// drifted and waited on a signal that never arrived — the orchestrator
    /// then sat "waiting for tabs" until the timeout, with the real reply
    /// already discarded.
    @MainActor
    private func awaitTurnEnd(on target: AgentSession, promptId: UUID?,
                              bailForInterjectionsOn waiter: AgentSession?) async -> WaitOutcome {
        // The turn can land while this call suspends — check the record first
        // so a late subscriber doesn't wait for an event already gone by.
        if let promptId, let last = target.lastTurnEnd, last.promptId == promptId {
            return .ended(last)
        }
        return await withCheckedContinuation { (cont: CheckedContinuation<WaitOutcome, Never>) in
            var resumed = false
            var cancellables: [AnyCancellable] = []
            let finish: (WaitOutcome) -> Void = { outcome in
                guard !resumed else { return }
                resumed = true
                cont.resume(returning: outcome)
            }
            target.turnEnded
                .filter { promptId == nil || $0.promptId == promptId }
                .prefix(1)
                .sink { finish(.ended($0)) }
                .store(in: &cancellables)
            waiter?.interjectionDelivered
                .prefix(1)
                .sink { finish(.interjected) }
                .store(in: &cancellables)
            // Belt-and-braces timeout. The cancellables are captured by
            // the work item so they stay alive until a path fires.
            DispatchQueue.main.asyncAfter(deadline: .now() + 600) {
                cancellables.forEach { $0.cancel() }
                finish(.timedOut)
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
