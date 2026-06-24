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
    /// claude called the AskUserQuestion tool. The owning session renders a
    /// native picker; the chosen answer is delivered as a new user turn
    /// (headless `--print` auto-denies the tool and ends the turn, so there's
    /// no open tool_result to fulfil — see `AgentSession.answerQuestion`).
    case askUserQuestion(toolUseId: String, prompt: AskPrompt)

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
    static let availableModels: [(label: String, id: String)] = [
        ("Default", ""),
        ("Opus 4.8", "claude-opus-4-8"),
        ("Sonnet 4.6", "claude-sonnet-4-6"),
        ("Haiku 4.5", "claude-haiku-4-5-20251001"),
    ]

    let cwd: String
    /// Updated by the owner after the first `initialized` event so subsequent
    /// `sendUserText` calls can resume the same conversation.
    var currentSessionId: String?

    private let subject = PassthroughSubject<BridgeEvent, Never>()
    private var activeProcess: Process?
    /// Held open for the duration of a turn: the initial user payload is
    /// written here, and it's closed in handleResult so claude exits cleanly.
    private var activeStdin: FileHandle?
    private var stdoutBuffer = Data()
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
        if let p = activeProcess, p.isRunning { return }
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
            // Always bypass the sensitive-file permission gate — this is a
            // local dev tool driving the user's own sessions; the prompts just
            // got in the way. (Previously a per-tab / global toggle.)
            "--permission-mode", "bypassPermissions",
            // Append a small instruction so claude consistently signals
            // "waiting on you" with a recognizable cue.
            "--append-system-prompt", Self.waitingCueSystemPrompt,
            // Keep answers concise; offer (don't dump) long reports. Pairs with
            // the waiting cue so the offer surfaces as a "waiting on you" state.
            "--append-system-prompt", Self.brevitySystemPrompt,
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
        let preferredModel = UserDefaults.standard.string(forKey: Keys.model) ?? ""
        if !preferredModel.isEmpty {
            args.append(contentsOf: ["--model", preferredModel])
        }
        if let rid = currentSessionId, !rid.isEmpty {
            args.append(contentsOf: ["--resume", rid])
        }
        if let cfg = mcpConfigPath {
            // Hand claude the manyagents-generated mcp.json — it exposes
            // list_agents + dispatch_agent for coordinator/orchestrator mode.
            args.append(contentsOf: ["--mcp-config", cfg])
            // Nudge the model to actually USE the user's open agents. Left to
            // itself it reaches for internal Task sub-agents and the other
            // tabs never move — defeating the point of orchestrator mode.
            args.append(contentsOf: ["--append-system-prompt", Self.coordinatorSystemPrompt])
            // NB: deliberately NO --permission-prompt-tool. We always run
            // --permission-mode bypassPermissions, so there are no permission
            // prompts to route. Passing the prompt-tool alongside bypass is
            // contradictory and made claude try to call a permission tool it
            // couldn't see ("mcp__manyagents__permission_prompt not found"),
            // which broke the orchestrator's tool loading.
        }

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
                // The persistent process is gone (cancel / teardown / crash).
                // Clear state so isBusy frees up and the next send() respawns.
                self?.activeProcess = nil
                self?.activeStdin = nil
                self?.turnInFlight = false
                self?.subject.send(.processExited(exitCode: code))
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
        guard !turnInFlight else {
            emit(.systemError("Previous turn still in flight."))
            return
        }
        ensureProcess()
        guard activeStdin != nil else { return }   // ensureProcess emitted the error
        askUserQuestionIds.removeAll()              // per-turn, not per-process
        turnInFlight = true
        var content: [[String: Any]] = []
        if !text.isEmpty {
            content.append(["type": "text", "text": text])
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

    private func writeUserPayload(_ payload: [String: Any]) {
        guard let handle = activeStdin,
              let data = try? JSONSerialization.data(withJSONObject: payload),
              let line = String(data: data, encoding: .utf8)
        else { return }
        let bytes = (line + "\n").data(using: .utf8) ?? Data()
        try? handle.write(contentsOf: bytes)
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
            case "text":
                emit(.partialBlockKind("writing"))
            case "tool_use":
                let toolName = block["name"] as? String ?? "tool"
                emit(.partialBlockKind("preparing \(toolName)"))
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
    - `mcp__manyagents__send_to_agent` — act ON a tab: send it a prompt as a \
    normal user turn (e.g. hand a finished artifact from one tab to another). \
    Waits for its reply by default.
    - `mcp__manyagents__new_agent` — spin up a new tab to work in when a task \
    needs its own context and no suitable tab exists. Reuses an existing EMPTY \
    tab in that project if free, rather than piling up blanks. Pass a `cwd` \
    you've seen via list_agents.
    - `mcp__manyagents__set_notes` — your running memory: what each tab is for, \
    what you're waiting on, your next intent. Update it as you go; the user sees it.
    - `mcp__manyagents__mute_agent` / `mcp__manyagents__unmute_agent` — stop / \
    resume being woken by a tab you've judged irrelevant (it stays on your board).

    If these `mcp__manyagents__*` tools are NOT in your tool list, say so plainly \
    rather than guessing at tool names. You are woken automatically with a \
    "[Board update]" message whenever a watched tab finishes a turn. When woken: \
    read the board, consult your notes, and decide if anything needs doing. Often \
    the answer is "not yet" — say so briefly, update your notes, and wait. Prefer \
    acting through the real tabs over spawning internal Task sub-agents, since the \
    user wants the work to happen visibly. Keep your notes current — they're how \
    you remember your plan across wake-ups.
    """

    // MARK: - Binary resolution

    static func resolveClaudePath() -> String? {
        let home = NSHomeDirectory()
        let candidates = [
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
