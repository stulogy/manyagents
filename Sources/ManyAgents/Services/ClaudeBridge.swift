import Foundation
import Combine

/// Events the bridge surfaces upward.
enum BridgeEvent {
    case initialized(sessionId: String, model: String?)
    case assistantBlocks([ContentBlock])
    case toolResult(toolUseId: String, content: String, isError: Bool, parentToolUseId: String?)
    /// An image returned by a tool (e.g. Read on a screenshot). Rendered
    /// inline as an image block instead of being flattened to text.
    case toolResultImage(toolUseId: String, data: Data, mediaType: String, parentToolUseId: String?)
    case result(usage: TokenUsage?, costUsd: Double?, isError: Bool, text: String?)
    case processExited(exitCode: Int32)
    case systemError(String)
    /// Canonical per-message output-token total. Fires from `message_delta`
    /// stream events at end-of-message — exactly correct, but only ticks
    /// at message boundaries.
    case tokenCount(outputTokens: Int)
    /// Live text/thinking chars arriving on `content_block_delta` stream
    /// events. The session converts chars→tokens with a rough /4 estimate
    /// so the gauge ticks smoothly within a single long message; the
    /// estimate is reconciled to the canonical count when `.tokenCount`
    /// fires at message-end.
    case partialOutputChars(Int)
    /// A new content block just opened — text, thinking, or a specific
    /// tool. Lets the session set a real phase ("Thinking", "Writing",
    /// "Preparing Bash") even when no completed assistant event has
    /// landed yet, so long extended-thinking sequences don't look stuck.
    case partialBlockKind(String)
    /// The wire name of the tool that block belongs to, so the UI can badge
    /// ManyAgents' own tools as the app's machinery rather than as a
    /// third-party integration. Empty string when the block isn't a tool.
    case partialToolName(String)
    /// claude called the AskUserQuestion tool. The owning session renders a
    /// native picker; the chosen answer is delivered as a new user turn
    /// (headless `--print` auto-denies the tool and ends the turn, so there's
    /// no open tool_result to fulfil — see `AgentSession.answerQuestion`).
    case askUserQuestion(toolUseId: String, prompt: AskPrompt)
    /// The CLI began consuming a user message — emitted from the
    /// `--replay-user-messages` echo, which fires at TURN START (verified
    /// empirically). This is the only signal that a CLI-initiated turn
    /// exists: a steered message that misses its window is queued by the
    /// CLI and run as a NEW turn after the current one ends, with no other
    /// stdout traffic until the model's first block (which can be a long
    /// silent stretch). Without this, the session showed idle during such
    /// turns — new sends dispatched into the CLI's queue instead of
    /// queueing app-side, and the turn-start watchdog killed the silent
    /// (but working) process mid-turn.
    case userTurnBegan
    /// A `<task-notification>` the harness injected — a background agent
    /// finished. Carries only the one-line summary; the raw report inside
    /// the block is deliberately dropped here so it can never reach the
    /// transcript as body text.
    case harnessNotice(String)

    struct AskPrompt: Equatable {
        let header: String?
        let question: String
        let options: [AskOption]
        let multiSelect: Bool
    }

    struct AskOption: Equatable, Identifiable {
        let label: String
        let description: String?
        var id: String { label }
    }

    struct TokenUsage {
        let inputTokens: Int
        let outputTokens: Int
        let cacheReadInputTokens: Int
        let cacheCreationInputTokens: Int
        /// Tokens in claude's context at the END of the last forward
        /// pass of the turn — the gauge-correct number. Differs from
        /// `inputTokens + cacheReadInputTokens + cacheCreationInputTokens`
        /// in multi-iteration turns: aggregate cache_read_input_tokens
        /// double-counts the same prefix across each iteration, so the
        /// aggregate sum can exceed the context window even when the
        /// model is only ~20% full. We pull this from the LAST entry
        /// of `usage.iterations` when present; falls back to aggregate
        /// for single-iteration turns where they match.
        let lastIterationContextTokens: Int?
        /// Model-specific window claude itself reports in modelUsage
        /// (e.g. "claude-opus-4-7[1m]: contextWindow=1000000"). When
        /// present this is canonical; the model-id-string heuristic
        /// in AgentSession.contextWindow is only the fallback.
        let canonicalContextWindow: Int?

        /// What we display on the gauge. Last-iteration value when
        /// available; aggregate as a safe fallback.
        var totalContextTokens: Int {
            lastIterationContextTokens
                ?? (inputTokens + cacheReadInputTokens + cacheCreationInputTokens)
        }
    }
}

/// Drives `claude` in headless stream-json mode, one process per user
/// prompt. This matches Claude Code's intended SDK pattern: each turn is a
/// fresh `claude -p ... --resume <session_id>` invocation that streams its
/// events then exits. Cleaner than holding a long-running pty: less memory,
/// no zombie processes, and `--resume` actually picks up the prior
/// conversation because we hand claude a prompt to run against immediately.
///
/// State that needs to survive between turns (the claude session_id) lives
/// on the owning `AgentSession`, not here.
final class ClaudeBridge {
    enum Keys {
        static let model = "manyagents.model"
    }

    /// Models the user can select in Settings. Empty string means "use claude's default".
    /// Verified against the CLI's `--model` flag — every id here answers a
    /// real prompt. Ids are canonical and complete: never append a date
    /// suffix (`claude-haiku-4-5`, not `claude-haiku-4-5-20251001`).
    /// Mythos 5 is deliberately absent — same model as Fable 5, but only
    /// available to approved organizations, so it would fail for most users.
    static let availableModels: [(label: String, id: String)] = [
        ("Default", ""),
        ("Fable 5", "claude-fable-5"),
        ("Opus 5", "claude-opus-5"),
        ("Opus 4.8", "claude-opus-4-8"),
        ("Sonnet 5", "claude-sonnet-5"),
        ("Sonnet 4.6", "claude-sonnet-4-6"),
        ("Haiku 4.5", "claude-haiku-4-5"),
    ]

    let cwd: String
    /// Updated by the owner after the first `initialized` event so subsequent
    /// `sendUserText` calls can resume the same conversation.
    var currentSessionId: String?

