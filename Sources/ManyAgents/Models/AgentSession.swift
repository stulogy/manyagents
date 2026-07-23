import Foundation
import Combine

enum AgentStatus {
    case idle       // ready for input, no work in flight
    case running    // assistant is generating or a tool call is in progress
    case waiting    // assistant turn ended with end_turn — user's move
    case error      // bridge failed or claude exited unexpectedly

    /// Short human label used in the orchestrator board snapshot.
    var boardLabel: String {
        switch self {
        case .idle:    return "idle"
        case .running: return "running"
        case .waiting: return "waiting on user"
        case .error:   return "error"
        }
    }
}

/// One conversation with a claude agent. Owns the `ClaudeBridge` subprocess
/// and the message history. Mirrors `HostedSession` in ClaudeDeck but talks
/// to claude over JSON-stream stdio instead of a PTY.
@MainActor
final class AgentSession: ObservableObject, Identifiable {
    let id: UUID
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
    /// Output tokens carried over from turn(s) interrupted by a force-send, so
    /// the displayed count continues across the interrupt instead of dropping
    /// to 0. The indicator shows `carriedTurnTokens + currentTurnOutputTokens`.
    /// Accumulates on each force-send; reset to 0 when a turn completes.
    @Published var carriedTurnTokens: Int = 0
    /// chars-÷-4 estimate of how much we've over-counted the current
    /// in-flight message via partial-text deltas. Subtracted then
    /// replaced when `.tokenCount` lands with the canonical figure.
    /// Not @Published — internal accounting only.
    private var inflightTokenEstimate: Int = 0
    /// Set when the user deliberately interrupts the in-flight turn (force-
    /// send). Lets `.processExited` treat the kill as a clean stop rather
    /// than an error, and unblocks the queue drain.
    private var intentionalInterrupt = false
    /// Captured on a force-send so the interrupting turn keeps the original
    /// turn's start time instead of resetting the timer to 0 — interrupting a
    /// thinking turn shouldn't make it look like the wait started over.
    private var carryOverTurnStart: Date?
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
        /// True for an automatic orchestrator board-wake turn. Optional so old
        /// persisted snapshots (which lack the key) still decode. The resulting
        /// assistant messages get tagged so silent "holding" turns can be
        /// hidden from the transcript.
        var isBoardWake: Bool? = nil
    }

    /// Set while a board-wake turn is dispatching, so the assistant messages it
    /// produces get tagged `fromBoardWake`. Cleared at turn end.
    private var currentTurnIsBoardWake = false

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

    /// Every AskUserQuestion the user has answered this session, keyed by
    /// the question's tool_use id. Unlike `answeredAsk` (a single transient
    /// chip that clears on the next turn), this persists for the life of
    /// the session so the transcript can render a permanent "you chose X"
    /// card where the question was asked — the decision stays in history
    /// instead of vanishing once the agent resumes.
    @Published var answeredQuestions: [String: AnsweredAsk] = [:]

    struct AnsweredAsk: Equatable {
        let state: AskState
        let answer: String
    }

    // MARK: - Chain / pipeline state

    /// True when this session acts as THE orchestrator — exactly one tab at
    /// a time (enforced by AgentManager.setOrchestrator). Claude inside it
    /// gets MCP tools to see/read/send/mute the other tabs, and is woken
    /// ("watch & nudge") whenever a watched tab finishes a turn. Toggled via
    /// the tab menu; takes effect on the next turn.
    @Published var isCoordinator: Bool = false

    // MARK: - Orchestrator (v2)

    /// User-level "Hide from orchestrator": this tab drops off the board
    /// entirely and never pings the orchestrator. Hard opt-out, distinct
    /// from the orchestrator's soft `mutedTabIds`.
    @Published var hiddenFromOrchestrator: Bool = false
    /// The orchestrator's running "thinking" note — what each tab is for,
    /// what it's waiting on, its next intent. Written by the orchestrator
    /// itself via the `set_notes` MCP tool; surfaced in the brain-icon
    /// popover. Only meaningful on the orchestrator session.
    @Published var orchestratorNotes: String = ""
    /// Tabs the orchestrator has soft-muted (judged irrelevant): still on
    /// the board for reference, but their turn-completions don't wake it.
    /// Managed via the `mute_agent`/`unmute_agent` tools. Orchestrator only.
    @Published var mutedTabIds: Set<UUID> = []
    /// Accumulated board-update lines since the orchestrator's last turn.
    /// Watched-tab completions append here silently (zero tokens) and the
    /// whole digest rides along with the orchestrator's next prompt —
    /// push-accumulate, pull-read, replacing the old timed wake turns.
    /// Orchestrator only. Capped in the appender.
    @Published var pendingBoardUpdates: [String] = []
    /// Set while the orchestrator is mid-turn and a watched tab finished —
    /// coalesces a burst of completions into a single follow-up "recheck"
    /// ping once the current orchestrator turn lands. Orchestrator only.
    @Published var pendingOrchestratorRecheck: Bool = false
    /// Count of clean turn completions on this session, monotonic for its
    /// lifetime. Feeds the orchestrator wake signature (so back-to-back
    /// completions with the same end status still register as change) and
    /// indexes the anti-loop suppression below.
    private(set) var completedTurns: Int = 0

    /// Turn indices (values of `completedTurns` at completion time) whose
    /// completion must NOT ping the orchestrator — set on a TARGET tab when
    /// the orchestrator dispatches a prompt into it, since it already gets
    /// that reply via the dispatch tool. Indexed rather than a single bool
    /// so a busy tab's own in-flight turn doesn't consume the suppression
    /// meant for the orchestrator's turn (and then double-ping).
    var suppressedOrchestratorTurns: Set<Int> = []

    /// Name used on the orchestrator board and in digests. An unnamed
    /// tab's displayName is the bare project name ("uhp"), which reads
    /// like the project or the orchestrator itself — disambiguate.
    var boardTitle: String {
        if let t = aiTitle, !t.isEmpty { return t }
        return "Untitled tab (\(displayName))"
    }

    /// Set when the orchestrator dispatched work to this tab fire-and-forget
    /// (or spawned it with a task). When the tab next finishes and goes
    /// quiet, it auto-notifies the orchestrator ONCE so the loop closes
    /// without anyone remembering to ask it to report back. Cleared on fire.
    var pendingOrchestratorReport: Bool = false

    /// One-line snapshot of what this tab last said — used for the
    /// orchestrator board and wake pings. Empty when nothing yet.
    var latestSnippet: String {
        let last = messages.last(where: { $0.role == .assistant })?.flatText ?? ""
        let oneLine = last
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
        return oneLine.count > 160 ? String(oneLine.prefix(160)) + "…" : oneLine
    }

    /// Permission prompt waiting on the user. Set by MCPRelay when
    /// claude's permission-prompt-tool fires; cleared when the user
    /// taps Allow or Deny in the picker. While non-nil, a banner sits
    /// above the composer with the request details.
    @Published var pendingPermission: PendingPermission?

    /// Name of an MCP server a tool result reported as needing
    /// authorization. While non-nil an authorize banner sits above the
    /// composer. Cleared on dismiss or when the server authenticates
    /// (AgentManager clears it on the auth-changed notification).
    @Published var pendingMCPAuthServer: String?

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

    /// Fires once whenever a turn resolves cleanly (`.result` without
    /// error). AgentManager subscribes to this to drive the orchestrator
    /// "watch & nudge" wake. Carries the assistant text from the turn that
    /// just ended (whatever the model said last).
    let turnCompleted = PassthroughSubject<String, Never>()

    /// True while AutoNamer is generating this tab's title — the tab row
    /// shows a spinner instead of the status-placeholder label.
    @Published var isAutoNaming: Bool = false

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
    /// The post-compaction seed brief, parked until the old persistent
    /// claude process is confirmed dead (`.processExited`). Delivering it
    /// synchronously raced the async `terminate()` and the seed was lost —
    /// see finishCompact / flushPendingCompactSeed.
    private var pendingCompactSeed: String?

    /// Set externally before connect() if we should resume a prior session id.
    var resumeSessionId: String?

    let bridge: ClaudeBridge
    private var bridgeCancellable: AnyCancellable?

    init(cwd: String, resumeSessionId: String? = nil, id: UUID = UUID()) {
        // Stable across restarts when restored from a snapshot — the
        // orchestrator holds tab ids in its conversation context, and
        // regenerating them on relaunch made every remembered id die
        // ("unknown agent_id") after any app restart.
        self.id = id
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
    private var compactWatchdog: DispatchWorkItem?

    func compact() {
        guard !isCompacting, status != .running, !bridge.isBusy else { return }
        isCompacting = true
        // Safety net: no matter what event is missed, the spinner can't
        // hang forever. 120s covers a big summary; then bail cleanly.
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isCompacting else { return }
            self.lastError = "Compaction timed out — kept the conversation. Try again."
            self.cancelCompact()
        }
        compactWatchdog = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 120, execute: work)
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
        // plumbing, not something the user typed. MUST bypass send():
        // its isCompacting guard (added so USER prompts hold until the
        // fresh session) would queue the summarise prompt itself and
        // deadlock the whole compaction — spinner forever, "Background
        // instruction" rows stuck in the strip. The guards above
        // (!running, !busy) make direct dispatch safe here.
        dispatch(PendingPrompt(text: summarisePrompt, images: [], visible: false))
    }

    /// Abort a compaction — banner Cancel, or a stuck phase. Queued
    /// prompts resume draining into the existing session.
    func cancelCompact() {
        guard isCompacting else { return }
        compactWatchdog?.cancel()
        compactWatchdog = nil
        compactCancellable?.cancel()
        compactCancellable = nil
        pendingCompactSeed = nil
        isCompacting = false
        if status == .running { bridge.cancel() }
        DispatchQueue.main.async { [weak self] in self?.drainQueueIfReady() }
    }

    @MainActor
    private func finishCompact(with summary: String) {
        let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        // If the summary came back empty or trivially short, bail out
        // rather than blow away the transcript for nothing. Surface as
        // an error so the user can retry. The floor scales with the
        // conversation: a long session summarized into a one-liner (a
        // real occurrence — 184 chars for a full working session) means
        // the summarizer under-delivered, and seeding it would silently
        // discard nearly everything.
        let floor = messages.count >= 30 ? 600 : 80
        guard trimmed.count > floor else {
            isCompacting = false
            lastError = "Compaction summary looked too thin (\(trimmed.count) chars) — kept the conversation. Try again."
            return
        }

        // Tear down the bridge and clear all session-id pointers so the
        // next send() spawns a brand-new claude process with no
        // `--resume` arg. The session_id from the new init event
        // overwrites `claudeSessionId` automatically.
        // NB: the bridge is NOT cancelled here — that happens after the seed
        // is stashed (below), so the `.processExited` the cancel triggers can
        // hand the seed to a guaranteed-fresh respawn.
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

        This is your restored context after compaction. Do NOT resume, continue, or take any action on prior work. Reply with a single short line confirming you're caught up, then stop and wait for my next instruction.
        """
        let charCount = trimmed.count
        let lineCount = trimmed.components(separatedBy: "\n").count
        let marker = "Conversation compacted — \(lineCount)-line brief (\(charCount.formatted()) chars) seeded to a fresh claude session."
        messages.append(
            Message(role: .system, blocks: [.text(id: UUID(), text: marker)])
        )
        isCompacting = false
        compactCancellable = nil
        // Defer the seed until the old persistent process is confirmed dead.
        // Sending synchronously here raced terminate(): ensureProcess saw the
        // still-"running" dying process and skipped the respawn, then the
        // just-nilled stdin made bridge.send bail — the seed vanished and the
        // reseeded session came up empty ("forgot everything"). Stash it; the
        // `.processExited` handler delivers it into a brand-new claude session
        // the instant the old one dies. The 1.5s timer is a safety net for the
        // rare case the process was already gone (no exit event will fire).
        pendingCompactSeed = seed
        intentionalInterrupt = true
        bridge.cancel()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.flushPendingCompactSeed()
        }
    }

    /// Deliver the parked post-compaction seed into a fresh claude session.
    /// Idempotent via the nil-check: called from both `.processExited` (the
    /// normal path, the moment the old process dies) and a safety-net timer.
    private func flushPendingCompactSeed() {
        guard let seed = pendingCompactSeed else { return }
        pendingCompactSeed = nil
        dispatch(PendingPrompt(text: seed, images: [], visible: false, isBoardWake: false))
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
    /// Resume a turn interrupted by an app restart. Sends an invisible
    /// nudge (no fake "Continue" bubble) so the resumed claude session
    /// keeps going with whatever it was mid-way through — the user never
    /// types "continue"/"try again" per tab.
    func continueAfterRestart() {
        send("[The ManyAgents app restarted and interrupted your previous turn. Continue exactly where you left off and finish the task you were working on. Do not restart it, re-summarize, or ask what to do — just carry on.]",
             visible: false)
    }

    func send(_ text: String, images: [Data] = [], visible: Bool = true,
              boardWake: Bool = false) {
        // Clear any waiting-for-net state — the user just hit send
        // again, so they're taking control back from the auto-resumer.
        awaitingNetworkResume = false
        let prompt = PendingPrompt(text: text, images: images, visible: visible,
                                   isBoardWake: boardWake)
        // isCompacting: a prompt sent mid-compaction must NOT dispatch —
        // the teardown window flips status to idle, so it raced the fresh
        // session's seed and "resumed" the old turn. Queue until seeded.
        if status == .running || bridge.isBusy || isCompacting {
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
        // Tag the assistant output of this turn if it's an automatic board-wake.
        currentTurnIsBoardWake = (prompt.isBoardWake == true)
        status = .running
        // Normally a fresh turn starts the timer now; but a force-send carries
        // the interrupted turn's start time so the timer continues unbroken.
        currentTurnStartedAt = carryOverTurnStart ?? Date()
        carryOverTurnStart = nil
        currentTurnOutputTokens = 0
        inflightTokenEstimate = 0
        currentPhase = "thinking"
        // Stash for the auto-resumer. Cleared on the next clean .result.
        lastSentPrompt = prompt
        // Wire MCP for all sessions so open_preview is available everywhere.
        // Coordinator sessions additionally get list_agents / send_to_agent
        // (those are filtered by MCPRelay based on isCoordinator).
        do {
            _ = try MCPRelay.shared.startIfNeeded()
            bridge.mcpConfigPath = try CoordinatorConfig.write(for: self)
        } catch {
            bridge.mcpConfigPath = nil
            if isCoordinator {
                lastError = "Coordinator setup failed: \(error.localizedDescription)"
            }
        }
        // Orchestrator: attach the accumulated board digest to whatever
        // is being sent (user message, dispatch reply prompt) — the
        // transcript shows only the typed text; claude gets both. This
        // replaces the timed board-wake turns: updates cost nothing
        // until a turn was happening anyway.
        var outgoingText = prompt.text
        if isCoordinator, prompt.visible, !pendingBoardUpdates.isEmpty {
            let digest = pendingBoardUpdates.joined(separator: "\n")
            pendingBoardUpdates.removeAll()
            outgoingText += """
            \n\n[Automatic board digest — activity on your other tabs since your last turn. Not from the user:
            \(digest)
            Use read_agent if anything needs a closer look; otherwise just answer the user.]
            """
        }
        // Kick the bridge off the main thread — process.run() + stdin
        // write was blocking SwiftUI rendering, so the "Thinking…"
        // indicator didn't appear until the spawn returned.
        let bridgeRef = bridge
        Task.detached(priority: .userInitiated) { [outgoingText] in
            bridgeRef.send(text: outgoingText, imagesPng: prompt.images)
        }
        armTurnStartWatchdog()
    }

    // MARK: - Turn-start watchdog

    /// Time of the last bridge event, any kind. Proof-of-life for the
    /// claude process; the watchdog compares against it.
    private var lastBridgeEventAt: Date = .distantPast
    private var turnStartWatchdog: DispatchWorkItem?
    /// One retry per dispatched prompt — a watchdog respawn that ALSO
    /// goes silent means something bigger than a dead pipe; surface an
    /// error instead of looping.
    private var watchdogRetried = false

    /// A prompt written to a dead or wedged process vanishes silently:
    /// `try? stdin.write` swallows broken pipes, and if the exit event
    /// was missed (app relaunch races, kill -9) nothing ever fires. If
    /// no bridge event lands within the grace window after dispatch,
    /// kill the process and re-send via `--resume` — the same recovery
    /// path the network auto-resumer uses.
    private func armTurnStartWatchdog() {
        turnStartWatchdog?.cancel()
        let dispatchedAt = Date()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.status == .running,
                  self.lastBridgeEventAt < dispatchedAt,
                  let prompt = self.lastSentPrompt else { return }
            if self.watchdogRetried {
                self.status = .error
                self.lastError = "The agent process isn't responding. Try sending again."
                return
            }
            self.watchdogRetried = true
            self.bridge.cancel()
            // Give the kill a beat to settle, then re-dispatch the same
            // prompt — dispatch() respawns the process with --resume.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self else { return }
                // Drop the duplicate transcript entry dispatch() would add.
                if prompt.visible, self.messages.last?.role == .user {
                    self.messages.removeLast()
                }
                self.dispatch(prompt)
            }
        }
        turnStartWatchdog = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: work)
    }

    /// Pop the next queued prompt (if any) and send it. Called whenever a
    /// turn finishes so the queue drains FIFO without further user action.
    private func drainQueueIfReady() {
        guard status != .running, !bridge.isBusy, !isCompacting,
              let next = pendingPrompts.first else { return }
        pendingPrompts.removeFirst()
        dispatch(next)
    }

    /// Allow the composer to surgically remove a queued item (e.g. an "X"
    /// on the queued-prompts strip).
    func removeQueued(id: UUID) {
        pendingPrompts.removeAll { $0.id == id }
    }

    /// Drag-and-drop reorder in the queued strip: move `movedId` so it
    /// fires before `targetId` (nil → last).
    func reorderQueued(movedId: UUID, before targetId: UUID?) {
        guard movedId != targetId,
              let idx = pendingPrompts.firstIndex(where: { $0.id == movedId }) else { return }
        let moving = pendingPrompts.remove(at: idx)
        if let targetId, let t = pendingPrompts.firstIndex(where: { $0.id == targetId }) {
            pendingPrompts.insert(moving, at: t)
        } else {
            pendingPrompts.append(moving)
        }
    }

    /// User picked an option from the AskUserQuestion picker. Interrupts the
    /// (auto-denied, dead-end) question turn and delivers the choice as the
    /// resumed session's next turn, so the agent actually receives it without
    /// a manual force-push. Multi-select callers pass the comma-joined labels.
    func answerQuestion(_ answer: String) {
        guard let q = pendingAskUserQuestion else { return }
        pendingAskUserQuestion = nil
        // Keep a record so the picker shows a "✓ <answer>" confirmation chip
        // (with the original question) until the next turn's output lands.
        answeredAsk = (state: q, answer: answer)
        // Durable record (keyed by tool_use id) so the transcript can render
        // a permanent card where the question was asked — survives the next
        // turn, unlike the transient chip above.
        answeredQuestions[q.toolUseId] = AnsweredAsk(state: q, answer: answer)
        // The CLI auto-denies AskUserQuestion in `--print` mode, but the turn
        // does NOT cleanly end — the process keeps running after the denial.
        // So a plain `send()` would queue the answer behind a turn that never
        // drains (the bug: "stuck on Thinking, answer sits in the queue until
        // I force-push"). Deliver it like a force-send instead: stage the
        // answer at the FRONT of the queue and interrupt the dead-end turn so
        // the resumed session — which still holds the question context — picks
        // the answer up immediately as its next turn. visible:false keeps it
        // out of the bubble flow; the chip + historical card stand in for it.
        let prompt = PendingPrompt(text: answer, images: [], visible: false)
        if status == .running || bridge.isBusy {
            pendingPrompts.insert(prompt, at: 0)
            intentionalInterrupt = true
            // Carry the interrupted turn's start + tokens so the timer/gauge
            // continue unbroken into the answer's turn (mirrors forceSend).
            carryOverTurnStart = currentTurnStartedAt
            carriedTurnTokens += currentTurnOutputTokens
            bridge.cancel()
        } else {
            // Turn already ended — just dispatch the answer now.
            dispatch(prompt)
        }
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
            // Carry the in-flight turn's start time AND token count into the
            // forced turn so the timer and token count continue across the
            // interrupt instead of snapping back to 0.
            carryOverTurnStart = currentTurnStartedAt
            carriedTurnTokens += currentTurnOutputTokens
            bridge.cancel()
        } else {
            // Idle path — just dispatch directly.
            pendingPrompts.removeFirst()
            dispatch(prompt)
        }
    }

    // MARK: - Stream event handling

    private func handle(_ event: BridgeEvent) {
        // Proof-of-life for the turn-start watchdog: ANY event means the
        // process is alive and the prompt landed. A clean lifecycle also
        // re-arms the one-retry budget.
        lastBridgeEventAt = Date()
        if case .result = event { watchdogRetried = false }
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
               messages[lastIdx].role == .assistant,
               messages[lastIdx].fromBoardWake == currentTurnIsBoardWake {
                messages[lastIdx].blocks.append(contentsOf: blocks)
            } else {
                messages.append(Message(role: .assistant, blocks: blocks,
                                        fromBoardWake: currentTurnIsBoardWake))
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
            // An MCP server just refused for lack of auth — raise the
            // banner above the composer so the user can't miss it. The
            // inline button under the tool result stays as a secondary
            // affordance; this is the primary one.
            if let server = MCPConnectors.authNeededServer(in: content) {
                pendingMCPAuthServer = server
            }
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
        case .toolResultImage(_, let data, let mediaType, _):
            // An image a tool returned (e.g. a screenshot the agent Read).
            // Render it inline as an image block.
            messages.append(Message(role: .system,
                                    blocks: [.image(id: UUID(), data: data, mediaType: mediaType)]))
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
            // Persist this turn to the usage history (Window > Usage).
            UsageLog.append(cwd: cwd,
                            inputTokens: usage?.inputTokens ?? 0,
                            outputTokens: usage?.outputTokens ?? 0,
                            costUsd: cost ?? 0,
                            model: model)
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
                // Tell AgentManager a clean turn just landed so the
                // orchestrator watch-&-nudge loop can wake. Only fires for
                // non-error completions so we don't nudge on a broken turn.
                completedTurns += 1
                turnCompleted.send(lastAssistantText)
            }
            currentTurnStartedAt = nil
            currentTurnIsBoardWake = false
            // The logical turn finished — clear any carried token base so the
            // next fresh turn starts its count from 0.
            carriedTurnTokens = 0
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
                if intentionalInterrupt {
                    status = .idle          // deliberate (force-send / compaction)
                } else {
                    // No .result landed and this wasn't a deliberate
                    // interrupt — the turn ended WITHOUT a response. Don't
                    // go silently idle (the "it just stops, I have to nudge
                    // again" bug); surface why. Most common cause is a
                    // usage/rate limit or a transient CLI error.
                    status = .error
                    lastError = exitCode == 0
                        ? "The turn ended without a response — usually a usage/rate limit or a transient hiccup. Send again to retry."
                        : "claude exited (\(exitCode)) without responding. Send again to retry."
                }
            }
            intentionalInterrupt = false
            // Mid-compaction reseed: the old process just died, so the bridge
            // will respawn clean. Deliver the seed as the new session's FIRST
            // message before draining anything the user queued meanwhile.
            if pendingCompactSeed != nil {
                flushPendingCompactSeed()
                return
            }
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
