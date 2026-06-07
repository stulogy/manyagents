import Foundation
import Network

/// In-process server that exposes a "dispatch another agent" API to
/// coordinator sessions over a Unix domain socket. The MCP subprocess
/// (ManyAgents launched with --mcp-stdio) connects to this socket, auths
/// with a per-launch random token, and translates JSON-RPC tool calls
/// from claude into single-line JSON requests against this relay.
@MainActor
final class MCPRelay {
    static let shared = MCPRelay()

    /// Path of the active socket, if running. Coordinator sessions hand
    /// this to the MCP subprocess via env / args so it knows where to
    /// connect.
    private(set) var socketPath: String?

    /// Random token rotated each launch — the MCP subprocess includes
    /// it as its first auth message. Without it, anything that finds
    /// the socket can poke our API.
    private(set) var authToken: String?

    /// Weak handle to the manager so we don't tangle ownership. Set
    /// when the relay is wired in by AgentManager at app start.
    weak var manager: AgentManager?

    private var listener: NWListener?
    private var connections: [ObjectIdentifier: ClientConnection] = [:]

    private init() {}

    // MARK: - Lifecycle

    /// Attach the manager whose sessions the relay's operations target.
    /// Called once by AgentManager.init.
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
        let path = tmpDir.appendingPathComponent("relay-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString.prefix(8)).sock").path
        try? FileManager.default.removeItem(atPath: path)

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
            return await listAgents(id: id)
        case "dispatch":
            return await dispatch(req: req, id: id)
        default:
            return ["id": id, "ok": false, "error": "unknown op: \(op)"]
        }
    }

    @MainActor
    private func listAgents(id: String) async -> [String: Any] {
        guard let mgr = manager else { return ["id": id, "ok": false, "error": "manager unavailable"] }
        let agents: [[String: Any]] = mgr.sessions.map { s in
            [
                "id": s.id.uuidString,
                "project": ProjectNaming.name(forCwd: s.cwd),
                "cwd": s.cwd,
                "title": s.aiTitle ?? s.displayName,
                "status": statusString(s.status)
            ]
        }
        return ["id": id, "ok": true, "agents": agents]
    }

    @MainActor
    private func dispatch(req: [String: Any], id: String) async -> [String: Any] {
        guard let mgr = manager else { return ["id": id, "ok": false, "error": "manager unavailable"] }
        guard let targetIdStr = req["agent_id"] as? String,
              let targetUUID = UUID(uuidString: targetIdStr),
              let target = mgr.sessions.first(where: { $0.id == targetUUID })
        else { return ["id": id, "ok": false, "error": "unknown agent_id"] }
        guard let prompt = req["prompt"] as? String,
              !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return ["id": id, "ok": false, "error": "empty prompt"] }

        let wait = req["wait_for_result"] as? Bool ?? true
        let sourceIdStr = req["source_session_id"] as? String
        let sourceUUID = sourceIdStr.flatMap(UUID.init(uuidString:))

        // Snapshot how many turns are already queued ahead of ours so
        // `awaitTurnCompletion(skip:)` doesn't return the wrong reply
        // when the target was busy.
        let turnsAhead = (target.status == .running ? 1 : 0)
                       + target.pendingPrompts.count

        if let src = sourceUUID {
            mgr.handOff(from: src, to: target.id, prompt: prompt, autoSend: true)
        } else {
            target.send(prompt)
        }

        if !wait {
            return ["id": id, "ok": true, "agent_id": targetIdStr, "status": "dispatched"]
        }

        let reply = await awaitTurnCompletion(on: target, skip: turnsAhead)
        return [
            "id": id,
            "ok": true,
            "agent_id": targetIdStr,
            "reply": reply ?? "",
            "status": statusString(target.status)
        ]
    }

    /// Suspends until the (skip+1)-th `.turnCompleted` from `target`.
    /// Times out at 10 minutes so a hung agent doesn't pin a tool call
    /// forever.
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

        Task { @MainActor [weak self] in
            guard let self else { return }
            let reply = await self.relay?.handle(obj) ?? ["ok": false, "error": "relay gone"]
            self.send(reply)
        }
    }

    private func send(_ dict: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: []) else { return }
        var out = data
        out.append(0x0A)
        raw.send(content: out, completion: .contentProcessed { _ in })
    }
}
