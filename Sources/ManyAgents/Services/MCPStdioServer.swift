import Foundation
import Network

/// When ManyAgents is launched with `--mcp-stdio`, the binary doesn't
/// boot SwiftUI — it runs THIS instead. The process becomes a tiny MCP
/// (Model Context Protocol) JSON-RPC server that claude spawns as a
/// child process. Tool calls from claude get translated into Unix-
/// socket requests against the in-process `MCPRelay` of the parent
/// ManyAgents app, the relay performs the work (list sessions,
/// dispatch a prompt to another agent, wait for the reply), and the
/// response is wrapped back into JSON-RPC and written to stdout.
///
/// All of this stays bundled in the single ManyAgents binary; no
/// separate executable target, no separate Swift project. The binary
/// dual-modes purely off its CLI args.
enum MCPStdioServer {
    struct Args {
        let socketPath: String
        let token: String
        /// Source agent's UUID — every dispatch we forward to the
        /// relay includes this so chain provenance ("from <agent>")
        /// gets attached and the hop budget can be respected.
        let sourceSessionId: String?
    }

    /// Parse expected args. Returns nil if this isn't an MCP-stdio
    /// launch, in which case the caller continues to the SwiftUI app.
    static func parseArgs(_ args: [String]) -> Args? {
        guard args.contains("--mcp-stdio") else { return nil }
        var socket: String?
        var token: String?
        var source: String?
        var i = 0
        while i < args.count {
            switch args[i] {
            case "--socket":   if i + 1 < args.count { socket = args[i + 1]; i += 1 }
            case "--token":    if i + 1 < args.count { token = args[i + 1]; i += 1 }
            case "--source":   if i + 1 < args.count { source = args[i + 1]; i += 1 }
            default: break
            }
            i += 1
        }
        guard let s = socket, let t = token else { return nil }
        return Args(socketPath: s, token: t, sourceSessionId: source)
    }

    /// Run the MCP server loop. Blocks until stdin closes (claude
    /// disconnects). Never returns under normal use.
    static func run(_ args: Args) -> Never {
        let server = ServerState(args: args)
        server.connectRelay()
        server.runLoop()
        exit(0)
    }
}

// MARK: - Internals

private final class ServerState {
    let args: MCPStdioServer.Args
    private var relay: NWConnection?
    /// Outstanding relay requests, keyed by request id. Each pending
    /// entry holds a continuation that resumes when the matching
    /// reply lands. Allows multiple in-flight tool calls in theory,
    /// though in practice claude calls one at a time.
    private var pending: [String: (Result<[String: Any], Error>) -> Void] = [:]
    private var relayBuffer = Data()
    private let lock = NSLock()
    /// Strictly serializes writes to stdout so JSON-RPC frames never
    /// interleave even when async tool calls race each other.
    private let stdoutQueue = DispatchQueue(label: "mcp.stdout")
    /// All NWConnection callbacks (state changes, receives, reconnect
    /// timers) run here. This must NOT be the main queue: `runLoop()`
    /// blocks the main thread in a synchronous stdin read, so anything
    /// scheduled on .main would never execute — the auth handshake
    /// would never send and relay replies would never drain, hanging
    /// every tool call until claude gives up.
    private let netQueue = DispatchQueue(label: "mcp.relay-client")

    init(args: MCPStdioServer.Args) {
        self.args = args
    }

    // MARK: - Relay connection

    /// Tracks how many times we've tried to connect — used so the
    /// failure handler only auto-reconnects a few times before giving
    /// up and failing any pending tool calls.
    private var connectAttempts: Int = 0
    private let maxConnectAttempts: Int = 8  // ~2 s of backoff total

