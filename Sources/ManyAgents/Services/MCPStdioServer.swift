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
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
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
        conn.start(queue: .main)
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
        let stdin = FileHandle.standardInput
        var inbuf = Data()
        while let chunk = try? stdin.read(upToCount: 64 * 1024), !chunk.isEmpty {
            inbuf.append(chunk)
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
            respond(id: id, result: [
                "protocolVersion": "2024-11-05",
                "serverInfo": ["name": "manyagents-mcp", "version": "0.3.0"],
                "capabilities": ["tools": [String: Any]()]
            ])
        case "initialized":
            // Notification; no response.
            break
        case "tools/list":
            respond(id: id, result: ["tools": toolDescriptors])
        case "tools/call":
            Task { await handleToolCall(id: id, params: params) }
        case "ping":
            respond(id: id, result: [String: Any]())
        default:
            respond(id: id, error: ["code": -32601, "message": "Method not found: \(method)"])
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
                "description": "List every open ManyAgents session — id, project, title, status. Use the returned id when calling dispatch_agent.",
                "inputSchema": [
                    "type": "object",
                    "properties": [String: Any](),
                    "additionalProperties": false
                ]
            ],
            [
                "name": "dispatch_agent",
                "description": "Send a prompt to another agent session and (by default) wait for its reply. The peer agent treats the prompt as a hand-off from this coordinator session and runs it as a normal user turn. Use this to delegate work to a sibling agent — e.g. asking the auth-service agent to implement an API while you stay focused on the design.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "agent_id": [
                            "type": "string",
                            "description": "The UUID returned by list_agents. Not a project name."
                        ],
                        "prompt": [
                            "type": "string",
                            "description": "The prompt to send to the other agent. Will be wrapped with a hand-off provenance tag on the receiving side."
                        ],
                        "wait_for_result": [
                            "type": "boolean",
                            "description": "If true (default), the tool call blocks until the dispatched agent's turn completes and returns its last assistant reply. If false, returns immediately with a 'dispatched' status.",
                            "default": true
                        ]
                    ],
                    "required": ["agent_id", "prompt"],
                    "additionalProperties": false
                ]
            ],
            [
                "name": "create_agent",
                "description": "Open a NEW agent session in ManyAgents. A project in the sidebar is just a unique working directory, so passing a cwd that isn't open yet creates a new project; passing a folder nested inside an existing project creates a sub-project of it. Set coordinator=true to make the new tab an orchestrator that can itself list, dispatch and create agents. Optionally send it a first prompt so it starts working immediately. Returns the new agent's id, usable with dispatch_agent.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "cwd": [
                            "type": "string",
                            "description": "Absolute path (or ~/ path, or a path relative to your own cwd) of the folder the agent works in. Must already exist. This path is what groups the agent into a project."
                        ],
                        "title": [
                            "type": "string",
                            "description": "Optional tab title, e.g. \"Compass Core\". Without it the tab is auto-named after its first exchange."
                        ],
                        "coordinator": [
                            "type": "boolean",
                            "description": "If true, the new agent gets these same orchestration tools (an orchestrator tab). Default false.",
                            "default": false
                        ],
                        "prompt": [
                            "type": "string",
                            "description": "Optional first prompt. Sent as a hand-off from you as soon as the agent is open; the call returns without waiting for its reply. Use dispatch_agent for follow-ups."
                        ]
                    ],
                    "required": ["cwd"],
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
            case "dispatch_agent":
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
                    let reply = res["reply"] as? String ?? "(dispatched)"
                    let status = res["status"] as? String ?? "unknown"
                    let body = wait
                        ? "[Reply from agent \(agentId) · status: \(status)]\n\n\(reply)"
                        : "[Dispatched to \(agentId) · status: \(status)] (not waiting)"
                    respondToolResult(id: id, text: body)
                } else {
                    respondToolResult(id: id,
                                      text: "Error: \(res["error"] as? String ?? "dispatch failed")",
                                      isError: true)
                }
            case "create_agent":
                guard let cwd = arguments["cwd"] as? String, !cwd.isEmpty else {
                    respondToolResult(id: id, text: "Error: missing cwd.", isError: true)
                    return
                }
                var payload: [String: Any] = [
                    "op": "create_agent",
                    "source_session_id": args.sourceSessionId as Any,
                    "cwd": cwd,
                    "coordinator": (arguments["coordinator"] as? Bool) ?? false
                ]
                if let title = arguments["title"] as? String { payload["title"] = title }
                if let prompt = arguments["prompt"] as? String { payload["prompt"] = prompt }
                let res = try await awaitRelay(payload)
                if (res["ok"] as? Bool) == true {
                    let newId = res["agent_id"] as? String ?? "?"
                    let project = res["project"] as? String ?? "?"
                    let title = res["title"] as? String ?? project
                    let isCoord = (res["coordinator"] as? Bool) == true
                    let sent = (res["prompt_sent"] as? Bool) == true
                    var body = "Opened agent id=\(newId) in project \(project) (\(res["cwd"] as? String ?? cwd)), title \"\(title)\""
                    if isCoord { body += ", orchestrator mode on" }
                    body += sent ? ". First prompt sent; it is working now." : "."
                    respondToolResult(id: id, text: body)
                } else {
                    respondToolResult(id: id,
                                      text: "Error: \(res["error"] as? String ?? "create failed")",
                                      isError: true)
                }
            default:
                respondToolResult(id: id, text: "Unknown tool: \(name)", isError: true)
            }
        } catch {
            respondToolResult(id: id, text: "Relay error: \(error.localizedDescription)", isError: true)
        }
    }

    private func renderAgentsList(_ agents: [[String: Any]]) -> String {
        if agents.isEmpty { return "No open agents." }
        let lines: [String] = agents.map { a in
            let id = a["id"] as? String ?? "?"
            let project = a["project"] as? String ?? "?"
            let title = a["title"] as? String ?? "?"
            let status = a["status"] as? String ?? "?"
            return "- id=\(id)  project=\(project)  title=\"\(title)\"  status=\(status)"
        }
        return "Open agents:\n" + lines.joined(separator: "\n")
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