    private let subject = PassthroughSubject<BridgeEvent, Never>()
    private var activeProcess: Process?
    /// Model the active process was launched with. Empty string = claude's default.
    private var activeProcessModel: String = ""
    /// MCP config path the active process was launched with. nil = no MCP.
    private var activeProcessMCPPath: String? = nil
    /// Whether the active process was launched with the orchestrator prompt.
    private var activeProcessCoordinator = false
    /// Whether the active process was launched with the repo-lead prompt.
    private var activeProcessRepoLead = false
    /// Held open for the duration of a turn: the initial user payload is
    /// written here, and it's closed in handleResult so claude exits cleanly.
    private var activeStdin: FileHandle?
    private var stdoutBuffer = Data()
    /// Processes deliberately replaced mid-flight (model / MCP / role change).
    /// Their termination handlers still fire; see the handler for why that
    /// mattered.
    private var supersededProcesses = Set<ObjectIdentifier>()
    /// tool_use ids of AskUserQuestion calls seen this turn. In headless
    /// `--print` mode the CLI auto-denies AskUserQuestion and emits an
    /// is_error "Answer questions?" tool_result for it — pure noise, since the
    /// native picker/chip already represents the question. We track the ids so
    /// `handleUserMessage` can drop that result instead of rendering an error.
    private var askUserQuestionIds: Set<String> = []
    /// Set per-turn by the owning AgentSession. Always written when an
    /// MCP relay is up so claude has both the permission-prompt tool
    /// (always exposed) and the coordinator dispatch tools (when the
    /// session is in coordinator mode). Passed to `claude --mcp-config <path>`.
    var mcpConfigPath: String?
    /// Set per-turn by the owning AgentSession: whether this session wears
    /// the orchestrator hat. Gates the coordinator system prompt — a worker
    /// tab must never be told it's the orchestrator. A change respawns the
    /// process so the prompt matches the role.
    var isCoordinator: Bool = false
    /// Set per-turn alongside `isCoordinator`: this session runs a NESTED
    /// repo's board under a workspace orchestrator. It still gets the full
    /// coordinator prompt; this only adds the half it can't infer — that
    /// there's somebody above it, and how to reach them.
    var isRepoLead: Bool = false
    /// Set per-turn by the owning AgentSession: the model THIS session
    /// should run, already resolved (Optimize Mode's subagent downgrade
    /// applied or not — the bridge just runs whatever it's told). Empty
    /// means claude's own default. A change respawns the process, same as
    /// the general/coordinator settings above.
    var modelOverride: String = ""

    var events: AnyPublisher<BridgeEvent, Never> { subject.eraseToAnyPublisher() }
    /// True while a turn is in flight (a user message was sent and its
    /// `.result` hasn't landed). With the persistent process, "busy" is about
    /// the turn, not whether the process exists (it's almost always running).
    var isBusy: Bool { turnInFlight }
    private var turnInFlight = false

    init(cwd: String, resumeSessionId: String? = nil) {
        self.cwd = cwd
        self.currentSessionId = resumeSessionId
    }

    /// Back-compat shim — most callers send plain text.
    func sendUserText(_ text: String) { send(text: text, imagesPng: []) }

    /// Ensure the session's persistent claude process is running. Spawned once
    /// (lazily, on first send) and kept alive across turns — each user message
    /// is fed over the held-open stdin instead of paying claude's cold start
    /// every turn. `--resume <currentSessionId>` is applied only on (re)spawn
    /// to restore the conversation; the warm process holds it in memory after.
    private func ensureProcess() {
        let preferredModel = modelOverride
        if let p = activeProcess, p.isRunning {
            let modelChanged = preferredModel != activeProcessModel
            let mcpChanged   = mcpConfigPath != activeProcessMCPPath
            let roleChanged  = isCoordinator != activeProcessCoordinator
                            || isRepoLead != activeProcessRepoLead
            guard modelChanged || mcpChanged || roleChanged else { return }
            // Model, MCP config, or orchestrator role changed — kill so the
            // next send respawns with the right flags. --resume preserves
            // conversation history. Flagged first: its termination handler
            // fires later, once the replacement is live, and must not be
            // mistaken for the new process dying.
            supersededProcesses.insert(ObjectIdentifier(p))
            p.terminate()
            activeProcess = nil
        }
        guard let claudePath = Self.resolveClaudePath() else {
            emit(.systemError("claude binary not found on PATH"))
            return
        }

        var args = [
            "--print",
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            "--verbose",
            // Stream content-block deltas (text/thinking chunks) and
            // message_delta events. Lets us tick the output-token gauge
            // smoothly during long single-message generations instead of
            // jumping only at message boundaries.
            "--include-partial-messages",
            // Echo each user message back on stdout when the CLI consumes
            // it — i.e. at turn start. This is how we detect CLI-initiated
            // turns (a queued steered message run as its own turn) so the
            // session shows running instead of idle. See .userTurnBegan.
            "--replay-user-messages",
            // Always bypass the sensitive-file permission gate — this is a
            // local dev tool driving the user's own sessions; the prompts just
            // got in the way. (Previously a per-tab / global toggle.)
            "--permission-mode", "bypassPermissions",
            // Remove AskUserQuestion entirely. In headless stream-json mode the
            // CLI auto-resolves it (the picker is cosmetic and the agent moves
            // on without the answer — known CLI gap). With the tool gone the
            // model has no choice but to ask in prose and end the turn, which
            // the system prompt already steers it to do. Prompt alone wasn't
            // reliably obeyed; this makes it impossible to call.
            "--disallowedTools", "AskUserQuestion",
            // WebSearch / WebFetch are read-only research tools the user always
            // wants to flow — never block them on a permission prompt. An
            // --allowedTools rule bypasses the prompt even under acceptEdits.
            "--allowedTools", "WebSearch,WebFetch"
        ]
        if !preferredModel.isEmpty {
            args.append(contentsOf: ["--model", preferredModel])
        }
        if let rid = currentSessionId, !rid.isEmpty {
            args.append(contentsOf: ["--resume", rid])
        }
        if let cfg = mcpConfigPath {
            // Hand claude the manyagents-generated mcp.json — every session
            // gets it (open_preview / notify_orchestrator); the orchestrator
            // session's config additionally exposes the board tools.
            args.append(contentsOf: ["--mcp-config", cfg])
            // NB: deliberately NO --permission-prompt-tool. We always run
            // --permission-mode bypassPermissions, so there are no permission
            // prompts to route. Passing the prompt-tool alongside bypass is
            // contradictory and made claude try to call a permission tool it
            // couldn't see ("mcp__manyagents__permission_prompt not found"),
            // which broke the orchestrator's tool loading.
        }
        // ONE --append-system-prompt, never several. The CLI keeps only the
        // LAST occurrence and silently discards the rest (verified on 2.1.234:
        // two flags, only the second one's instruction is obeyed). We were
        // passing four, so for every session with MCP wired — i.e. all of
        // them — only the role prompt survived and the brevity rule, the
        // waiting cue, and the tool note were dead the whole time. That is
        // why "never write comprehensive reports" kept producing them.
        var appended = [Self.waitingCueSystemPrompt,
                        Self.brevitySystemPrompt,
                        Self.shellCwdSystemPrompt,
                        Self.fileToolsSystemPrompt]
        if mcpConfigPath != nil {
            appended.append(Self.manyAgentsToolsSystemPrompt)
            // Nudge the orchestrator to use the user's open tabs (left to
            // itself it reaches for internal Task sub-agents and the board
            // never moves); tell every other tab plainly that it is NOT the
            // orchestrator, or workers claim the hat and poke the board.
            appended.append(isCoordinator ? Self.coordinatorSystemPrompt
                                          : Self.workerSystemPrompt)
            if isCoordinator && isRepoLead {
                appended.append(Self.repoLeadSystemPrompt)
            }
        }
        args.append(contentsOf: ["--append-system-prompt",
                                 appended.joined(separator: "\n\n")])

        activeProcessModel = preferredModel
        activeProcessMCPPath = mcpConfigPath
        activeProcessCoordinator = isCoordinator
        activeProcessRepoLead = isRepoLead
        let process = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: claudePath)
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "dumb"
        env["NO_COLOR"] = "1"
        env["MANYAGENTS"] = "1"
        // A GUI app launched from Finder/Xcode inherits launchd's minimal PATH
        // (/usr/bin:/bin:…), so the agent's Bash tool can't find node (nvm /
        // homebrew) and shebang scripts like `./dev/query_db.sh` fail, forcing
        // absolute paths. Hand the child the user's real login-shell PATH so
        // dev tooling and relative scripts resolve exactly as in their terminal.
        env["PATH"] = Self.userPath
        process.environment = env