    func connectRelay() {
        // Race window: when claude spawns this subprocess, the parent
        // ManyAgents may have JUST called listener.start() and not yet
        // bound the socket. Retry a handful of times with linear backoff
        // before giving up. The wait per attempt is ~250 ms.
        connectAttempts += 1
        let endpoint = NWEndpoint.unix(path: args.socketPath)
        let params = NWParameters(tls: nil, tcp: NWProtocolTCP.Options())
        let conn = NWConnection(to: endpoint, using: params)
        relay = conn
        conn.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.connectAttempts = 0
                self.sendAuth()
            case .failed, .cancelled:
                if self.connectAttempts < self.maxConnectAttempts {
                    self.netQueue.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                        self?.connectRelay()
                    }
                } else {
                    self.failAllPending(NSError(
                        domain: "MCPStdio",
                        code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "relay unreachable after \(self.maxConnectAttempts) attempts"]
                    ))
                }
            default:
                break
            }
        }
        conn.start(queue: netQueue)
        receiveRelay()
    }

    private func sendAuth() {
        let id = UUID().uuidString
        sendRelay(["id": id, "op": "auth", "token": args.token])
    }

    private func sendRelay(_ payload: [String: Any]) {
        guard let conn = relay,
              let data = try? JSONSerialization.data(withJSONObject: payload, options: [])
        else { return }
        var out = data
        out.append(0x0A)
        conn.send(content: out, completion: .contentProcessed { _ in })
    }

    private func receiveRelay() {
        relay?.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.relayBuffer.append(data)
                self.drainRelayLines()
            }
            if isComplete || error != nil {
                self.failAllPending(error ?? NSError(domain: "MCPStdio", code: -2, userInfo: [NSLocalizedDescriptionKey: "relay EOF"]))
                return
            }
            self.receiveRelay()
        }
    }

    private func drainRelayLines() {
        while let nl = relayBuffer.firstIndex(of: 0x0A) {
            let line = relayBuffer.prefix(upTo: nl)
            relayBuffer.removeSubrange(relayBuffer.startIndex...nl)
            if line.isEmpty { continue }
            guard let obj = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any] else { continue }
            handleRelayReply(obj)
        }
    }

    private func handleRelayReply(_ obj: [String: Any]) {
        guard let id = obj["id"] as? String else { return }
        lock.lock()
        let cb = pending.removeValue(forKey: id)
        lock.unlock()
        cb?(.success(obj))
    }

    private func failAllPending(_ error: Error) {
        lock.lock()
        let callbacks = pending
        pending.removeAll()
        lock.unlock()
        callbacks.values.forEach { $0(.failure(error)) }
    }

    private func awaitRelay(_ payload: [String: Any]) async throws -> [String: Any] {
        let id = (payload["id"] as? String) ?? UUID().uuidString
        var withId = payload
        withId["id"] = id
        return try await withCheckedThrowingContinuation { cont in
            lock.lock()
            pending[id] = { result in
                switch result {
                case .success(let dict): cont.resume(returning: dict)
                case .failure(let e):    cont.resume(throwing: e)
                }
            }
            lock.unlock()
            sendRelay(withId)
        }
    }

    // MARK: - Stdin / JSON-RPC loop

    func runLoop() {
        // POSIX read(2), NOT FileHandle.read(upToCount:). FileHandle's
        // variant loops until it fills the REQUESTED length or hits EOF —
        // and claude holds stdin open for the session's lifetime, so a
        // ~300-byte initialize left us blocked waiting for 64KB that
        // never arrived: no reply, ever, and the CLI showed the server
        // "still connecting" forever. read(2) returns as soon as any
        // bytes are available. (Every hand-probe passed because closing
        // stdin forced EOF and flushed the loop — masking this.)
        var inbuf = Data()
        var buf = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = read(0, &buf, buf.count)
            if n <= 0 { break }
            inbuf.append(buf, count: n)
            while let nl = inbuf.firstIndex(of: 0x0A) {
                let line = inbuf.prefix(upTo: nl)
                inbuf.removeSubrange(inbuf.startIndex...nl)
                if line.isEmpty { continue }
                handleRPCLine(Data(line))
            }
        }
        // Keep the runloop alive long enough to drain async work.
        // claude closing stdin → loop exits → relay stays open just
        // long enough for any in-flight reply to land.
        RunLoop.main.run(until: Date().addingTimeInterval(2))
    }

    private func handleRPCLine(_ line: Data) {
        guard let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { return }
        let method = obj["method"] as? String ?? ""
        let id = obj["id"]  // may be Int, String, or absent (notification)
        let params = obj["params"] as? [String: Any] ?? [:]

        switch method {
        case "initialize":
            // Echo the CLIENT's protocol version. Answering with a fixed
            // old date (2024-11-05) made claude ≥ ~2.1.209 (which asks
            // for 2025-11-25) treat the server as incompatible and stall
            // in "still connecting" forever — it never even sent
            // initialized. Our surface is tools-only and stable across
            // protocol revisions, so mirroring the request is safe.
            let requested = (params["protocolVersion"] as? String) ?? "2025-06-18"
            respond(id: id, result: [
                "protocolVersion": requested,
                "serverInfo": [
                    "name": "manyagents-mcp",
                    "title": "ManyAgents",
                    "version": "0.4.0"
                ],
                "capabilities": ["tools": [String: Any]()],
                // Injected into the agent's context by the client — the
                // canonical place to explain the app.
                "instructions": """
                You are running inside ManyAgents, a native macOS app the user drives multiple Claude Code sessions from — each session is a tab, tabs group by project. These tools are loaded directly into your toolset (ToolSearch cannot see them; call them by name). open_preview shows the user a URL in the app's shared browser panel — use it whenever you start or update a dev server. If this session is the project's orchestrator, the board tools (list_agents, read_agent, send_to_agent, new_agent, set_notes, mute_agent) let you coordinate the user's other tabs. Refer to the app as "ManyAgents".
                """
            ])
        case "initialized", "notifications/initialized":
            // Notification; no response. The spec method is
            // "notifications/initialized" — only matching the bare name
            // sent this into default:, which answered with an id-less
            // error frame. Notifications must NEVER be answered; claude
            // ≥ ~2.1.19x treats a server that does as broken and leaves
            // it "still connecting" forever (2.1.168 tolerated it).
            break
        case "tools/list":
            respond(id: id, result: ["tools": toolDescriptors])
        case "tools/call":
            Task { await handleToolCall(id: id, params: params) }
        case "ping":
            respond(id: id, result: [String: Any]())
        default:
            // Method-not-found only for actual REQUESTS. Any notification
            // (no id) — known or future — gets silence, per JSON-RPC.
            if id != nil {
                respond(id: id, error: ["code": -32601, "message": "Method not found: \(method)"])
            }
        }
    }

    private var toolDescriptors: [[String: Any]] {
        [
            [
                "name": "permission_prompt",
                "description": "Surface a sensitive-path or permission-required action to the user for Allow / Deny. Claude Code calls this automatically via --permission-prompt-tool; you generally do not call it directly. Returns the user's decision as JSON.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "tool_name": ["type": "string"],
                        "input": [
                            "type": "object",
                            "additionalProperties": true
                        ]
                    ],
                    "required": ["tool_name", "input"]
                ]
            ],
            [
                "name": "list_agents",
                "description": "Your board: list the user's other open tabs — id, project, title, status, whether muted, and a one-line snapshot of what each last said. Tabs the user hid are excluded. Call this to see the current situation across tabs.",
                "inputSchema": [
                    "type": "object",
                    "properties": [String: Any](),
                    "additionalProperties": false
                ]
            ],
            [
                "name": "read_agent",
                "description": "Look closer at one tab: returns the tail of its transcript so you can see what it's actually doing/produced, WITHOUT sending it anything. Use this to check on a tab (e.g. 'is the report ready?') before deciding to act.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "agent_id": ["type": "string", "description": "The UUID from list_agents."]
                    ],
                    "required": ["agent_id"],
                    "additionalProperties": false
                ]
            ],
            [
                "name": "send_to_agent",
                "description": "Take action ON a tab: send it a prompt as a normal user turn (e.g. hand a finished report from one tab to another, or ask a tab to do something). By default waits for its reply. The tab is tagged so it knows the message came from you, the orchestrator.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "agent_id": [
                            "type": "string",
                            "description": "The UUID from list_agents. Not a project name."
                        ],
                        "prompt": [
                            "type": "string",
                            "description": "What to send the tab."
                        ],
                        "wait_for_result": [
                            "type": "boolean",
                            "description": "If true (default), blocks until the tab's turn completes and returns its reply. If false, returns immediately.",
                            "default": true
                        ]
                    ],
                    "required": ["agent_id", "prompt"],
                    "additionalProperties": false
                ]
            ],
            [
                "name": "new_agent",
                "description": "Spin up a new tab (session) to do work in — for when a task needs its own working context and no suitable tab exists. If an EMPTY tab already exists in that project (no history), it's reused instead of opening another. Give the project's cwd (from list_agents) and an optional first prompt. Returns the tab's id so you can read_agent / send_to_agent it like any other. Doesn't steal the user's focus.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "cwd": ["type": "string", "description": "Absolute project path (the cwd from list_agents) the new tab runs in."],
                        "prompt": ["type": "string", "description": "Optional first task to hand the new tab immediately."]
                    ],
                    "required": ["cwd"],
                    "additionalProperties": false
                ]
            ],
            [
                "name": "set_notes",
                "description": "Record your running understanding — what each tab is for, what you're waiting on, your next intended action. This is your memory across wake-ups and is shown to the user in the orchestrator indicator. Overwrites the previous note; keep it short and current.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "notes": ["type": "string", "description": "Your current plan / situational read, a few lines."]
                    ],
                    "required": ["notes"],
                    "additionalProperties": false
                ]
            ],
            [
                "name": "mute_agent",
                "description": "Stop being woken by a tab you've judged irrelevant. It stays on your board for reference, but its turn-completions won't ping you. Use this to self-prune noise. Reversible with unmute_agent.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "agent_id": ["type": "string", "description": "The UUID from list_agents."]
                    ],
                    "required": ["agent_id"],
                    "additionalProperties": false
                ]
            ],
            [
                "name": "unmute_agent",
                "description": "Resume being woken by a tab you previously muted.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "agent_id": ["type": "string", "description": "The UUID from list_agents."]
                    ],
                    "required": ["agent_id"],
                    "additionalProperties": false
                ]
            ],
            [
                "name": "open_preview",
                "description": "Open a URL in ManyAgents' shared browser preview panel. Use this to show the user what you just built (e.g. a localhost dev server page). All preview panels share cookies/sessions so the user only needs to log in once.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "url": ["type": "string", "description": "The URL to open, e.g. http://localhost:3000/dashboard"]
                    ],
                    "required": ["url"],
                    "additionalProperties": false
                ]
            ]
        ]
    }

    private func handleToolCall(id: Any?, params: [String: Any]) async {
        let name = params["name"] as? String ?? ""
        let arguments = params["arguments"] as? [String: Any] ?? [:]

        do {
            switch name {
            case "permission_prompt":
                let toolName = arguments["tool_name"] as? String ?? "Unknown"
                let toolInput = arguments["input"] as? [String: Any] ?? [:]
                let res = try await awaitRelay([
                    "op": "permission_prompt",
                    "source_session_id": args.sourceSessionId as Any,
                    "tool_name": toolName,
                    "tool_input": toolInput
                ])
                if (res["ok"] as? Bool) == true {
                    let decision = res["decision"] as? String ?? "deny"
                    // Claude's permission-prompt-tool contract: return
                    // a JSON-text content with `{behavior, ...}`. allow
                    // → echo the input back as updatedInput; deny →
                    // include a user-visible message.
                    let payload: [String: Any]
                    if decision == "allow" {
                        payload = [
                            "behavior": "allow",
                            "updatedInput": toolInput
                        ]
                    } else {
                        let msg = (res["message"] as? String) ?? "Denied by user."
                        payload = [
                            "behavior": "deny",
                            "message": msg
                        ]
                    }
                    let data = (try? JSONSerialization.data(withJSONObject: payload, options: []))
                        ?? Data("{\"behavior\":\"deny\",\"message\":\"encode failed\"}".utf8)
                    let text = String(data: data, encoding: .utf8) ?? ""
                    respondToolResult(id: id, text: text)
                } else {
                    respondToolResult(id: id,
                                      text: "{\"behavior\":\"deny\",\"message\":\"\((res["error"] as? String) ?? "relay error")\"}",
                                      isError: true)
                }
            case "list_agents":
                let res = try await awaitRelay(["op": "list_agents",
                                                "source_session_id": args.sourceSessionId as Any])
                let agents = (res["agents"] as? [[String: Any]]) ?? []
                let summary = renderAgentsList(agents)
                respondToolResult(id: id, text: summary)
            case "read_agent":
                guard let agentId = arguments["agent_id"] as? String else {
                    respondToolResult(id: id, text: "Error: missing agent_id.", isError: true)
                    return
                }
                let res = try await awaitRelay(["op": "read_agent",
                                                "source_session_id": args.sourceSessionId as Any,
                                                "agent_id": agentId])
                if (res["ok"] as? Bool) == true {
                    let title = res["title"] as? String ?? agentId
                    let status = res["status"] as? String ?? "unknown"
                    let tail = res["transcript_tail"] as? String ?? "(no transcript)"
                    respondToolResult(id: id, text: "[\(title) · status: \(status)]\n\n\(tail)")
                } else {
                    respondToolResult(id: id, text: "Error: \(res["error"] as? String ?? "read failed")", isError: true)
                }
            case "new_agent":
                guard let cwd = arguments["cwd"] as? String else {
                    respondToolResult(id: id, text: "Error: missing cwd.", isError: true)
                    return
                }
                var payload: [String: Any] = ["op": "new_agent",
                                              "source_session_id": args.sourceSessionId as Any,
                                              "cwd": cwd]
                if let p = arguments["prompt"] as? String { payload["prompt"] = p }
                let res = try await awaitRelay(payload)
                if (res["ok"] as? Bool) == true {
                    let aid = res["agent_id"] as? String ?? "?"
                    let reused = (res["reused"] as? Bool) == true
                    respondToolResult(id: id, text: "\(reused ? "Reused empty tab" : "Created tab") \(aid) in \(cwd).")
                } else {
                    respondToolResult(id: id, text: "Error: \(res["error"] as? String ?? "new_agent failed")", isError: true)
                }
            case "send_to_agent":
                guard let agentId = arguments["agent_id"] as? String,
                      let prompt = arguments["prompt"] as? String
                else {
                    respondToolResult(id: id, text: "Error: missing agent_id or prompt.", isError: true)
                    return
                }
                let wait = (arguments["wait_for_result"] as? Bool) ?? true
                let res = try await awaitRelay([
                    "op": "dispatch",
                    "source_session_id": args.sourceSessionId as Any,
                    "agent_id": agentId,
                    "prompt": prompt,
                    "wait_for_result": wait
                ])
                if (res["ok"] as? Bool) == true {
                    let reply = res["reply"] as? String ?? "(sent)"
                    let status = res["status"] as? String ?? "unknown"
                    let body = wait
                        ? "[Reply from tab \(agentId) · status: \(status)]\n\n\(reply)"
                        : "[Sent to tab \(agentId) · status: \(status)] (not waiting)"
                    respondToolResult(id: id, text: body)
                } else {
                    respondToolResult(id: id,
                                      text: "Error: \(res["error"] as? String ?? "send failed")",
                                      isError: true)
                }
            case "set_notes":
                let notes = arguments["notes"] as? String ?? ""
                let res = try await awaitRelay(["op": "set_notes",
                                                "source_session_id": args.sourceSessionId as Any,
                                                "notes": notes])
                respondToolResult(id: id,
                                  text: (res["ok"] as? Bool) == true ? "Notes updated." : "Error: \(res["error"] as? String ?? "failed")",
                                  isError: (res["ok"] as? Bool) != true)
            case "mute_agent", "unmute_agent":
                guard let agentId = arguments["agent_id"] as? String else {
                    respondToolResult(id: id, text: "Error: missing agent_id.", isError: true)
                    return
                }
                let res = try await awaitRelay(["op": name,
                                                "source_session_id": args.sourceSessionId as Any,
                                                "agent_id": agentId])
                respondToolResult(id: id,
                                  text: (res["ok"] as? Bool) == true ? "\(name == "mute_agent" ? "Muted" : "Unmuted") tab \(agentId)." : "Error: \(res["error"] as? String ?? "failed")",
                                  isError: (res["ok"] as? Bool) != true)
            case "open_preview":
                guard let url = arguments["url"] as? String else {
                    respondToolResult(id: id, text: "Error: missing url.", isError: true)
                    return
                }
                // source_session_id keys the URL to the CALLING agent's
                // worktree; without it the relay falls back to whatever
                // tab the user happens to be looking at.
                let res = try await awaitRelay(["op": "open_preview",
                                                "source_session_id": args.sourceSessionId as Any,
                                                "url": url])
                respondToolResult(id: id,
                                  text: (res["ok"] as? Bool) == true ? "Preview opened: \(url)" : "Error: \(res["error"] as? String ?? "failed")",
                                  isError: (res["ok"] as? Bool) != true)
            default:
                respondToolResult(id: id, text: "Unknown tool: \(name)", isError: true)
            }
        } catch {
            respondToolResult(id: id, text: "Relay error: \(error.localizedDescription)", isError: true)
        }
    }

    private func renderAgentsList(_ agents: [[String: Any]]) -> String {
        if agents.isEmpty { return "No other open tabs." }
        let lines: [String] = agents.map { a in
            let id = a["id"] as? String ?? "?"
            let title = a["title"] as? String ?? "?"
            let status = a["status"] as? String ?? "?"
            let muted = (a["muted"] as? Bool) == true ? " (muted)" : ""
            let latest = a["latest"] as? String ?? ""
            let snippet = latest.isEmpty ? "" : "  last: \(latest)"
            return "- id=\(id)  title=\"\(title)\"  status=\(status)\(muted)\(snippet)"
        }
        return "Your board (other open tabs):\n" + lines.joined(separator: "\n")
    }

    // MARK: - stdout JSON-RPC framing

    private func respond(id: Any?, result: [String: Any]) {
        var msg: [String: Any] = ["jsonrpc": "2.0", "result": result]
        if let id { msg["id"] = id }
        writeRPC(msg)
    }

    private func respond(id: Any?, error: [String: Any]) {
        var msg: [String: Any] = ["jsonrpc": "2.0", "error": error]
        if let id { msg["id"] = id }
        writeRPC(msg)
    }

    private func respondToolResult(id: Any?, text: String, isError: Bool = false) {
        respond(id: id, result: [
            "content": [
                ["type": "text", "text": text]
            ],
            "isError": isError
        ])
    }

    private func writeRPC(_ msg: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: msg, options: []) else { return }
        var out = data
        out.append(0x0A)
        // `FileHandle.write(_:)` raises NSException on broken pipe
        // (claude exiting / closing stdin while we still have buffered
        // output to flush). Swift can't catch ObjC exceptions, so the
        // whole binary aborts — and since the same binary backs the
        // SwiftUI app, our parent process's UI gets killed too on
        // any coordinator-session race. Use the throwing variant
        // (`write(contentsOf:)`) so a closed pipe degrades to an
        // honest error we can swallow + exit the loop cleanly.
        stdoutQueue.sync {
            do {
                try FileHandle.standardOutput.write(contentsOf: out)
            } catch {
                // Pipe is dead; nothing more to do — let runLoop's
                // stdin-EOF path bring the subprocess down.
            }
        }
    }
}
