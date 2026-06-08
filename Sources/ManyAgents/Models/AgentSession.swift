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
    @Published var status: AgentStatus = .idle {
        didSet {
            // Fire once when the agent hands control back to the user
            // (running → idle/waiting/error). Same-state writes during a
            // turn (running → running) don't qualify. Drives finish
            // notifications. didSet never fires on the initial value.
            if oldValue == .running && status != .running {
                finishedWorking.send(status)
            }
        }
    }

    /// Emits the terminal status each time the agent stops working. The
    /// manager subscribes to drive system notifications / sounds.
    let finishedWorking = PassthroughSubject<AgentStatus, Never>()
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

    /// Canonical context window for the active model, taken from the
    /// `modelUsage[*].contextWindow` field on the last `.result` event
    /// when present. Skips the model-id heuristic entirely — claude
    /// is the source of truth, and this avoids flakiness when the id
    /// reported on init doesn't carry the `[1m]` suffix even on a 1M
    /// variant. Falls back to nil for sessions that haven't completed
    /// a turn yet.
    @Published var lastTurnContextWindow: Int?

    /// Total context window for the active model. Prefers the canonical
    /// value from claude's result event; falls back to a model-id-based
    /// heuristic only when no result has landed yet.
    var contextWindowTokens: Int {
        if let canonical = lastTurnContextWindow, canonical > 0 {
            return canonical
        }
        return Self.contextWindow(for: model)
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
    /// Set when the user deliberately interrupts the in-flight turn (force-
    /// send). Lets `.processExited` treat the kill as a clean stop rather
    /// than an error, and unblocks the queue drain.
    private var intentionalInterrupt = false
    /// What claude is doing right now — "thinking", "writing", "running Bash",
    /// etc. Derived from the most recent stream event.
    @Published var currentPhase: String = "thinking"
    /// Prompts the user has queued while the current turn is in flight.
    /// Sent one-by-one in FIFO order once the current turn lands. Matches
    /// the queued-messages UX in the Claude Code TUI.
    @Published var pendingPrompts: [PendingPrompt] = []

    struct PendingPrompt: Identifiable, Equatable, Codable {
        let id = UUID()
        let text: String
        let images: [Data]
        /// When false, dispatch() skips appending this prompt to the
        /// visible transcript. Used for internal plumbing turns like
        /// the compaction summariser, where the user shouldn't see
        /// the meta-instruction sitting in the conversation as if
        /// they typed it themselves. claude still receives the text;
        /// only the UI transcript is bypassed.
        var visible: Bool = true
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

    /// The most recently answered AskUserQuestion. Kept so the picker can
    /// render a compact "✓ <answer>" confirmation chip (with the original
    /// question) in place of the options until the next turn's assistant
    /// output supersedes it. Cleared on the next `.assistantBlocks` and reset.
    @Published var answeredAsk: (state: AskState, answer: String)?

    // MARK: - Chain / pipeline state

    /// If set, this session is wired as the LEFT side of a chain — when
    /// the current turn lands cleanly (`.result` with no error), the
    /// session's last assistant text is handed off to the agent with
    /// this id. Set via the chain settings popover.
    @Published var chainTargetId: UUID?
    /// If true, chain hand-offs from this agent fire automatically
    /// without confirmation. "YOLO mode." When false, the target
    /// stages the hand-off as `pendingHandOff` and waits for the user
    /// to approve it.
    @Published var chainYoloMode: Bool = false
    /// Initial hop budget that gets baked into a new chain starting at
    /// this session — passed onto downstream sessions as `remainingHops`.
    /// 5 is the default; raising it allows longer pipelines.
    @Published var chainHopBudget: Int = 5
    /// True when this session acts as an orchestrator — claude inside
    /// it gets an MCP tool that can list and dispatch other agents.
    /// Toggled on per-session; takes effect on the next turn.
    @Published var isCoordinator: Bool = false

    /// Permission prompt waiting on the user. Set by MCPRelay when
    /// claude's permission-prompt-tool fires; cleared when the user
    /// taps Allow or Deny in the picker. While non-nil, a banner sits
    /// above the composer with the request details.
    @Published var pendingPermission: PendingPermission?

    struct PendingPermission: Identifiable, Equatable {
        let id: String                    // matches MCP relay request id
        let toolName: String
        let toolInput: [String: AnyCodable]
        let createdAt: Date

        static func == (lhs: PendingPermission, rhs: PendingPermission) -> Bool {
            lhs.id == rhs.id
        }
    }

    /// Fires every time the user resolves a pending permission request.
    /// MCPRelay subscribes to this to unblock its awaiting tool call.
    let permissionDecisions = PassthroughSubject<PermissionDecision, Never>()

    struct PermissionDecision {
        let requestId: String
        let allow: Bool
        let message: String?
    }

    /// Resolve a permission prompt. Pops the banner, fires the
    /// decision out for MCPRelay to forward back to claude.
    func respondToPermission(allow: Bool, message: String? = nil) {
        guard let pending = pendingPermission else { return }
        pendingPermission = nil
        permissionDecisions.send(PermissionDecision(
            requestId: pending.id,
            allow: allow,
            message: message
        ))
    }

    /// Agent id that fed THIS session as part of a chain. Set on hand-
    /// off; used for visualisation (header chip) and loop detection.
    @Published var chainSourceId: UUID?
    /// Hops left before the chain stops auto-forwarding. Decrements on
    /// each hand-off; once it hits 0, auto-forward is suppressed and
    /// the conversation stops (a manual "Send to" still works).
    @Published var remainingHops: Int = 5

    /// A hand-off that landed on this session and is awaiting user
    /// approval — appears as a banner above the composer with Send /
    /// Edit / Dismiss. Skipped entirely when the source's chain is in
    /// YOLO mode (the hand-off is dispatched immediately instead).
    @Published var pendingHandOff: PendingHandOff?

    struct PendingHandOff: Identifiable, Equatable {
        let id = UUID()
        let sourceAgentId: UUID
        let sourceProjectName: String
        let sourceTitle: String
        let payload: String
        let hopsRemaining: Int
    }

    /// Fires once whenever a turn resolves cleanly (`.result` without
    /// error). The manager subscribes to this to drive auto-forwarding
    /// for chained sessions. Carries the assistant text from the turn
    /// that just ended (whatever the model said last).
    let turnCompleted = PassthroughSubject<String, Never>()

    /// Live composer text for THIS session. Owned on the session (not
    /// in ComposerView's @State) so flipping tabs doesn't wipe a half-
    /// typed draft — each session remembers what its operator was
    /// mid-keystroke on.
    @Published var draftText: String = ""

    /// The most-recently dispatched prompt — kept around so the
    /// auto-resumer can re-send it after network comes back up.
    /// Cleared on the next successful `.result`.
    var lastSentPrompt: PendingPrompt?

    /// True when the most recent turn failed while the network was
    /// down. AgentManager watches NetworkMonitor.isOnline; on
    /// transition false → true, it re-dispatches `lastSentPrompt` for
    /// every session with this flag set, then clears the flag.
    @Published var awaitingNetworkResume: Bool = false

    /// True while a real compaction (kebab "Compact conversation") is
    /// in flight. Phase 1 sends a summarise turn; phase 2 tears down
    /// the claude session and seeds a fresh one with the summary. The
    /// UI shows a banner across both phases so the user knows the tab
    /// is intentionally between contexts, not idle.
    @Published var isCompacting: Bool = false
    private var compactCancellable: AnyCancellable?

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

    /// Real conversation compaction — the kebab "Compact conversation"
    /// action. Two phases:
    ///   1. Ask the current claude session to produce a self-contained
    ///      summary of everything important so far. We capture the
    ///      assistant's last text on `turnCompleted`.
    ///   2. Drop the claude session id + resume id + transcript + token
    ///      state, then send the summary as turn 1 of a brand-new
    ///      claude process (no `--resume`). The fresh process gets its
    ///      own session_id back via the init event, and the new context
    ///      window starts essentially empty.
    /// Visual continuity stays — same tab, same UUID, same project, but
    /// the model's working memory is genuinely reset.
    func compact() {
        guard !isCompacting, status != .running, !bridge.isBusy else { return }
        isCompacting = true
        // Subscribe ONCE — turnCompleted is a PassthroughSubject, so we
        // need a dedicated cancellable rather than reusing the manager's.
        compactCancellable = turnCompleted
            .prefix(1)
            .sink { [weak self] summary in
                Task { @MainActor [weak self] in
                    self?.finishCompact(with: summary)
                }
            }
        let summarisePrompt = """
        Compaction request from the user. Produce ONLY a self-contained \
        brief that captures everything important from our conversation \
        so I can resume work without scrollback. Include:
        - Identity & scope (who, what, where).
        - Key decisions reached, with the reasoning behind each.
        - Files / paths / commands we've touched, with their current state.
        - In-flight work and where we left off (next concrete step).
        - Open questions, unresolved disagreements, things waiting on other people.
        - Anything brittle the future-me would otherwise re-discover the hard way.
        Format it as clean Markdown with section headings. No preamble, \
        no apology, no "here's a summary" sentence — just the brief itself.
        """
        // Hidden from the visible transcript — this is internal
        // plumbing, not something the user typed.
        send(summarisePrompt, visible: false)
    }

    @MainActor
    private func finishCompact(with summary: String) {
        let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        // If the summary came back empty or trivially short, bail out
        // rather than blow away the transcript for nothing. Surface as
        // an error so the user can retry.
        guard trimmed.count > 80 else {
            isCompacting = false
            lastError = "Compaction failed — model returned an empty summary. Try again."
            return
        }

        // Tear down the bridge and clear all session-id pointers so the
        // next send() spawns a brand-new claude process with no
        // `--resume` arg. The session_id from the new init event
        // overwrites `claudeSessionId` automatically.
        bridge.cancel()
        bridge.currentSessionId = nil
        resumeSessionId = nil
        claudeSessionId = nil

        // Drop transcript + transient state so the UI doesn't carry old
        // tool-result rows / pending prompts into the fresh context.
        messages.removeAll()
        pendingPrompts.removeAll()
        pendingAskUserQuestion = nil
        answeredAsk = nil
        pendingPermission = nil
        pendingHandOff = nil
        lastTurnContextTokens = 0
        lastTurnContextWindow = nil
        currentTurnOutputTokens = 0
        inflightTokenEstimate = 0
        currentPhase = "thinking"
        lastError = nil

        // Seed the new session with the summary. The model receives
        // the full brief, but the user shouldn't see a giant
        // unformatted user-role block — that just looks like noise.
        // We append a small SYSTEM-role marker so the transcript reads
        // "conversation compacted" + then the new assistant reply,
        // instead of "blank → assistant suddenly answering".
        let seed = """
        [Compacted from prior conversation. The summary below is the entirety of our shared context — treat anything not in it as if it never happened.]

        \(trimmed)

        Ready to continue.
        """
        let charCount = trimmed.count
        let lineCount = trimmed.components(separatedBy: "\n").count
        let marker = "Conversation compacted — \(lineCount)-line brief (\(charCount.formatted()) chars) seeded to a fresh claude session."
        messages.append(
            Message(role: .system, blocks: [.text(id: UUID(), text: marker)])
        )
        isCompacting = false
        compactCancellable = nil
        // Hidden — model receives the full brief, transcript stays clean.
        send(seed, visible: false)
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
    /// `visible = false` skips the visible transcript append (used by
    /// the compaction summariser).
    func send(_ text: String, images: [Data] = [], visible: Bool = true) {
        // Clear any waiting-for-net state — the user just hit send
        // again, so they're taking control back from the auto-resumer.
        awaitingNetworkResume = false
        let prompt = PendingPrompt(text: text, images: images, visible: visible)
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
        if prompt.visible {
            messages.append(userMessage)
        }
        status = .running
        currentTurnStartedAt = Date()
        currentTurnOutputTokens = 0
        inflightTokenEstimate = 0
        currentPhase = "thinking"
        // Stash for the auto-resumer. Cleared on the next clean .result.
        lastSentPrompt = prompt
        // SAFETY ROLLBACK: only coordinator sessions wire MCP for now.
        // The "always-on for permission prompts" flow had a runaway
        // somewhere that filled the conversation pane with an empty
        // user-styled block. Reverting until that's traced.
        if isCoordinator {
            do {
                _ = try MCPRelay.shared.startIfNeeded()
                bridge.mcpConfigPath = try CoordinatorConfig.write(for: self)
            } catch {
                bridge.mcpConfigPath = nil
                lastError = "Coordinator setup failed: \(error.localizedDescription)"
            }
        } else {
            bridge.mcpConfigPath = nil
        }
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
        // Keep a record so the picker shows a "✓ <answer>" confirmation chip
        // (with the original question) until the next turn's output lands.
        answeredAsk = (state: q, answer: answer)
        // In headless `--print` mode the CLI auto-denies AskUserQuestion and
        // ends the turn — there's no open tool_result to fulfil and stdin is
        // already closed, so the old `submitToolResult` path silently no-oped
        // (the bug: "click does nothing, stuck on Thinking…"). Deliver the
        // choice as a normal new user turn instead; the resumed session still
        // holds the question context, so a plain follow-up continues cleanly.
        // visible:false keeps it out of the bubble flow — the chip stands in.
        send(answer, visible: false)
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
            intentionalInterrupt = true
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
            // A fresh assistant turn supersedes any answered-question chip.
            answeredAsk = nil
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
                if let cw = u.canonicalContextWindow, cw > 0 {
                    lastTurnContextWindow = cw
                }
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
                // If we lost the network, flag for auto-resume rather
                // than asking the user to retype the prompt. The manager
                // re-dispatches lastSentPrompt as soon as the path goes
                // satisfied again.
                if !NetworkMonitor.shared.isOnline {
                    awaitingNetworkResume = true
                }
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
                // Clean completion: the prompt landed, so the auto-
                // resumer has nothing to retry.
                lastSentPrompt = nil
                awaitingNetworkResume = false
                // Tell AgentManager a clean turn just landed so the chain
                // coordinator can decide whether to auto-forward to a
                // chainTargetId (or stage the hand-off on the target).
                // Only fires for non-error completions so we don't
                // propagate a broken state down the pipeline.
                turnCompleted.send(lastAssistantText)
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
            // Each turn is its own process. If status is STILL .running here,
            // no .result landed — the turn was force-cancelled or the process
            // died. Move OFF .running regardless of exit code; otherwise
            // drainQueueIfReady (guarded on `status != .running`) can never
            // fire the queued/forced prompt — the force-send "nothing happens"
            // bug. A successful turn already set .waiting via .result, so the
            // `status == .running` check leaves it untouched.
            if status == .running {
                if intentionalInterrupt || exitCode == 0 {
                    status = .idle          // clean stop (force-send / normal exit)
                } else {
                    status = .error
                    lastError = "claude exited (\(exitCode))"
                }
            }
            intentionalInterrupt = false
            // Whether the previous turn succeeded, errored, or was cancelled,
            // drain the next queued prompt.
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
