import Foundation
import Combine

enum AgentStatus {
    case idle       // ready for input, no work in flight
    case running    // assistant is generating or a tool call is in progress
    case waiting    // assistant turn ended with end_turn — user's move
    case error      // bridge failed or claude exited unexpectedly
}

/// One conversation with a claude agent. Owns the `ClaudeBridge` subprocess
/// and the message history. Mirrors `HostedSession` in ClaudeDeck but talks
/// to claude over JSON-stream stdio instead of a PTY.
@MainActor
final class AgentSession: ObservableObject, Identifiable {
    let id = UUID()
    let cwd: String
    let createdAt: Date

    @Published var displayName: String
    @Published var aiTitle: String?
    @Published var messages: [Message] = []
    @Published var status: AgentStatus = .idle
    @Published var claudeSessionId: String?
    @Published var lastError: String?
    @Published var totalInputTokens: Int = 0
    @Published var totalOutputTokens: Int = 0
    @Published var totalCostUsd: Double = 0
    /// Total tokens claude saw in its context window on the LAST completed
    /// turn (input + cache_read + cache_creation). This is the right number
    /// to compare against the model's context window to compute "how full
    /// am I" — `totalInputTokens` would double-count cache reads across
    /// every turn.
    @Published var lastTurnContextTokens: Int = 0
    /// Model id reported by claude's init event ("claude-opus-4-7",
    /// "claude-opus-4-7[1m]", "claude-sonnet-4-6", etc). Drives the
    /// context-window cap for the gauge so we don't over- or under-
    /// estimate context usage based on a wrong assumption.
    @Published var model: String?

    /// Total context window for the active model, derived from `model`.
    /// Falls back to 200K — the conservative default that matches every
    /// non-[1m] Claude release. Updates when an init event arrives.
    var contextWindowTokens: Int {
        Self.contextWindow(for: model)
    }

    static func contextWindow(for model: String?) -> Int {
        guard let m = model?.lowercased() else { return 200_000 }
        // Explicit [1m] / -1m suffix means 1M variant. Older signal —
        // newer Claude builds drop the suffix from the init event even
        // when running the 1M variant, so we can't rely on it alone.
        if m.contains("[1m]") || m.contains("-1m") { return 1_000_000 }
        // Opus 4.7+ ships with 1M as the default. claude's init event
        // reports the bare id ("claude-opus-4-7" / "claude-opus-4-8" /
        // "claude-opus-5-…") even on the 1M variant, so we have to
        // infer from the family — without this the gauge slams to 100%
        // around the 200K mark while /context still reads ~20%.
        if m.range(of: #"opus-4-[7-9]"#, options: .regularExpression) != nil {
            return 1_000_000
        }
        if m.range(of: #"opus-[5-9]"#, options: .regularExpression) != nil {
            return 1_000_000
        }
        return 200_000
    }
    /// When the user pressed send for the current in-flight turn. `nil` once
    /// the turn lands. Drives the "Warping… 2m 19s" elapsed timer.
    @Published var currentTurnStartedAt: Date?
    /// Running output-token count for the in-flight turn. Reset on send.
    /// Sum of (canonical per-message counts already committed) + (a live
    /// chars-÷-4 estimate of the in-flight message). The estimate is
    /// rolled back into the canonical count by `.tokenCount` events at
    /// each message boundary, so the displayed number self-corrects.
    @Published var currentTurnOutputTokens: Int = 0
    /// chars-÷-4 estimate of how much we've over-counted the current
    /// in-flight message via partial-text deltas. Subtracted then
    /// replaced when `.tokenCount` lands with the canonical figure.
    /// Not @Published — internal accounting only.
    private var inflightTokenEstimate: Int = 0
    /// What claude is doing right now — "thinking", "writing", "running Bash",
    /// etc. Derived from the most recent stream event.
    @Published var currentPhase: String = "thinking"
    /// Prompts the user has queued while the current turn is in flight.
    /// Sent one-by-one in FIFO order once the current turn lands. Matches
    /// the queued-messages UX in the Claude Code TUI.
    @Published var pendingPrompts: [PendingPrompt] = []