        stdoutBuffer.removeAll()
        activeProcess = process

        process.terminationHandler = { [weak self] proc in
            let code = proc.terminationStatus
            DispatchQueue.main.async {
                guard let self else { return }
                // A process WE replaced on purpose still fires this handler,
                // asynchronously, after the replacement is already running and
                // mid-turn. Reporting that exit surfaced a red "claude exited
                // (143) without responding" — 143 being the SIGTERM we sent —
                // against the healthy turn that had just started, and nilling
                // activeStdin out from under it would have broken the next
                // send outright. The exit is ours; it isn't news.
                if self.supersededProcesses.remove(ObjectIdentifier(proc)) != nil { return }
                // The persistent process is gone (cancel / teardown / crash).
                // Clear state so isBusy frees up and the next send() respawns.
                self.activeProcess = nil
                self.activeStdin = nil
                self.turnInFlight = false
                self.subject.send(.processExited(exitCode: code))
            }
        }

        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.appendStdout(data)
        }

        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty,
                  let s = String(data: data, encoding: .utf8),
                  !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return }
            DispatchQueue.main.async {
                self?.subject.send(.systemError(s))
            }
        }

        do {
            try process.run()
            // Held open for the session lifetime; we write every turn's user
            // message here. Closed only on teardown/cancel (`cancel()`), never
            // per turn — that's what keeps the process warm.
            activeStdin = stdin.fileHandleForWriting
        } catch {
            activeProcess = nil
            emit(.systemError("Failed to spawn claude: \(error.localizedDescription)"))
        }
    }

    /// Send a user message. Spawns the persistent process on first use, then
    /// writes the message to its stdin — no respawn, no cold start on turns 2+.
    /// The turn ends when claude emits `.result` (handleResult flips
    /// `turnInFlight` off); stdin stays open for the next message.
    func send(text: String, imagesPng: [Data]) {
        // The caller only sends when the app considers the session idle, so a
        // set flag here means a prior turn ended without clearing it (missed
        // .result, kill -9, relaunch race). Treat it as stale and proceed —
        // silently rejecting would drop the prompt and it would never reach
        // claude. If the underlying process is genuinely wedged, the turn-start
        // watchdog respawns it.
        if turnInFlight { turnInFlight = false }
        ensureProcess()
        guard activeStdin != nil else { return }   // ensureProcess emitted the error
        askUserQuestionIds.removeAll()              // per-turn, not per-process
        turnInFlight = true
        var content: [[String: Any]] = []
        let saved = Self.persistAttachments(imagesPng)
        let body = Self.textWithAttachmentPaths(text, saved)
        if !body.isEmpty {
            content.append(["type": "text", "text": body])
        }
        for png in imagesPng {
            content.append([
                "type": "image",
                "source": [
                    "type": "base64",
                    "media_type": "image/png",
                    "data": png.base64EncodedString()
                ]
            ])
        }
        writeUserPayload([
            "type": "user",
            "message": ["role": "user", "content": content]
        ])
    }

    /// Where a pasted screenshot is kept on disk.
    ///
    /// An image only exists inside the conversation, and a long conversation
    /// loses the early ones — the model stops being able to see a screenshot
    /// it was looking at an hour ago, which is why compacting "fixes" it.
    /// Writing them out costs nothing and turns an image into something that
    /// can be re-read on demand for the rest of the session.
    private static var attachmentsDir: URL? {
        guard let base = try? FileManager.default.url(for: .applicationSupportDirectory,
                                                      in: .userDomainMask,
                                                      appropriateFor: nil, create: true)
        else { return nil }
        let dir = base.appendingPathComponent("ManyAgents/attachments", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Writes each attachment out and returns the paths, in order. Failures
    /// are silent: the inline image still goes through, this is only the
    /// fallback for when it later ages out.
    private static func persistAttachments(_ images: [Data]) -> [String] {
        guard !images.isEmpty, let dir = attachmentsDir else { return [] }
        pruneAttachments(in: dir)
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        var paths: [String] = []
        for (i, png) in images.enumerated() {
            let url = dir.appendingPathComponent("\(stamp)-\(i + 1)-\(UUID().uuidString.prefix(6)).png")
            guard (try? png.write(to: url)) != nil else { continue }
            paths.append(url.path)
        }
        return paths
    }

    /// Two weeks is long past the life of any conversation these belong to,
    /// and screenshots are large enough that keeping them forever would be a
    /// slow leak in Application Support.
    private static func pruneAttachments(in dir: URL) {
        let cutoff = Date().addingTimeInterval(-14 * 24 * 3600)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey])
        else { return }
        for f in files {
            let modified = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? Date()
            if modified < cutoff { try? FileManager.default.removeItem(at: f) }
        }
    }

    /// Names the files alongside the inline images, so the model can get an
    /// image back with Read once the original has aged out of the window.
    /// Added to what CLAUDE receives only — the visible transcript keeps the
    /// user's own words.
    private static func textWithAttachmentPaths(_ text: String, _ paths: [String]) -> String {
        guard !paths.isEmpty else { return text }
        let list = paths.enumerated()
            .map { "  Image \($0.offset + 1): \($0.element)" }
            .joined(separator: "\n")
        return """
        \(text)

        [The attached image\(paths.count == 1 ? " is" : "s are") also saved on disk:
        \(list)
        If you can no longer see \(paths.count == 1 ? "it" : "them") later in this conversation, \
        Read the path to bring \(paths.count == 1 ? "it" : "them") back rather than asking the user to re-send.]
        """
    }

    /// Inject a user message into the RUNNING turn without cancelling it —
    /// Claude Code-style steering. The CLI buffers the message and the model
    /// sees it at its next boundary, deciding itself how much attention to
    /// give it. Returns false when there is no live in-flight turn to steer
    /// (caller should fall back to a normal send/dispatch).
    func steer(text: String, imagesPng: [Data]) -> Bool {
        guard turnInFlight, activeStdin != nil,
              let p = activeProcess, p.isRunning else { return false }
        var content: [[String: Any]] = []
        // Same durability as a normal send — an image steered into a running
        // turn ages out of the window exactly like any other.
        let body = Self.textWithAttachmentPaths(text, Self.persistAttachments(imagesPng))
        if !body.isEmpty {
            content.append(["type": "text", "text": body])
        }
        for png in imagesPng {
            content.append([
                "type": "image",
                "source": [
                    "type": "base64",
                    "media_type": "image/png",
                    "data": png.base64EncodedString()
                ]
            ])
        }
        writeUserPayload([
            "type": "user",
            "message": ["role": "user", "content": content]
        ])
        return true
    }

    private func writeUserPayload(_ payload: [String: Any]) {
        guard let handle = activeStdin,
              let data = try? JSONSerialization.data(withJSONObject: payload),
              let line = String(data: data, encoding: .utf8)
        else { return }
        let bytes = (line + "\n").data(using: .utf8) ?? Data()
        try? handle.write(contentsOf: bytes)
    }

    /// Kill the persistent process ONLY when no turn is in flight, so the
    /// next send respawns it (with --resume) and reconnects MCP servers.
    /// Used after `claude mcp login` succeeds — a live process holds MCP
    /// connections from before the credentials existed.
    func recycleIfIdle() {
        guard !turnInFlight, let p = activeProcess, p.isRunning else { return }
        try? activeStdin?.close()
        activeStdin = nil
        p.terminate()
        activeProcess = nil
    }

    /// Cancel any in-flight turn. The corresponding `.processExited` event
    /// will fire on the termination handler.
    func cancel() {
        try? activeStdin?.close()
        activeStdin = nil
        if let p = activeProcess, p.isRunning {
            p.terminate()
        }
    }

    // MARK: - Stream parsing

    private func appendStdout(_ data: Data) {
        stdoutBuffer.append(data)
        while let nl = stdoutBuffer.firstIndex(of: 0x0A) {
            let line = stdoutBuffer.prefix(upTo: nl)
            stdoutBuffer.removeSubrange(stdoutBuffer.startIndex...nl)
            if line.isEmpty { continue }
            handleLine(Data(line))
        }
    }

    private func handleLine(_ line: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let type = obj["type"] as? String
        else { return }
        switch type {
        case "system":
            if obj["subtype"] as? String == "init",
               let sid = obj["session_id"] as? String {
                currentSessionId = sid
                let model = obj["model"] as? String
                emit(.initialized(sessionId: sid, model: model))
            }
        case "assistant":
            handleAssistant(obj)
        case "user":
            handleUserMessage(obj)
        case "result":
            handleResult(obj)
        case "stream_event":
            handleStreamEvent(obj)
        default:
            break
        }
    }

    /// Parse the wrapped Anthropic-API SSE events that `claude` re-emits
    /// when `--include-partial-messages` is on. We only care about two
    /// shapes here:
    ///   * `content_block_delta`: incoming text/thinking/json chunks for
    ///     the live token-estimate ticker. We forward char counts; the
    ///     session does the chars→tokens estimate.
    ///   * `message_delta`: end-of-message canonical `output_tokens` for
    ///     that one message. The session sums these across the turn.
    private func handleStreamEvent(_ obj: [String: Any]) {
        guard let event = obj["event"] as? [String: Any],
              let eventType = event["type"] as? String
        else { return }
        switch eventType {
        case "content_block_start":
            // Earliest possible "what's claude doing right now" signal —
            // fires the moment a new block opens, before any text streams.
            // For tool_use blocks the tool name is right here in
            // `content_block.name`; for text/thinking blocks we surface
            // those kinds directly so the indicator's verb reflects
            // reality instead of rotating whimsy words during long
            // extended-thinking stretches.
            guard let block = event["content_block"] as? [String: Any],
                  let kind = block["type"] as? String
            else { return }
            switch kind {
            case "thinking":
                emit(.partialBlockKind("thinking"))
                emit(.partialToolName(""))
            case "text":
                emit(.partialBlockKind("writing"))
                emit(.partialToolName(""))
            case "tool_use":
                let toolName = block["name"] as? String ?? "tool"
                // The wire name would read "preparing
                // mcp__manyagents__new_agent" here, which is the app's own
                // plumbing shown as if it were someone else's plugin.
                emit(.partialBlockKind(ToolNaming.phase(for: toolName)))
                emit(.partialToolName(toolName))
            default:
                break
            }
        case "content_block_delta":
            guard let delta = event["delta"] as? [String: Any] else { return }
            // Any deltable text field counts toward output token estimate:
            // visible text, hidden thinking, and the partial JSON of a
            // tool_use's input block.
            let chars: Int
            if let t = delta["text"] as? String { chars = t.count }
            else if let t = delta["thinking"] as? String { chars = t.count }
            else if let t = delta["partial_json"] as? String { chars = t.count }
            else { return }
            if chars > 0 { emit(.partialOutputChars(chars)) }
        case "message_delta":
            if let usage = event["usage"] as? [String: Any],
               let out = usage["output_tokens"] as? Int {
                emit(.tokenCount(outputTokens: out))
            }
        default:
            break
        }
    }

    private func handleAssistant(_ obj: [String: Any]) {
        guard let message = obj["message"] as? [String: Any],
              let content = message["content"] as? [[String: Any]]
        else { return }
        // NOTE: we used to emit `.tokenCount` here from
        // `message.usage.output_tokens`. With `--include-partial-messages`
        // enabled, the `assistant` event lands mid-stream and its usage
        // reflects only the warmup (e.g. ~7 tokens), not the final
        // per-message count. The canonical count now comes from
        // `stream_event/message_delta` in `handleStreamEvent`.

        // claude reports the parent tool_use id at the event root when
        // the assistant message was produced by a subagent (Task tool).
        // We propagate it onto each tool block so the renderer can nest
        // sub-tool-calls under their parent Agent card.
        let parentToolUseId = obj["parent_tool_use_id"] as? String

        var blocks: [ContentBlock] = []
        for raw in content {
            guard let blockType = raw["type"] as? String else { continue }
            switch blockType {
            case "text":
                if let t = raw["text"] as? String {
                    blocks.append(.text(id: UUID(), text: t))
                }
            case "thinking":
                if let t = raw["thinking"] as? String {
                    blocks.append(.thinking(id: UUID(), text: t))
                }
            case "tool_use":
                if let id = raw["id"] as? String,
                   let name = raw["name"] as? String {
                    let rawInput = raw["input"] as? [String: Any] ?? [:]
                    // AskUserQuestion is special — we DON'T want it rendered
                    // as a generic tool-use card. Surface it as an
                    // `.askUserQuestion` event so the session can render a
                    // native picker. Still emit it as a regular tool_use
                    // block so the transcript records the call, but the
                    // MessageView will skip drawing AskUserQuestion cards.
                    if name == "AskUserQuestion" {
                        askUserQuestionIds.insert(id)
                        if let parsed = Self.parseAskUserQuestion(input: rawInput) {
                            emit(.askUserQuestion(toolUseId: id, prompt: parsed))
                        }
                    }
                    let input = rawInput.mapValues(AnyCodable.from)
                    blocks.append(.toolUse(id: UUID(),
                                           toolUseId: id,
                                           name: name,
                                           input: input,
                                           parentToolUseId: parentToolUseId))
                }
            default:
                break
            }
        }
        if !blocks.isEmpty {
            emit(.assistantBlocks(blocks))
        }
    }

    private func handleUserMessage(_ obj: [String: Any]) {
        guard let message = obj["message"] as? [String: Any],
              let content = message["content"] as? [[String: Any]]
        else { return }
        // A text-only user frame is the --replay-user-messages echo: the
        // CLI just consumed a user message and began its turn. Never
        // rendered (the transcript bubble was appended at dispatch/steer
        // time) — it's purely the turn-began signal, and it marks the
        // bridge busy so steer() can reach CLI-initiated turns too.
        let hasToolResult = content.contains { ($0["type"] as? String) == "tool_result" }
        if !hasToolResult {
            // Background-agent completions ride in on this same frame. Show
            // the user a muted one-liner that one finished; never the
            // `<result>` body, which is the subagent's raw report.
            for block in content where (block["type"] as? String) == "text" {
                guard let text = block["text"] as? String,
                      HarnessNotice.contains(text) else { continue }
                for notice in HarnessNotice.rewrite(text).notices {
                    emit(.harnessNotice(notice))
                }
            }
            if content.contains(where: {
                let t = $0["type"] as? String
                return t == "text" || t == "image"
            }) {
                turnInFlight = true
                emit(.userTurnBegan)
            }
            return
        }
        // Same provenance signal as on the assistant side — when set,
        // this tool_result is feedback to a subagent's tool call, not
        // the top-level conversation.
        let parentToolUseId = obj["parent_tool_use_id"] as? String
        for raw in content where raw["type"] as? String == "tool_result" {
            let toolUseId = raw["tool_use_id"] as? String ?? ""
            // Drop the CLI's auto-deny result for AskUserQuestion — the picker
            // (and the post-answer chip) already represent it; a red error row
            // is just confusing noise.
            if askUserQuestionIds.contains(toolUseId) { continue }
            let isError = raw["is_error"] as? Bool ?? false
            // Inline images (e.g. Read on a screenshot) render as image blocks.
            let images = Self.imageParts(raw["content"])
            for img in images {
                emit(.toolResultImage(toolUseId: toolUseId,
                                      data: img.data,
                                      mediaType: img.mediaType,
                                      parentToolUseId: parentToolUseId))
            }
            let text = Self.flattenToolResultContent(raw["content"])
            // Skip an empty text result when we already rendered image(s),
            // so an image-only Read doesn't also print an "(empty)" row.
            if images.isEmpty || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                emit(.toolResult(toolUseId: toolUseId,
                                 content: text,
                                 isError: isError,
                                 parentToolUseId: parentToolUseId))
            }
        }
    }

    /// Extract any base64 image parts from a tool_result `content` array
    /// (Anthropic image-block shape). Used so screenshots an agent Reads
    /// render inline instead of being dropped. Shared with TranscriptLoader.
    static func imageParts(_ value: Any?) -> [(data: Data, mediaType: String)] {
        guard let arr = value as? [[String: Any]] else { return [] }
        var out: [(Data, String)] = []
        for item in arr where (item["type"] as? String) == "image" {
            guard let src = item["source"] as? [String: Any],
                  (src["type"] as? String) == "base64",
                  let b64 = src["data"] as? String,
                  let data = Data(base64Encoded: b64)
            else { continue }
            out.append((data, src["media_type"] as? String ?? "image/png"))
        }
        return out
    }

    private static func flattenToolResultContent(_ value: Any?) -> String {
        let raw: String
        if let s = value as? String {
            raw = s
        } else if let arr = value as? [[String: Any]] {
            raw = arr.compactMap { item in
                if item["type"] as? String == "text" { return item["text"] as? String }
                return nil
            }.joined(separator: "\n")
        } else {
            raw = ""
        }
        return Self.cleanToolWrapperTags(raw)
    }

    /// Strip claude code's internal wrapper tags from tool_result content
    /// before it reaches the UI. The `is_error: true` flag already conveys
    /// the error state; the literal `<tool_use_error>…</tool_use_error>`
    /// markup is just visual noise. Same for the `<system-reminder>` tags
    /// claude appends to some tool outputs.
    static func cleanToolWrapperTags(_ raw: String) -> String {
        var s = raw
        let pairs: [(open: String, close: String)] = [
            ("<tool_use_error>", "</tool_use_error>"),
            ("<system-reminder>", "</system-reminder>"),
            ("<local-command-stdout>", "</local-command-stdout>"),
            ("<local-command-stderr>", "</local-command-stderr>")
        ]
        for pair in pairs {
            s = s.replacingOccurrences(of: pair.open, with: "")
            s = s.replacingOccurrences(of: pair.close, with: "")
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func handleResult(_ obj: [String: Any]) {
        let isError = obj["is_error"] as? Bool ?? false
        let text = obj["result"] as? String
        let cost = obj["total_cost_usd"] as? Double
        let usage = (obj["usage"] as? [String: Any]).flatMap { u -> BridgeEvent.TokenUsage? in
            guard let inT = u["input_tokens"] as? Int,
                  let outT = u["output_tokens"] as? Int else { return nil }
            let cacheRead = u["cache_read_input_tokens"] as? Int ?? 0
            let cacheCreate = u["cache_creation_input_tokens"] as? Int ?? 0
            // For multi-iteration turns, the LAST iteration's totals
            // are what represent the model's actual final context size.
            // Aggregate cache_read sums across iterations and can
            // far exceed the context window (sending the gauge to
            // 100% incorrectly). Take the last iteration when present.
            var lastIterCtx: Int? = nil
            if let iters = u["iterations"] as? [[String: Any]], let last = iters.last {
                let li = (last["input_tokens"] as? Int) ?? 0
                let lcr = (last["cache_read_input_tokens"] as? Int) ?? 0
                let lcc = (last["cache_creation_input_tokens"] as? Int) ?? 0
                lastIterCtx = li + lcr + lcc
            }
            // Pull the canonical context window for the active model
            // from modelUsage. The result event carries it for every
            // model used during the turn — find the entry matching the
            // active model (or just take the first non-haiku entry,
            // which is usually the primary).
            var canonicalWindow: Int? = nil
            if let modelUsage = obj["modelUsage"] as? [String: Any] {
                // Prefer the largest contextWindow reported — there are
                // usually at most two entries (primary + a haiku helper)
                // and the larger one is the primary that drives the gauge.
                let windows: [Int] = modelUsage.compactMap { _, value in
                    (value as? [String: Any])?["contextWindow"] as? Int
                }
                canonicalWindow = windows.max()
            }
            return .init(inputTokens: inT,
                         outputTokens: outT,
                         cacheReadInputTokens: cacheRead,
                         cacheCreationInputTokens: cacheCreate,
                         lastIterationContextTokens: lastIterCtx,
                         canonicalContextWindow: canonicalWindow)
        }
        // Turn is done — but the process + stdin stay warm for the next turn
        // (that's the whole point). Just free the in-flight flag.
        turnInFlight = false
        emit(.result(usage: usage, costUsd: cost, isError: isError, text: text))
    }

    /// Parse the structured AskUserQuestion input — the tool takes an
    /// array of `questions` each with `question`, `header`, `multiSelect`,
    /// and `options` (`label` + `description`). We surface only the first
    /// question (the multi-question variant is rare in practice; can
    /// extend later).
    private static func parseAskUserQuestion(input: [String: Any]) -> BridgeEvent.AskPrompt? {
        guard let questions = input["questions"] as? [[String: Any]],
              let first = questions.first
        else { return nil }
        let question = first["question"] as? String ?? ""
        let header = first["header"] as? String
        let multi = first["multiSelect"] as? Bool ?? false
        let rawOpts = first["options"] as? [[String: Any]] ?? []
        let opts: [BridgeEvent.AskOption] = rawOpts.compactMap { o in
            guard let label = o["label"] as? String, !label.isEmpty else { return nil }
            return BridgeEvent.AskOption(
                label: label,
                description: o["description"] as? String
            )
        }
        guard !opts.isEmpty else { return nil }
        return BridgeEvent.AskPrompt(header: header,
                                     question: question,
                                     options: opts,
                                     multiSelect: multi)
    }

    private func emit(_ event: BridgeEvent) {
        DispatchQueue.main.async { [weak self] in
            self?.subject.send(event)
        }
    }

    /// One-paragraph hint we append to claude's system prompt on every
    /// invocation. Tells claude how to end its turn so ManyAgents can tell
    /// "waiting on you" apart from "done/idle." Stays scoped to the
    /// invocation — never touches the user's CLAUDE.md or global config.
    private static let waitingCueSystemPrompt = """
    Never use the AskUserQuestion tool — it does not work in this environment \
    (it gets auto-answered, so the choice never reaches you). When you need me \
    to decide, choose between options, or confirm something, ask in plain text \
    in your reply and END THE TURN to wait for my answer. Lay out the options \
    as a short list if helpful. Do not proceed past a real decision on your own.

    When you finish a turn with something pending from me — a question, a \
    decision, a choice between options, a confirmation, or any case where \
    you need my input before continuing — end your final sentence with \
    either a literal question mark or a short cue like "Your move.", \
    "Let me know which.", or "Your call." When you finish a turn with \
    nothing pending (an acknowledgement, a "done" status, a goodbye), end \
    in a plain statement without a question mark or those cue phrases. \
    Vary the cue phrasing naturally. This is read by the wrapping UI to \
    distinguish "waiting on you" from "idle."
    """

    /// Keeps responses tight by default and makes the model OFFER a deep report
    /// instead of dumping one unprompted — Stu found long auto-generated
    /// "Comprehensive Reports" flooded the chat. Pairs with the waiting cue so
    /// the offer reads as a "waiting on you" turn.
    private static let manyAgentsToolsSystemPrompt = """
    This session runs inside the ManyAgents app. Its MCP tools (mcp__manyagents__open_preview, mcp__manyagents__preview_look, mcp__manyagents__preview_do, mcp__manyagents__notify_orchestrator, and — on orchestrator sessions — list_agents / read_agent / send_to_agent / new_agent / rename_agent / compact_agent / close_agent / set_notes / mute_agent) are loaded DIRECTLY into your toolset. To compact or close a tab, call compact_agent / close_agent — do NOT send it a "/compact" text message (the CLI doesn't process slash commands; it just makes the tab write a summary). They into your toolset — they are not deferred, so ToolSearch will not find them. Do not conclude they are unavailable from a ToolSearch miss; call them directly by name.
    You can DRIVE the preview browser, not just point it at a URL: open_preview loads a page and tells you where it actually landed, preview_look reads the page back (screenshot:true when you need to see it), and preview_do clicks, fills fields and navigates. Use that browser rather than launching your own headless Playwright or Puppeteer — it's the one the user is watching, and it keeps their cookies, so pages behind a login work once they've signed in there. Sign in when it's a LOCAL DEVELOPMENT login and you have the credentials legitimately — a seeded test account the user gave you, or one from the project's own .env, fixtures or seed data, against localhost or a dev container. That's ordinary development and refusing it helps nobody: you'd only end up typing the same test password into a headless browser the user can't watch. Do NOT sign in to anything else — a real account, staging or production, a third-party service, or any credential you found lying around rather than being given for this purpose. There, say you've reached a sign-in page and ask the user to sign in once in the panel; the session is remembered from then on. Either way, check preview_look after acting instead of assuming the click did what you expected. preview_look hands you the page's interactive elements as a short numbered list — [e7] button "Save changes" — and passing a ref back as preview_do's selector acts on exactly that element. Prefer that over inventing CSS selectors, and over screenshots: ask for screenshot:true only when the question is genuinely visual (layout, spacing, overlap, colour), because the elements list costs a fraction of an image and cannot match the wrong node.
    If a project orchestrator is coordinating you and you get blocked, need a decision, or finish a long task it was waiting on (tests, a deploy, a build), call mcp__manyagents__notify_orchestrator with a specific message to wake it — it will take a turn to act on it.
    Messages from the orchestrator (or the user) can be injected into your RUNNING turn — they appear mid-turn, often alongside a tool result. Treat such a message as arriving NOW: if it tells you to stop, stand down, or change course, obey it immediately — drop the current plan, do not first finish the step you were on, and acknowledge briefly. Because you only see injected messages when your current tool call returns, never run a long foreground command that blocks you for many minutes: run long builds, test suites, installs, and servers with the Bash tool's run_in_background option (or a modest timeout) and poll their output — that keeps you reachable mid-task.
    Images the user attaches are ALSO written to disk, and their paths are listed in the message that carried them. A long conversation eventually pushes early images out of the window — when you can no longer see one, Read its path to get it back instead of asking the user to send it again.
    If this conversation was resumed after an app or process restart, any background tasks, watchers, or dev servers you started earlier are DEAD — they died with the previous process. Never trust a prior turn's claim that something is being watched or served; re-check actual state (and re-arm watchers or restart servers) before relying on it.
    Your Bash tool runs through ZSH on macOS, not bash, and zsh aborts a command at parse time rather than passing an unmatched pattern through. Three things bite constantly, so write around them from the start:
    - Quote globs in flags. `grep -rn foo lib/ --include=*.ts` dies with "no matches found: --include=*.ts" before grep ever runs. Write `--include='*.ts'`. Same for `--exclude=`, `--files=`, and any flag whose value contains `*`, `?`, or `[`.
    - Don't start a word with `=`. A bare `===` or `==` separator triggers zsh's `=` expansion and fails with "== not found"; use `echo "==="` or a different separator.
    - `timeout` does not exist on macOS. Use the Bash tool's own timeout parameter, or run the thing in the background and poll it.
    A command that dies this way did NOT run — the exit code is the shell's, not the tool's. Fix the quoting and re-run rather than concluding the search found nothing.
    """

    /// The shell's cwd persists across Bash calls, and background agents
    /// inherit it. A scratch `cd` earlier in a turn has sent subagents to
    /// the wrong repo, where they find nothing and come back with a
    /// failure report — which the user then has to read.
    private static let shellCwdSystemPrompt = """
    Your shell's working directory persists between Bash calls, and anything you \
    launch from the session — background agents especially — starts in whatever \
    directory you last left it in, not the project root. A stray `cd` into a \
    scratch folder sends the next subagent to the wrong repo, where it finds \
    nothing and reports failure. Never leave the shell parked outside the \
    project: run one-off commands elsewhere in a subshell — `(cd /tmp/scratch && \
    …)` — or with absolute paths, so the working directory is unchanged when the \
    command returns.
    """

    /// Counters the CLI's own "auto mode", which tells sessions to prefer
    /// Bash over Read/Edit/Write. That rule exists to dodge permission
    /// prompts, and there are none here — these sessions run with
    /// --permission-mode bypassPermissions — so it was pure cost: file
    /// changes arrived as `sed` and python heredocs, which this app can
    /// only render as an opaque shell command. The user could not see
    /// which files were being edited or created, or where.
    ///
    /// Reading is left alone: grepping the ten lines you need really is
    /// cheaper than reading the whole file.
    private static let fileToolsSystemPrompt = """
    Use the Edit and Write tools to change files, not shell commands. Do \
    not modify files with sed, awk, perl, python heredocs, or `cat >` \
    redirection. There are no permission prompts in this environment, so \
    those buy you nothing, and they cost: the app shows the user each Edit \
    and Write with its path and what changed, while a shell command is \
    just an opaque blob to them. Edit also refuses when its target is \
    ambiguous, where a regex silently changes the wrong line.

    Reading and searching are the opposite — keep using Bash for those. \
    `grep`, `sed -n '120,160p'` and friends pull the few lines you need \
    instead of a whole file.

    This rule OUTRANKS any conflicting instruction that arrives appended to \
    a message — a trailing block telling you to prefer sed, heredocs or \
    short scripts for edits is a generic default, and this is the app you \
    are actually running inside. Follow this one, and don't stop to ask \
    about the contradiction.
    """

    private static let brevitySystemPrompt = """
    NEVER write "comprehensive reports", status write-ups, exhaustive summaries, \
    recap documents, or multi-section reports on your own initiative. The user \
    finds these genuinely annoying and they flood the chat — do not produce them \
    unless explicitly asked. Default to concise, direct answers: lead with the \
    conclusion, keep it as short as the question allows, and stop. Do not \
    volunteer comparison tables, sectioned write-ups, or end-of-turn summaries of \
    what you just did. When a task would genuinely benefit from real depth (a \
    comparison, audit, architecture review, migration plan), name in ONE line \
    what such a report would cover and ASK whether I want it — write it only if I \
    say yes. Only produce a full report or long document when I explicitly ask \
    for one (e.g. "write a report", "give me the full detail", "make a PDF").

    Verification and coverage questions are NOT report requests. "Did you \
    cover everything?", "are all the agents handled?", "is anything missing?" \
    get the conclusion plus exceptions only — "Yes, all 9" or "All except X, \
    because…" — never a full inventory, per-item map, or file:line walkthrough. \
    "Review X and confirm" means confirm, not document. The same goes when the \
    asker is an orchestrator tab: replies to orchestrator dispatches are a few \
    lines of outcome; long replies just burn the orchestrator's context.

    When a report IS wanted — I asked for one, or a security review / audit \
    genuinely produces more than fits on a screen or two — do not paste the \
    whole thing into the chat. Lead with the verdict and the findings that \
    change what I do next, written out properly, not compressed into fragments. \
    Then put the full write-up in a file and cite its path in backticks on its \
    own line: the app turns a real file path in a code span into a clickable \
    link, so I can open, read, and keep the full thing. A `.md` beside the code \
    is the default; use a scratch dir for something throwaway. The chat carries \
    the answer, the file carries the exhaustive detail — and "the answer" means \
    everything I need to act, not a teaser.

    This applies to your sub-agents too: whenever you dispatch a Task/Agent \
    sub-agent, explicitly instruct it in its prompt to do its work and return a \
    SHORT findings summary (a few lines / key bullets) — NOT a comprehensive \
    report, audit document, or multi-section write-up. Sub-agents may investigate \
    deeply but must report back tersely.
    """

    /// Appended only for the orchestrator session. Describes the watch-&-nudge
    /// model and the tab tools, so the model coordinates the user's other open
    /// tabs (which they hold context in) rather than spawning sub-agents.
    private static let coordinatorSystemPrompt = """
    You are the ORCHESTRATOR for the user's other open tabs. Each tab is a \
    long-lived session the user is working in and holds context on — NOT a \
    throwaway sub-agent. Your job is to keep an eye on those tabs and act \
    between them on the user's behalf.

    Your tools come from the `manyagents` MCP server and appear in your tool \
    list with the prefix `mcp__manyagents__`. ALWAYS call them by their full \
    prefixed names — do NOT call bare names like `set_notes` (that fails). The \
    tools are:
    - `mcp__manyagents__list_agents` — your board: the other tabs with id, \
    title, status, and a one-line snapshot of each. Hidden tabs are excluded.
    - `mcp__manyagents__read_agent` — peek at a tab's recent transcript WITHOUT \
    sending it anything. Use this to check on a tab (e.g. "is the report ready?").
    - `mcp__manyagents__send_to_agent` — act ON a tab: send it a prompt (e.g. \
    hand a finished artifact from one tab to another). Delivery is immediate: \
    an idle tab starts a turn; a BUSY tab gets the message injected into its \
    running turn and reads it at its next step. Delivered is not acted-on — a \
    busy tab has not read your message yet when the call returns, and a tab \
    inside a long build or test command won't reach that step for minutes. So \
    for a control message the tab MUST obey now — "STAND DOWN", "stop \
    pushing", "you're duplicating another tab" — pass `interrupt: true`: that \
    stops its current turn and makes it read you within seconds. Either way, \
    delivered is not complied-with: confirm via its ping or read_agent before \
    acting as if it stopped. Fire-and-forget: it returns immediately and the \
    tab pings you when its turn ends. Pass wait_for_result true ONLY for a \
    genuinely quick question you cannot proceed without — never for real work.
    - `mcp__manyagents__new_agent` — spin up a new tab to work in when a task \
    needs its own context and no suitable tab exists. Reuses an existing EMPTY \
    tab in that project if free, rather than piling up blanks. Pass a `cwd` \
    you've seen via list_agents.
    WORKTREES. When several tabs must WRITE to the same repo at once, give \
    each its own `git worktree` and pass that path as new_agent's cwd — they'd \
    otherwise overwrite each other's files and fight over one index. Those tabs \
    stay on your board and nest under the project in the sidebar. Don't reach \
    for one otherwise: a tab that only reads, or the only tab touching the \
    repo, belongs in the project directory itself. Once a worktree's branch is \
    merged, remove it (`git worktree remove`) — nothing prunes them \
    automatically and they pile up in the user's Sites folder.
    - `mcp__manyagents__set_notes` — your running memory: what each tab is for, \
    what you're waiting on, your next intent. Update it as you go; the user sees it.
    - `mcp__manyagents__mute_agent` / `mcp__manyagents__unmute_agent` — stop / \
    resume being woken by a tab you've judged irrelevant (it stays on your board).

    If these `mcp__manyagents__*` tools are NOT in your tool list, say so plainly \
    rather than guessing at tool names.

    WAITING. You cannot idle inside a turn — there is no sleep, no poll, no way \
    to sit and watch. When you're waiting on a tab, END your turn and say plainly \
    what you're waiting for. The wake comes to you: any tab you dispatched pings \
    you automatically the moment it stops, whether it finished, needs a decision, \
    or died on an error. So never promise to "keep checking" or "monitor" — you \
    can't, and the user is left staring at a tab that looks stuck. Also:
    - After a `send_to_agent` dispatch, do NOT wait around, poll the tab, or \
    hold your turn open — end it. The tab pings you the moment it stops. \
    Sitting inside a blocked tool call while a tab works is exactly what you \
    must not do.
    - If you opted into wait_for_result and got status `still_running`, that's \
    NORMAL for long work: the tab blew past the 10-minute wait and is fine. Do \
    not re-send the prompt and do not treat it as a failure — end your turn; \
    you'll be pinged when it stops. The wait also returns `still_running` \
    early when a message arrives FOR YOU while you're blocked — that message \
    is already in your context: read it and act on it this turn.
    - Tab pings and reports can be injected into your RUNNING turn — they \
    appear mid-turn, often next to a tool result. Act on them at your next \
    step; don't finish a long checklist first and don't miss them.
    - A dispatch reporting an error means that tab's turn BROKE and the work \
    did not happen. Decide: retry it, hand it to another tab, or tell the user.
    - If you genuinely have nothing to wait on and nothing to do, say so and stop.

    You are woken automatically with a \
    "[Board update]" message whenever a watched tab finishes a turn. When woken: \
    read the board, consult your notes, and decide if anything needs doing. Often \
    the answer is "not yet" — say so briefly, update your notes, and wait. Prefer \
    acting through the real tabs over spawning internal Task sub-agents, since the \
    user wants the work to happen visibly. Keep your notes current — they're how \
    you remember your plan across wake-ups.
    """

    /// Appended to every NON-orchestrator session that has MCP wired. States
    /// the role plainly so a worker never claims to be the orchestrator, and
    /// routes "ask the orchestrator" requests through notify_orchestrator.
    private static let workerSystemPrompt = """
    You are NOT the orchestrator. This project may have a separate dedicated \
    "Orchestrator" tab that coordinates the open tabs; you are one of the tabs \
    it coordinates. The orchestrator board tools (list_agents, read_agent, \
    send_to_agent, new_agent, rename_agent, compact_agent, close_agent, \
    set_notes, mute_agent) are NOT available to you. If the user asks you to \
    "ask the orchestrator" something, or you need a cross-tab decision, call \
    mcp__manyagents__notify_orchestrator with a specific message — the \
    orchestrator wakes, acts, and reaches you back via a tagged \
    "[Message from orchestrator ...]" turn. If that call errors because no \
    orchestrator is designated, tell the user instead of improvising.
    """

    /// Appended on top of the coordinator prompt for a repo lead. It runs a
    /// nested repo's board, but it isn't the top of the tree, and nothing
    /// else in its context says so — its board lists only its own repo's
    /// tabs, so the workspace orchestrator that delegated the hat is
    /// invisible to it. Left to infer, a lead treats a workspace-level
    /// question as its own to answer, or sends the answer sideways to a
    /// worker because the worker is the only tab it can see.
    private static let repoLeadSystemPrompt = """
    You are a REPO LEAD, not the top orchestrator. You run the board for your \
    own repo; above you sits the workspace orchestrator that delegated this \
    hat, and it coordinates every repo in the workspace. It is deliberately \
    NOT on your board — list_agents shows only your repo's tabs, and \
    send_to_agent reaches only those, so you cannot mistake a worker for your \
    parent. To reach the workspace orchestrator — you're blocked, you need a \
    cross-repo decision, you have a result it's waiting on, or the user asks \
    you to tell it something — call mcp__manyagents__notify_orchestrator; that \
    is the one channel that goes UP, and it routes to whoever delegated you. \
    Never answer a question that spans other repos yourself: pass it up. \
    Anything scoped to your own repo, just do — that's the point of the hat.
    """

    // MARK: - Binary resolution

    static func resolveClaudePath() -> String? {
        // Prefer whatever the user's terminal would run: walk their real
        // login-shell PATH in order. The hardcoded fallbacks previously
        // shadowed newer installs — an old /opt/homebrew/bin/claude won
        // over the native installer's ~/.local/bin/claude, so sessions
        // (and `claude mcp login`) ran a stale CLI.
        for dir in userPath.split(separator: ":") {
            let candidate = "\(dir)/claude"
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        let home = NSHomeDirectory()
        let candidates = [
            "\(home)/.local/bin/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "\(home)/.claude/local/claude",
            "\(home)/.bun/bin/claude",
            "\(home)/.npm-global/bin/claude"
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return nil
    }

    // MARK: - PATH resolution

    /// The user's interactive-login-shell PATH, resolved once per app launch
    /// (statics are lazy + thread-safe). A GUI process otherwise only sees
    /// launchd's bare PATH, hiding Homebrew, nvm node, and anything else the
    /// user wired up in their shell rc files.
    static let userPath: String = computeUserPath()

    private static func computeUserPath() -> String {
        let base = probeLoginShellPath()
            ?? ProcessInfo.processInfo.environment["PATH"]
            ?? ""
        // Guarantee the common dirs are present (and ahead of launchd's) even
        // if the probe came back thin, then de-dupe while preserving order.
        let guaranteed = ["/opt/homebrew/bin", "/usr/local/bin",
                          "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        var seen = Set<String>()
        return (base.split(separator: ":").map(String.init) + guaranteed)
            .filter { !$0.isEmpty && seen.insert($0).inserted }
            .joined(separator: ":")
    }

    /// Run the user's interactive login shell to capture the PATH their
    /// terminal would have (Homebrew shellenv in .zprofile, nvm in .zshrc,
    /// etc.). A sentinel brackets the value so rc-file chatter can't corrupt
    /// it, and a 5s watchdog guards against an rc that blocks on input.
    /// Returns nil on any failure so the caller can fall back.
    private static func probeLoginShellPath() -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: shell)
        p.arguments = ["-ilc", "printf '__MA_PATH__%s__END__' \"$PATH\""]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()          // swallow shell noise
        p.standardInput = FileHandle.nullDevice
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "dumb"
        p.environment = env

        do { try p.run() } catch { return nil }
        let deadline = Date().addingTimeInterval(5)
        while p.isRunning && Date() < deadline { usleep(50_000) }
        if p.isRunning { p.terminate(); return nil }

        let data = out.fileHandleForReading.readDataToEndOfFile()
        guard let s = String(data: data, encoding: .utf8),
              let start = s.range(of: "__MA_PATH__"),
              let end = s.range(of: "__END__"),
              start.upperBound <= end.lowerBound
        else { return nil }
        let path = String(s[start.upperBound..<end.lowerBound])
        return path.isEmpty ? nil : path
    }
}