    struct PendingPrompt: Identifiable, Equatable {
        let id = UUID()
        let text: String
        let images: [Data]
    }

    /// claude called AskUserQuestion mid-turn and is now waiting for our
    /// selection. The UI renders an inline picker bound to this; clicking
    /// an option calls `answerQuestion` which posts the result back to
    /// claude and clears this state.
    @Published var pendingAskUserQuestion: AskState?

    struct AskState: Equatable {
        let toolUseId: String
        let header: String?
        let question: String
        let options: [BridgeEvent.AskOption]
        let multiSelect: Bool
    }

    /// Set externally before connect() if we should resume a prior session id.
    var resumeSessionId: String?

    let bridge: ClaudeBridge
    private var bridgeCancellable: AnyCancellable?

    init(cwd: String, resumeSessionId: String? = nil) {
        self.cwd = cwd
        self.createdAt = Date()
        self.resumeSessionId = resumeSessionId
        self.displayName = ProjectNaming.name(forCwd: cwd)
        self.bridge = ClaudeBridge(cwd: cwd, resumeSessionId: resumeSessionId)
    }

    /// Subscribe to bridge events. Idempotent and lightweight — no claude
    /// process is spawned until the user actually sends a prompt.
    func connect() {
        guard bridgeCancellable == nil else { return }
        bridgeCancellable = bridge.events
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                self?.handle(event)
            }
    }

    /// Cancel any in-flight turn and stop forwarding events.
    func disconnect() {
        bridgeCancellable?.cancel()
        bridgeCancellable = nil
        bridge.cancel()
    }

    /// Send a user prompt. Spawns a fresh `claude -p` process per turn,
    /// resuming the existing session if we already have one.
    /// User submitted a prompt. Sends immediately if the agent is free;
    /// otherwise queues it for FIFO delivery once the current turn lands.
    func send(_ text: String, images: [Data] = []) {
        let prompt = PendingPrompt(text: text, images: images)
        if status == .running || bridge.isBusy {
            pendingPrompts.append(prompt)
            return
        }
        dispatch(prompt)
    }

    /// Actually push a prompt to the bridge. Adds the user message to the
    /// transcript, flips status, kicks off the turn.
    private func dispatch(_ prompt: PendingPrompt) {
        var blocks: [ContentBlock] = []
        if !prompt.text.isEmpty {
            blocks.append(.text(id: UUID(), text: prompt.text))
        }
        for img in prompt.images {
            blocks.append(.image(id: UUID(), data: img, mediaType: "image/png"))
        }
        let userMessage = Message(role: .user, blocks: blocks)
        messages.append(userMessage)
        status = .running
        currentTurnStartedAt = Date()
        currentTurnOutputTokens = 0
        inflightTokenEstimate = 0
        currentPhase = "thinking"
        // Kick the bridge off the main thread — process.run() + stdin
        // write was blocking SwiftUI rendering, so the "Thinking…"
        // indicator didn't appear until the spawn returned.
        let bridgeRef = bridge
        Task.detached(priority: .userInitiated) {
            bridgeRef.send(text: prompt.text, imagesPng: prompt.images)
        }
    }

    /// Pop the next queued prompt (if any) and send it. Called whenever a
    /// turn finishes so the queue drains FIFO without further user action.
    private func drainQueueIfReady() {
        guard status != .running, !bridge.isBusy,
              let next = pendingPrompts.first else { return }
        pendingPrompts.removeFirst()
        dispatch(next)
    }

    /// Allow the composer to surgically remove a queued item (e.g. an "X"
    /// on the queued-prompts strip).
    func removeQueued(id: UUID) {
        pendingPrompts.removeAll { $0.id == id }
    }

    /// User picked an option from the AskUserQuestion picker. Post the
    /// result back to claude as a tool_result on the still-open stdin so
    /// the turn continues. Multi-select callers pass the comma-joined
    /// labels.
    func answerQuestion(_ answer: String) {
        guard let q = pendingAskUserQuestion else { return }
        pendingAskUserQuestion = nil
        // Render the user's pick in the transcript so the conversation
        // history reads cleanly on replay.
        messages.append(Message(
            role: .user,
            blocks: [.text(id: UUID(), text: answer)]
        ))
        currentPhase = "thinking"
        bridge.submitToolResult(toolUseId: q.toolUseId, content: answer)
    }

    /// "Send now" — move a queued prompt to the front of the line and
    /// cancel any in-flight turn so this one fires immediately. Other
    /// queued prompts stay queued and dispatch FIFO behind it.
    func forceSend(id: UUID) {
        guard let idx = pendingPrompts.firstIndex(where: { $0.id == id }) else { return }
        let prompt = pendingPrompts.remove(at: idx)
        pendingPrompts.insert(prompt, at: 0)
        if status == .running || bridge.isBusy {
            // Terminate the running process; .processExited triggers
            // drainQueueIfReady which will pop our prompt from the front.
            bridge.cancel()
        } else {
            // Idle path — just dispatch directly.
            pendingPrompts.removeFirst()
            dispatch(prompt)
        }
    }

    // MARK: - Stream event handling

    private func handle(_ event: BridgeEvent) {
        switch event {
        case .initialized(let sid, let model):
            // claude assigns a new session_id on the first turn; subsequent
            // turns reuse it via the bridge's currentSessionId.
            claudeSessionId = sid
            bridge.currentSessionId = sid
            if let model {
                self.model = model
            }
        case .assistantBlocks(let blocks):
            // Either append to an in-progress assistant message or start a
            // new one. The CLI emits each assistant *message* as a single
            // event (not per-delta) when streaming is off.
            if let lastIdx = messages.indices.last,
               messages[lastIdx].role == .assistant {
                messages[lastIdx].blocks.append(contentsOf: blocks)
            } else {
                messages.append(Message(role: .assistant, blocks: blocks))
            }
            status = .running
            // Derive a current-phase label from what just arrived so the
            // status line can read "writing" / "running Bash" / etc.
            for block in blocks.reversed() {
                switch block {
                case .toolUse(_, _, let name, _, _):
                    currentPhase = name == "Bash" ? "running Bash"
                                 : (name == "Edit" || name == "MultiEdit" || name == "Write") ? "editing"
                                 : (name == "Read") ? "reading"
                                 : (name == "Grep" || name == "Glob") ? "searching"
                                 : "running \(name)"
                case .text:
                    currentPhase = "writing"
                case .thinking:
                    currentPhase = "thinking"
                case .toolResult, .image:
                    continue
                }
                break
            }
        case .toolResult(let toolUseId, let content, let isError, let parentToolUseId):
            // Claude itself runs tools and reports the result. Render as a
            // dedicated message so the conversation stays linear. The
            // parentToolUseId, if set, tells the renderer this result
            // belongs to a subagent's tool call — it nests under the
            // parent Task card rather than rendering as a top-level row.
            let block = ContentBlock.toolResult(id: UUID(),
                                                toolUseId: toolUseId,
                                                content: content,
                                                isError: isError,
                                                parentToolUseId: parentToolUseId)
            messages.append(Message(role: .system, blocks: [block]))
        case .result(let usage, let cost, let isError, let resultText):
            if let u = usage {
                totalInputTokens += u.inputTokens
                totalOutputTokens += u.outputTokens
                currentTurnOutputTokens = u.outputTokens
                lastTurnContextTokens = u.totalContextTokens
            }
            // End-of-turn: estimate should already be drained by the
            // last message_delta. Clear defensively in case the turn
            // ended via error or an unexpected event ordering — keeps
            // the next turn from starting with stale state.
            inflightTokenEstimate = 0
            if let c = cost { totalCostUsd += c }
            if isError {
                status = .error
                lastError = resultText
            } else {
                // Decide "waiting on you" vs "idle" by looking at the
                // most recent assistant prose. claude is prompted (via
                // --append-system-prompt in ClaudeBridge) to end with a
                // cue when input is expected — we match that here.
                let lastAssistantText = messages
                    .last(where: { $0.role == .assistant })?.flatText ?? ""
                status = Self.endedAwaitingUserInput(lastAssistantText)
                    ? .waiting
                    : .idle
            }
            currentTurnStartedAt = nil
            // Hand off to the next queued prompt on the next runloop tick so
            // any UI bound to .result has settled before the new turn flips
            // status back to .running.
            DispatchQueue.main.async { [weak self] in self?.drainQueueIfReady() }
        case .partialBlockKind(let kind):
            // Earliest-possible "what is claude doing right now" signal.
            // Stops the indicator from sitting on a rotating whimsy verb
            // during long extended-thinking stretches that never produce
            // a completed assistant message.
            currentPhase = kind
        case .partialOutputChars(let chars):
            // Live ticker — count incoming chars as ~tokens/4 so the
            // gauge moves smoothly inside a single long message instead
            // of waiting for message-end. Rolled back when `.tokenCount`
            // delivers the canonical figure for the same message.
            let est = max(1, chars / 4)
            inflightTokenEstimate += est
            currentTurnOutputTokens += est
        case .tokenCount(let outputTokens):
            // End-of-message canonical figure (from message_delta).
            // Roll back the live estimate for the message that just
            // ended, then add the truth on top — net behaviour is
            // "sum per-message canonical counts across the turn".
            currentTurnOutputTokens -= inflightTokenEstimate
            inflightTokenEstimate = 0
            currentTurnOutputTokens += outputTokens
        case .askUserQuestion(let toolUseId, let prompt):
            pendingAskUserQuestion = AskState(
                toolUseId: toolUseId,
                header: prompt.header,
                question: prompt.question,
                options: prompt.options,
                multiSelect: prompt.multiSelect
            )
            currentPhase = "waiting on you"
        case .processExited(let exitCode):
            // Each turn is its own process. A non-zero exit during a turn
            // (status == .running) is an error; an exit after a successful
            // result has already landed the .waiting status, so just keep it.
            if exitCode != 0 && status == .running {
                status = .error
                lastError = "claude exited (\(exitCode))"
            }
            // Whether the previous turn succeeded or errored, try to drain.
            DispatchQueue.main.async { [weak self] in self?.drainQueueIfReady() }
        case .systemError(let message):
            status = .error
            lastError = message
        }
    }

    /// True when the assistant's last turn ended in a way that suggests
    /// it needs the user's input before continuing — a question mark, or
    /// one of a small set of natural cues claude is instructed to use
    /// via --append-system-prompt. Otherwise the turn is treated as a
    /// completion (acknowledgement, status report, goodbye) and the
    /// session goes idle.
    static func endedAwaitingUserInput(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        // Only consider the trailing window — earlier "?"s in a long
        // response don't indicate a present-tense ask.
        let tail = String(trimmed.suffix(240))
        if tail.hasSuffix("?") { return true }
        // Strip closing punctuation / wrappers and re-check.
        var stripped = tail
        while let last = stripped.last,
              "`)]}\"'*".contains(last) {
            stripped.removeLast()
        }
        if stripped.hasSuffix("?") { return true }
        let lower = tail.lowercased()
        let cues = [
            "your move",
            "your call",
            "let me know",
            "should i ", "shall i ",
            "do you want", "would you like",
            "which one", "which would", "which do you",
            "what should",
            "either way",
            "ready to proceed",
            "confirm",
            "decide",
            "pick one", "pick which",
            "your thoughts"
        ]
        return cues.contains { lower.contains($0) }
    }
}
