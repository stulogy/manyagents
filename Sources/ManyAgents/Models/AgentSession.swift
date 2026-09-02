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

    /// The project this session belongs to for grouping and orchestrator
    /// routing: its own cwd, or the main repo when the cwd is a git worktree.
    /// Tabs spread across worktrees are one project — the same board, the
    /// same orchestrator — even though each lives in its own directory.
    var projectRoot: String { ProjectNaming.projectRoot(forCwd: cwd) }
    /// The repo this tab works in — a worktree resolves to the repo it was
    /// cut from. This is what the sidebar groups tabs by: six worktrees of
    /// one repo are six tabs of that repo, not six things beside it.
    var repoRoot: String { ProjectNaming.repoRoot(forCwd: cwd) }

    /// What this tab coordinates when it wears the orchestrator hat: the
    /// whole workspace when it sits at the workspace root, otherwise just its
    /// own repo. That's what makes a repo LEAD possible — `uhp` keeps the
    /// board that spans every repo, while a tab in `dev/UHP-OPS-Agent` can
    /// run that repo's tabs without either one stealing the other's hat.
    var boardScope: String { repoRoot == projectRoot ? projectRoot : repoRoot }

    /// True for a repo-level orchestrator: coordinates its own repo, not the
    /// workspace. Bounds what it can see and where it can spawn.
    var isRepoLead: Bool { isCoordinator && boardScope != projectRoot }

    /// Does this orchestrator's board include `other`?
    func coordinates(_ other: AgentSession) -> Bool {
        boardScope == projectRoot ? other.projectRoot == boardScope
                                  : other.repoRoot == boardScope
    }
    /// True when this tab sits in a worktree rather than the main repo.
    var isWorktree: Bool { projectRoot != cwd }
    /// True once the tab's directory has been deleted underneath it — a
    /// worktree cleanup does exactly that, and the tab can no longer run a
    /// single command from there. Closing it is the only useful action.
    var cwdMissing: Bool { !ProjectNaming.directoryExists(cwd) }
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
                emitTurnEnded()
            }
        }
    }

    /// Emits the terminal status each time the agent stops working. The
    /// manager subscribes to drive system notifications / sounds.
    let finishedWorking = PassthroughSubject<AgentStatus, Never>()

    /// Fires exactly once per turn END, whatever the outcome — clean result,
    /// error, empty response, dead process, or a deliberate interrupt.
    /// `turnCompleted` covers only the clean case, so anything that waits on
    /// that (the orchestrator's dispatch, the dispatched-tab auto-report) waits
    /// forever the moment a turn breaks. This is the signal to wait on.
    let turnEnded = PassthroughSubject<TurnEnd, Never>()

    struct TurnEnd {
        /// Id of the prompt whose turn just ended. Lets a waiter match the end
        /// to the exact prompt it sent instead of counting completions — a
        /// count drifts as soon as any intervening turn errors, because an
        /// errored turn never emits one.
        let promptId: UUID?
        let status: AgentStatus
        /// The assistant's closing text, or the error when the turn broke.
        let text: String
        /// True when the turn was deliberately cancelled (force-send, answered
        /// question, compaction) rather than ending under its own steam. A
        /// replacement turn is already on its way.
        let interrupted: Bool
    }

    /// The most recent turn end. Kept so a waiter that subscribes a beat after
    /// sending still sees the end it was waiting for instead of hanging.
    private(set) var lastTurnEnd: TurnEnd?

    /// Id of the prompt driving the in-flight turn, stamped onto its TurnEnd.
    private var currentPromptId: UUID?

    private func emitTurnEnded() {
        let text: String
        if status == .error {
            text = lastError ?? "The turn ended with an error."
        } else {
            text = messages.last(where: { $0.role == .assistant })?.flatText ?? ""
        }
        let end = TurnEnd(promptId: currentPromptId, status: status,
                          text: text, interrupted: intentionalInterrupt)
        currentPromptId = nil
        lastTurnEnd = end
        turnEnded.send(end)
    }
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

    /// The model this tab actually runs. Optimize Mode can downgrade it,
    /// but only for a tab an orchestrator spawned or dispatched —
    /// `reportToOrchestratorId` is the marker for that — and never for a
    /// tab wearing the hat itself: a workspace orchestrator or repo lead
    /// needs its real intelligence to coordinate. A tab the user opened and
    /// drives by hand (reportToOrchestratorId is nil) keeps whatever model
    /// they picked in Settings regardless of this toggle.
    /// Which model this tab runs on, relative to the user's settings.
    ///
    /// Optimize Mode used to be all-or-nothing: every tab an orchestrator
    /// spawned got the cheap model, whatever it had been asked to do. A tab
    /// told to build a net-new epic — data model, endpoints, an
    /// authorization contract, a test plan — ran on the same model as one
    /// told to rename some files. So the cheap model is now the DEFAULT for
    /// dispatched tabs, not the rule: the orchestrator can ask for the full
    /// model when it hands over heavy work (it is the thing that knows), and
    /// the user can move any tab either way from its menu.
    ///
    /// Deliberately not a model id. What "full" and "cheap" mean stays in
    /// Settings, so changing either there moves every tab that follows it.
    enum ModelTier: String, Codable {
        /// The app default, unless Optimize Mode downgrades dispatched tabs.
        case auto
        /// The app default, never downgraded.
        case full
        /// Optimize Mode's subagent model, even for an orchestrator.
        case cheap
    }

    @Published var modelTier: ModelTier = .auto

    var effectiveModel: String {
        let base = UserDefaults.standard.string(forKey: ClaudeBridge.Keys.model) ?? ""
        let cheap = OptimizeMode.subagentModel.isEmpty ? base : OptimizeMode.subagentModel
        switch modelTier {
        case .full:
            return base
        case .cheap:
            return cheap
        case .auto:
            guard OptimizeMode.enabled, !isCoordinator, reportToOrchestratorId != nil
            else { return base }
            return cheap
        }
    }

    /// Human-readable name of the model this tab will actually use.
    var effectiveModelLabel: String {
        let id = effectiveModel
        if id.isEmpty { return "Default" }
        return ClaudeBridge.availableModels.first { $0.id == id }?.label ?? id
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
        // Fable / Mythos 5 are 1M (and 1M is also their default).
        if m.contains("fable") || m.contains("mythos") { return 1_000_000 }
        // Opus 4.6 and everything after it defaults to 1M.
        if m.range(of: #"opus-4-[6-9]"#, options: .regularExpression) != nil {
            return 1_000_000
        }
        if m.range(of: #"opus-[5-9]"#, options: .regularExpression) != nil {
            return 1_000_000
        }
        // Same for Sonnet from 4.6 on — this was missing, so a Sonnet tab's
        // gauge read against 200K and hit 100% while barely a fifth full.
        if m.range(of: #"sonnet-4-[6-9]"#, options: .regularExpression) != nil {
            return 1_000_000
        }
        if m.range(of: #"sonnet-[5-9]"#, options: .regularExpression) != nil {
            return 1_000_000
        }
        // Haiku and anything older stay at 200K.
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
    /// Wire name of the tool running right now, "" when none. Drives the
    /// live indicator's badge — ManyAgents' own tools read as the app doing
    /// something, not as an outside plugin with a machine-shaped name.
    @Published var currentTool: String = ""
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
        /// True ONLY for the internal turn that produces a rolling-compact
        /// brief — see `startRollingCompact()`. Its reply must never reach
        /// the visible transcript, so `dispatch()` and `.assistantBlocks`
        /// key off this instead of appending it like any other turn.
        /// Optional for the same snapshot-decode reason as `isBoardWake`.
        var isRollingCompactSummary: Bool? = nil
        /// True ONLY for the turn that reseeds a fresh session with the
        /// brief. Its reply is suppressed too: the model has to say
        /// *something* to close the turn, but "caught up, ready when you
        /// are" arriving unprompted reads as the tab talking to itself.
        var isRollingCompactSeed: Bool? = nil
    }

    /// Set while a board-wake turn is dispatching, so the assistant messages it
    /// produces get tagged `fromBoardWake`. Cleared at turn end.
    private var currentTurnIsBoardWake = false
    /// True only for the internal rolling-compact summarize turn — see
    /// `startRollingCompact()`. Keeps `.assistantBlocks` from appending its
    /// reply to the visible transcript.
    private var currentTurnIsRollingCompactSummary = false
    /// True only for the reseed turn — see `flushPendingRollingCompactSeed()`.
    /// Its reply is dropped on the floor rather than appended.
    private var currentTurnIsRollingCompactSeed = false
    /// True while this tab is running an internal turn nobody asked for —
    /// a rolling compact's summarize or reseed. The transcript hides its
    /// working indicator for these: showing a tab as busy on housekeeping
    /// reads as a stall, and the whole point of the rolling pass is that it
    /// happens out of the way.
    @Published private(set) var isBackgroundTurn = false

    /// claude sessions this tab used BEFORE its current one, oldest first.
    ///
    /// A rolling compact starts a fresh claude session, which means a fresh
    /// transcript file. The visible thread doesn't restart, so restore has
    /// to read the chain, not just the tail of the newest file. Bounded:
    /// only enough history to fill the restore window is ever useful.
    var priorSessionIds: [String] = []

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
    @Published var isCoordinator: Bool = false {
        didSet {
            guard isCoordinator, isCoordinator != oldValue else { return }
            publishRelayConfig()
        }
    }

    /// Write this tab's MCP config drop now, without waiting for its next
    /// turn. The drop is how anything outside the app finds the current
    /// relay socket, its token, and which tab holds the orchestrator hat —
    /// the ma-bridge reads exactly that. Written only at first turn, an
    /// orchestrator restored at launch was invisible until someone typed
    /// at it, and every board call from outside was refused as
    /// "not the project's orchestrator".
    func publishRelayConfig() {
        do {
            _ = try MCPRelay.shared.startIfNeeded()
            _ = try CoordinatorConfig.write(for: self)
        } catch {
            // Non-fatal: the next turn writes it anyway.
        }
    }

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
    /// Prompts whose turn must NOT ping the orchestrator through the board
    /// digest — set on a TARGET tab when the orchestrator dispatches into it,
    /// since it gets that reply via the dispatch tool (or the auto-report).
    /// Keyed by prompt id, not by turn index: index arithmetic assumed every
    /// turn ahead of ours would complete cleanly, and one errored turn shifted
    /// the whole sequence so a real completion got swallowed.
    var suppressedPromptIds: Set<UUID> = []

    /// Name used on the orchestrator board and in digests. An unnamed
    /// tab's displayName is the bare project name ("uhp"), which reads
    /// like the project or the orchestrator itself — disambiguate.
    var boardTitle: String {
        if let t = aiTitle, !t.isEmpty { return t }
        return "Untitled tab (\(displayName))"
    }

    /// True once the CURRENT turn has produced any assistant output (text,
    /// thinking, or a tool call). Reset at dispatch. If a turn ends with
    /// this still false, the model returned nothing — surfaced as an error
    /// instead of silently going idle (the "it just does nothing" bug).
    private var turnProducedOutput = false
    /// Pending "empty response" verdict. A .result with no output isn't
    /// necessarily OUR turn failing — a Monitor/event wake turn's empty
    /// result can land ahead of the real turn for the prompt just sent.
    /// The verdict waits a few seconds; assistant output cancels it.
    private var emptyResultGrace: DispatchWorkItem?

    /// True once a message has been steered into the turn now in flight.
    /// The CLI may close that turn to go and run the steered message as a
    /// new one, and the closing `.result` can be empty or flagged as an
    /// error. That boundary is not the tab failing, so its verdict is held
    /// rather than flashed as a red error the user has to reason about.
    /// Cleared when a turn is dispatched or a verdict resolves.
    private var steeredIntoCurrentTurn = false

    /// Set when the CLI announces a turn we did not dispatch — proof that a
    /// real turn is starting, which retroactively explains an empty or
    /// errored result as a turn boundary rather than a failure.
    private var cliInitiatedTurnPending = false

    /// Bumped every time a turn starts, whether we dispatched it or the CLI
    /// did. A held verdict captures the value and fires only if no newer
    /// turn has begun since — so suppression can never outlive the boundary
    /// that justified it, and a genuine failure is reported a few seconds
    /// late rather than swallowed.
    private var turnEpoch: UInt64 = 0

    /// Set when the orchestrator dispatched work to this tab fire-and-forget
    /// (or spawned it with a task). When the tab next finishes and goes
    /// quiet, it auto-notifies the orchestrator ONCE so the loop closes
    /// without anyone remembering to ask it to report back. Cleared on fire.
    /// Fires on ANY turn end, including an errored one — a tab that broke is
    /// exactly what the orchestrator needs to hear about, and waiting for a
    /// clean completion that will never come is what left it hanging.
    var pendingOrchestratorReport: Bool = false

    /// Which orchestrator this tab answers to, recorded at dispatch time and
    /// kept for the tab's life. Routing by cwd alone silently found nobody
    /// whenever the worker sat somewhere other than the orchestrator's own
    /// directory — a subdir, a worktree, or a different repo entirely. It is
    /// deliberately NOT cleared once the tab's first auto-report lands: a tab
    /// dispatched into another repo was then orphaned, and every later
    /// notify_orchestrator call from it failed with "no orchestrator in this
    /// project" while the orchestrator sat waiting for a report.
    var reportToOrchestratorId: UUID?

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

    /// Fires once whenever a turn resolves cleanly (`.result` without error),
    /// carrying the assistant text from the turn that just ended. Drives
    /// compaction phase 2, which genuinely only cares about clean turns.
    /// Anything that must not miss a broken turn watches `turnEnded` instead.
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

    /// True while a ROLLING auto-compact is in flight — Optimize Mode's
    /// automatic counterpart to the button above. Same two-phase mechanism
    /// (summarize, then reseed a fresh claude session), but the VISIBLE
    /// transcript is never touched: `messages` keeps every prior line, so
    /// scrollback and find-in-conversation work across it exactly as
    /// before. Only the model's live context actually resets.
    @Published var isRollingCompacting: Bool = false
    private var rollingCompactCancellable: AnyCancellable?
    private var rollingCompactWatchdog: DispatchWorkItem?
    /// Parked the same way `pendingCompactSeed` is, for the same reason:
    /// delivering it before `.processExited` confirms the old process is
    /// dead races `terminate()` and the seed is lost.
    private var pendingRollingCompactSeed: String?
    /// Accumulates the summarize turn's reply directly from bridge events.
    /// That turn is never appended to `messages` (see `.assistantBlocks`),
    /// so `turnCompleted` can't read it back off the transcript the way the
    /// manual path does — this is its only record.
    private var rollingCompactSummaryBuffer = ""

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
        guard !isCompacting, !isRollingCompacting, status != .running, !bridge.isBusy else { return }
        isCompacting = true
        // Safety net: no matter what event is missed, the spinner can't
        // hang forever. 120s covers a big summary; then bail cleanly.
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isCompacting else { return }
            self.lastError = "Compaction timed out — kept the conversation. Try again."
            self.appendErrorNotice("Compaction timed out — kept the conversation. Try again.")
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
            appendErrorNotice("Compaction summary looked too thin (\(trimmed.count) chars) — kept the conversation. Try again.")
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
        // A manual compact deliberately wipes the transcript, so the chain
        // goes with it — otherwise the next relaunch would restore exactly
        // the history the user just asked to be rid of.
        priorSessionIds.removeAll()
        pendingPrompts.removeAll()
        pendingAskUserQuestion = nil
        answeredAsk = nil
        pendingPermission = nil
        lastTurnContextTokens = 0
        lastTurnContextWindow = nil
        currentTurnOutputTokens = 0
        inflightTokenEstimate = 0
        currentPhase = "thinking"
        currentTool = ""
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

    // MARK: - Rolling auto-compact (Optimize Mode + worker ceiling)

    /// Called at the same "a turn just ended cleanly" checkpoint that
    /// otherwise drains the queue. Starts a rolling compact when Optimize
    /// Mode is on and this tab has crossed the user's threshold; returns
    /// whether it did, so the caller skips its own queue drain (compacting
    /// holds queued prompts exactly the way manual `compact()` does).
    ///
    /// Refuses whenever the user (or the model) is mid-interaction with
    /// THIS tab specifically — an unanswered question, a permission prompt,
    /// a pending MCP auth, a network-resume wait — since tearing down the
    /// context those refer to would erase what they're about.
    /// Pending "is this tab quiet enough to compact yet?" check.
    private var rollingCompactDelay: DispatchWorkItem?

    /// Wait for the tab to actually go quiet before compacting it.
    ///
    /// This used to fire the instant a turn ended, which is the moment the
    /// user is most likely to be typing their next message — so background
    /// housekeeping kept landing in the foreground. A few seconds of real
    /// idle first, and anything the user does meanwhile cancels it.
    private func scheduleRollingCompactCheck() {
        rollingCompactDelay?.cancel()
        // Optimize Mode compacts every tab early to save money; the ceiling
        // net compacts a worker late to keep it alive. Either one being in
        // play is reason enough to look.
        guard OptimizeMode.enabled || !isCoordinator else { return }
        let work = DispatchWorkItem { [weak self] in self?.rollingCompactIfNeeded() }
        rollingCompactDelay = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
    }

    /// What fraction of the window triggers a background compact for THIS
    /// tab, or nil when it shouldn't compact on its own at all.
    ///
    /// Optimize Mode's threshold wins when it's on, since it's both lower
    /// and the setting the user chose. With it off, a worker still gets the
    /// ceiling net so it never hits the CLI's own mid-turn compaction.
    private var backgroundCompactThreshold: Double? {
        if OptimizeMode.enabled { return OptimizeMode.autoCompactThreshold }
        return isCoordinator ? nil : OptimizeMode.workerCeilingThreshold
    }

    @discardableResult
    private func rollingCompactIfNeeded() -> Bool {
        guard let threshold = backgroundCompactThreshold,
              pendingPrompts.isEmpty,
              !isCompacting, !isRollingCompacting,
              pendingAskUserQuestion == nil, pendingPermission == nil,
              pendingMCPAuthServer == nil, !awaitingNetworkResume,
              status != .running, !bridge.isBusy,
              lastTurnContextWindow != nil, lastTurnContextTokens > 0
        else { return false }
        let pct = Double(lastTurnContextTokens) / Double(contextWindowTokens)
        guard pct >= threshold else { return false }
        startRollingCompact()
        return true
    }

    private func startRollingCompact() {
        isRollingCompacting = true
        rollingCompactSummaryBuffer = ""
        // Same safety net as manual compact: nothing can hang forever.
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isRollingCompacting else { return }
            // Silent give-up — this is background housekeeping the user
            // never asked for, so it just leaves the tab on its current
            // (larger) context rather than surfacing an error.
            self.cancelRollingCompact()
        }
        rollingCompactWatchdog = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 120, execute: work)
        rollingCompactCancellable = turnCompleted
            .prefix(1)
            .sink { [weak self] summary in
                Task { @MainActor [weak self] in
                    self?.finishRollingCompact(with: summary)
                }
            }
        let summarisePrompt = """
        [Automatic context compaction — internal housekeeping, not from the user.] Produce ONLY a \
        self-contained brief capturing everything important so far, so you can keep working without \
        the earlier scrollback. Include:
        - Identity & scope (who, what, where).
        - Key decisions reached, with the reasoning behind each.
        - Files / paths / commands touched, with their current state.
        - In-flight work and where things stand (next concrete step).
        - Open questions, unresolved disagreements, anything waiting on someone else.
        - Anything brittle that would otherwise need re-discovering the hard way.
        Format as clean Markdown with section headings. No preamble, no "here's a summary" sentence — \
        just the brief itself.
        """
        // Bypasses send()'s queue — safe because rollingCompactIfNeeded()
        // only calls this when status/bridge are already confirmed idle.
        // Never appended to the transcript: `isRollingCompactSummary`
        // routes its reply into `rollingCompactSummaryBuffer` instead (see
        // `.assistantBlocks`), which is the whole point of this path over
        // the manual one — the user should never see this turn happen.
        dispatch(PendingPrompt(text: summarisePrompt, images: [], visible: false,
                              isRollingCompactSummary: true))
    }

    /// Abort a rolling compact mid-flight. Not user-facing today (nothing
    /// calls it yet), kept for parity with `cancelCompact()` and as the
    /// natural hook if a cancel affordance gets added to the banner later.
    func cancelRollingCompact() {
        guard isRollingCompacting else { return }
        rollingCompactWatchdog?.cancel()
        rollingCompactWatchdog = nil
        rollingCompactCancellable?.cancel()
        rollingCompactCancellable = nil
        pendingRollingCompactSeed = nil
        isRollingCompacting = false
        // The summarize turn is about to be killed. Mark it deliberate, or
        // `.processExited` scores it as a turn that ended without a response
        // and writes a red error row — for a background pass the user never
        // asked for and does not need to hear about.
        currentTurnIsRollingCompactSummary = false
        currentTurnIsRollingCompactSeed = false
        isBackgroundTurn = false
        if status == .running {
            intentionalInterrupt = true
            bridge.cancel()
        }
        DispatchQueue.main.async { [weak self] in self?.drainQueueIfReady() }
    }

    @MainActor
    private func finishRollingCompact(with summary: String) {
        let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        // Same under-delivery floor as manual compact. Abandon quietly
        // rather than erroring — the user never asked for this pass, so a
        // red notice about it would be pure surprise. The tab just carries
        // its current (larger) context into the next turn.
        let floor = messages.count >= 30 ? 600 : 80
        guard trimmed.count > floor else {
            isRollingCompacting = false
            rollingCompactCancellable = nil
            rollingCompactWatchdog?.cancel()
            rollingCompactWatchdog = nil
            return
        }

        // Remember the session we're leaving, so a relaunch can stitch its
        // transcript back onto the front of this tab's history.
        if let outgoing = claudeSessionId ?? resumeSessionId, !outgoing.isEmpty {
            priorSessionIds.append(outgoing)
            if priorSessionIds.count > 4 {
                priorSessionIds.removeFirst(priorSessionIds.count - 4)
            }
        }
        // Reset the model's live session exactly like manual compact does.
        bridge.currentSessionId = nil
        resumeSessionId = nil
        claudeSessionId = nil
        lastTurnContextTokens = 0
        lastTurnContextWindow = nil
        currentTurnOutputTokens = 0
        inflightTokenEstimate = 0
        currentPhase = "thinking"
        currentTool = ""

        // UNLIKE manual compact: `messages` is untouched. Every prior line
        // stays exactly where it is — scrollable, searchable — and this
        // marker just records that the model's working context reset here.
        let marker = "Context compacted in the background — scrollback above is unaffected."
        messages.append(Message(role: .system, blocks: [.text(id: UUID(), text: marker)]))

        isRollingCompacting = false
        rollingCompactCancellable = nil
        rollingCompactWatchdog?.cancel()
        rollingCompactWatchdog = nil

        let seed = """
        [Context auto-compacted — internal, not from the user.] The brief below is your ONLY memory \
        of everything before this point — it already covers what matters, so don't re-derive or \
        re-explain it. This is housekeeping, not a message from anyone: reply with the single word \
        "ok" and nothing else, then stop and wait. Do not greet, summarize, restate the brief, or \
        announce that you are caught up.

        \(trimmed)
        """
        pendingRollingCompactSeed = seed
        intentionalInterrupt = true
        bridge.cancel()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.flushPendingRollingCompactSeed()
        }
    }

    private func flushPendingRollingCompactSeed() {
        guard let seed = pendingRollingCompactSeed else { return }
        pendingRollingCompactSeed = nil
        dispatch(PendingPrompt(text: seed, images: [], visible: false, isBoardWake: false,
                              isRollingCompactSeed: true))
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

    /// Returns the id of the prompt, so a caller (the orchestrator relay) can
    /// wait for the end of the turn THIS prompt causes, whether it runs now or
    /// drains out of the queue later.
    @discardableResult
    func send(_ text: String, images: [Data] = [], visible: Bool = true,
              boardWake: Bool = false) -> UUID {
        // Clear any waiting-for-net state — the user just hit send
        // again, so they're taking control back from the auto-resumer.
        awaitingNetworkResume = false
        // A message always beats background housekeeping. A rolling compact
        // is work nobody asked for, so abandon it rather than parking the
        // message behind it — the threshold simply triggers another one after
        // some later turn. (`deliverInterrupting` and `deliverNow` both fall
        // through to here while compacting, so this covers those too.)
        rollingCompactDelay?.cancel()
        if isRollingCompacting { cancelRollingCompact() }
        let prompt = PendingPrompt(text: text, images: images, visible: visible,
                                   isBoardWake: boardWake)
        // isCompacting: a prompt sent mid-compaction must NOT dispatch —
        // the teardown window flips status to idle, so it raced the fresh
        // session's seed and "resumed" the old turn. Queue until seeded.
        if status == .running || bridge.isBusy || isCompacting || isRollingCompacting {
            pendingPrompts.append(prompt)
            return prompt.id
        }
        dispatch(prompt)
        return prompt.id
    }

    /// Fires whenever a message is steered into this session's RUNNING turn.
    /// A relay call blocked on this session's behalf (the orchestrator sitting
    /// in a wait_for_result dispatch) watches it to bail out early — the model
    /// only reads the steered message once its current tool call returns, so
    /// staying blocked would keep it deaf to a message already in its context.
    let interjectionDelivered = PassthroughSubject<Void, Never>()

    /// Deliver a message into this session NOW: if a turn is running, steer
    /// it into the live turn over stdin — the model reads it at its next
    /// step, same mechanism as the user's force-send — otherwise send
    /// normally. Used for worker pings so a busy orchestrator isn't deaf
    /// until its (possibly long) turn ends.
    func deliverInterjection(_ text: String) {
        _ = deliverNow(text)
    }

    /// Hard-interrupting delivery, for a control message that cannot wait for
    /// the current tool call to return ("STAND DOWN", "stop pushing"). Steering
    /// is not enough here: a tab inside a long build or CI-watch command doesn't
    /// reach a step boundary for minutes, so the message goes unread while it
    /// keeps doing the very thing it was told to stop. Kills the in-flight turn
    /// and delivers the message as the next one, ahead of anything queued —
    /// same mechanism as the user's force-send. Returns the prompt id whose
    /// turn will carry it.
    @discardableResult
    func deliverInterrupting(_ text: String) -> UUID {
        // Nothing to interrupt (idle), or a compaction teardown in progress
        // (manual OR rolling) where a direct dispatch would race the
        // reseed: normal path. Killing the internal rolling-compact
        // summarize turn specifically would corrupt that whole flow —
        // there's no seed parked yet for it to hand off to.
        guard status == .running || bridge.isBusy, !isCompacting, !isRollingCompacting else {
            return send(text)
        }
        let prompt = PendingPrompt(text: text, images: [], visible: true)
        // Staged at the FRONT so `.processExited` → drainQueueIfReady dispatches
        // it as the very next turn (which is what appends its transcript row).
        pendingPrompts.insert(prompt, at: 0)
        // Deliberate kill: the turn end must not be scored as a failure, and a
        // replacement turn is already staged.
        intentionalInterrupt = true
        // Carry the killed turn's timing so the UI doesn't snap back to zero.
        carryOverTurnStart = currentTurnStartedAt
        carriedTurnTokens += currentTurnOutputTokens
        bridge.cancel()
        return prompt.id
    }

    /// Immediate delivery with enough back-channel for a waiter: steers into
    /// a running turn when there is one, otherwise sends normally. Returns the
    /// id of the prompt whose TurnEnd covers this delivery — the LIVE turn's
    /// id when steered (nil if that turn is CLI-initiated and has no app-side
    /// id), or the fresh prompt's id — plus whether it was steered.
    func deliverNow(_ text: String) -> (coveringPromptId: UUID?, steered: Bool) {
        if status == .running || bridge.isBusy, !isCompacting, !isRollingCompacting,
           bridge.steer(text: text, imagesPng: []) {
            messages.append(Message(role: .user, blocks: [.text(id: UUID(), text: text)]))
            steeredIntoCurrentTurn = true
            interjectionDelivered.send()
            return (currentPromptId, true)
        }
        return (send(text), false)
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
        currentTurnIsRollingCompactSummary = (prompt.isRollingCompactSummary == true)
        currentTurnIsRollingCompactSeed = (prompt.isRollingCompactSeed == true)
        isBackgroundTurn = currentTurnIsRollingCompactSummary || currentTurnIsRollingCompactSeed
        // Stamped onto this turn's TurnEnd so a waiter can match end to prompt.
        currentPromptId = prompt.id
        // A fresh turn is never pre-interrupted. Normally `.processExited`
        // clears this, but if a cancel() finds no live process that event never
        // lands — and a stuck flag would mark the next real turn end as
        // "interrupted" and swallow its report.
        intentionalInterrupt = false
        status = .running
        // Normally a fresh turn starts the timer now; but a force-send carries
        // the interrupted turn's start time so the timer continues unbroken.
        currentTurnStartedAt = carryOverTurnStart ?? Date()
        carryOverTurnStart = nil
        currentTurnOutputTokens = 0
        inflightTokenEstimate = 0
        currentPhase = "thinking"
        currentTool = ""
        turnProducedOutput = false
        // A stale empty-response verdict must not fire into this new turn,
        // and neither flag may leak across a turn boundary — a suppressed
        // verdict on one turn must not silence a real failure on the next.
        emptyResultGrace?.cancel()
        emptyResultGrace = nil
        steeredIntoCurrentTurn = false
        cliInitiatedTurnPending = false
        turnEpoch &+= 1
        // Stash for the auto-resumer. Cleared on the next clean .result.
        lastSentPrompt = prompt
        // Wire MCP for all sessions so open_preview is available everywhere.
        // Coordinator sessions additionally get the board tools: the config
        // carries a --coordinator flag (gates the stdio server's tool list),
        // MCPRelay hard-rejects board ops from non-coordinators, and the
        // bridge picks the coordinator vs worker system prompt off the flag.
        bridge.isCoordinator = isCoordinator
        bridge.isRepoLead = isRepoLead
        bridge.modelOverride = effectiveModel
        do {
            _ = try MCPRelay.shared.startIfNeeded()
            bridge.mcpConfigPath = try CoordinatorConfig.write(for: self)
        } catch {
            bridge.mcpConfigPath = nil
            if isCoordinator {
                lastError = "Coordinator setup failed: \(error.localizedDescription)"
                appendErrorNotice("Coordinator setup failed: \(error.localizedDescription)")
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
                self.reportTurnError("The agent process isn't responding. Try sending again.")
                return
            }
            self.watchdogRetried = true
            // Deliberate kill: mark it so `.processExited` doesn't score the
            // respawn as a failed turn and report a phantom error to the
            // orchestrator seconds before the retry actually runs.
            self.intentionalInterrupt = true
            self.bridge.cancel()
            // Give the kill a beat to settle, then re-dispatch the same
            // prompt — dispatch() respawns the process with --resume.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self else { return }
                // Drop the duplicate transcript entry dispatch() would add.
                // Walk back to the last USER row (an error notice may sit
                // after it now) and only remove an actual match — checking
                // just messages.last left a duplicate bubble behind the
                // error row.
                if prompt.visible,
                   let idx = self.messages.lastIndex(where: { $0.role == .user }),
                   self.messages[idx].flatText == prompt.text {
                    self.messages.remove(at: idx)
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
        guard status != .running, !bridge.isBusy, !isCompacting, !isRollingCompacting,
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
        // Whatever turn is running right now (if any) is the internal
        // rolling-compact summarize turn. Steering a real message into it
        // would corrupt that exchange, and waiting for it defeats the point
        // of a force-send, so drop the compact and let the prompt go as soon
        // as the process is down.
        if isRollingCompacting {
            cancelRollingCompact()
            pendingPrompts.insert(prompt, at: 0)
            return
        }
        if status == .running || bridge.isBusy {
            // Steer, Claude Code-style: inject the message into the RUNNING
            // turn over the held-open stdin (supported by the CLI in
            // stream-json mode — verified on 2.1.234: the model sees it at
            // its next boundary, same turn, single result). No cancel, no
            // "tool use was rejected" carnage — claude decides what
            // attention to give it, exactly like typing mid-turn in the
            // Claude Code terminal.
            if bridge.steer(text: prompt.text, imagesPng: prompt.images) {
                steeredIntoCurrentTurn = true
                if prompt.visible {
                    var blocks: [ContentBlock] = []
                    if !prompt.text.isEmpty {
                        blocks.append(.text(id: UUID(), text: prompt.text))
                    }
                    for img in prompt.images {
                        blocks.append(.image(id: UUID(), data: img, mediaType: "image/png"))
                    }
                    messages.append(Message(role: .user, blocks: blocks))
                }
                return
            }
            // No live process to steer (stale busy state) — fall back to the
            // interrupt path: terminate; .processExited triggers
            // drainQueueIfReady which pops our prompt from the front.
            pendingPrompts.insert(prompt, at: 0)
            intentionalInterrupt = true
            // Carry the in-flight turn's start time AND token count into the
            // forced turn so the timer and token count continue across the
            // interrupt instead of snapping back to 0.
            carryOverTurnStart = currentTurnStartedAt
            carriedTurnTokens += currentTurnOutputTokens
            bridge.cancel()
        } else {
            // Idle path — just dispatch directly.
            dispatch(prompt)
        }
    }

    // MARK: - Stream event handling

    private func handle(_ event: BridgeEvent) {
        // Proof-of-life for the turn-start watchdog: a real turn event means
        // the process is alive and the prompt landed. A .systemError does NOT
        // count — a rejected or failed send emits one, and letting it bump the
        // clock would fool the watchdog into thinking the prompt landed and
        // leave a dropped prompt stuck forever. A clean lifecycle also re-arms
        // the one-retry budget.
        if case .systemError = event {} else { lastBridgeEventAt = Date() }
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
            turnProducedOutput = true
            // Real output arrived — any pending "empty response" verdict was
            // a wake-turn result racing ahead of this turn. Stand down.
            emptyResultGrace?.cancel()
            emptyResultGrace = nil
            if currentTurnIsRollingCompactSummary {
                // Internal turn — its reply must never reach the visible
                // transcript. Capture it directly since `turnCompleted`
                // (below, in `.result`) can't read it back off `messages`
                // the way the manual compact path does.
                for block in blocks {
                    if case .text(_, let t) = block { rollingCompactSummaryBuffer += t }
                }
            }
            else if currentTurnIsRollingCompactSeed {
                // The reseed turn's acknowledgement. Dropped entirely — the
                // grey marker row already said the compaction happened, and
                // that is all the user needs to see of it.
            }
            // Either append to an in-progress assistant message or start a
            // new one. The CLI emits each assistant *message* as a single
            // event (not per-delta) when streaming is off.
            else if let lastIdx = messages.indices.last,
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
                    currentPhase = ToolNaming.phase(for: name)
                    currentTool = name
                case .text:
                    currentPhase = "writing"
                    currentTool = ""
                case .thinking:
                    currentPhase = "thinking"
                    currentTool = ""
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
            // A steered message can make the CLI close the turn it's in and
            // run the steered text as a fresh one. The closing result comes
            // back empty, or flagged as an error with no detail, and the tab
            // then carries on perfectly well — so the red notice was pure
            // noise arriving on every orchestrator message.
            let atSteerBoundary = steeredIntoCurrentTurn || cliInitiatedTurnPending
            if isError, !atSteerBoundary {
                reportTurnError(resultText ?? "The turn ended with an error.")
                // If we lost the network, flag for auto-resume rather
                // than asking the user to retype the prompt. The manager
                // re-dispatches lastSentPrompt as soon as the path goes
                // satisfied again.
                if !NetworkMonitor.shared.isOnline {
                    awaitingNetworkResume = true
                }
            } else if isError || !turnProducedOutput {
                // The turn completed but the model produced NOTHING (no
                // text, no tool call). Either a transient glitch — or NOT
                // our turn at all: a Monitor/event wake turn's empty result
                // landing ahead of the real turn for the prompt just sent
                // (the false "empty response, then it ran anyway" alarm).
                // Hold the verdict briefly; assistant output cancels it.
                // If it fires, surface the error so the user knows to retry
                // — lastSentPrompt stays set so a resend is one action.
                let verdict = isError
                    ? (resultText ?? "The turn ended with an error.")
                    : "The model returned an empty response. Send again to retry."
                scheduleEmptyVerdict(verdict, epoch: turnEpoch)
                // Leave the turn formally in flight (status stays .running,
                // no queue drain) until the verdict lands one way or the other.
                return
            } else if currentTurnIsRollingCompactSummary {
                // The internal summarize turn never touches `messages`, so
                // there's no assistant prose here to read the "waiting on
                // you" cue from — and it would be meaningless on this text
                // anyway. Always idle; `finishRollingCompact` takes it from
                // here via the `turnCompleted` subscription below.
                status = .idle
                lastSentPrompt = nil
                awaitingNetworkResume = false
                turnCompleted.send(rollingCompactSummaryBuffer)
            } else if currentTurnIsRollingCompactSeed {
                // Reseed done. Idle, silently — deliberately NOT published on
                // `turnCompleted`: subscribers there (the orchestrator report
                // path) would read an internal acknowledgement as the tab
                // having finished real work.
                status = .idle
                lastSentPrompt = nil
                awaitingNetworkResume = false
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
                turnCompleted.send(lastAssistantText)
            }
            currentTurnStartedAt = nil
            currentTurnIsBoardWake = false
            currentTurnIsRollingCompactSeed = false
            isBackgroundTurn = false
            // The logical turn finished — clear any carried token base so the
            // next fresh turn starts its count from 0.
            carriedTurnTokens = 0
            // Hand off to the next queued prompt on the next runloop tick so
            // any UI bound to .result has settled before the new turn flips
            // status back to .running.
            //
            // But NOT while a deliberate interrupt is pending. On a force-send
            // (or stop / answer / compact) we cancel() the running turn, and
            // its .processExited is the single authoritative drain point. If
            // claude's .result for the dying turn races ahead of that exit,
            // draining here too pops a SECOND queued prompt and interleaves it
            // — the "force-push also sent the message queued under it, out of
            // order" bug. Let .processExited do the one drain.
            if !intentionalInterrupt {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.drainQueueIfReady()
                    self.scheduleRollingCompactCheck()
                }
            }
        case .partialBlockKind(let kind):
            // Earliest-possible "what is claude doing right now" signal.
            // Stops the indicator from sitting on a rotating whimsy verb
            // during long extended-thinking stretches that never produce
            // a completed assistant message.
            currentPhase = kind
        case .partialToolName(let name):
            currentTool = name
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
                    reportTurnError(exitCode == 0
                        ? "The turn ended without a response — usually a usage/rate limit or a transient hiccup. Send again to retry."
                        : "claude exited (\(exitCode)) without responding. Send again to retry.")
                }
            }
            intentionalInterrupt = false
            isBackgroundTurn = false
            // Mid-compaction reseed: the old process just died, so the bridge
            // will respawn clean. Deliver the seed as the new session's FIRST
            // message before draining anything the user queued meanwhile.
            if pendingCompactSeed != nil {
                flushPendingCompactSeed()
                return
            }
            if pendingRollingCompactSeed != nil {
                flushPendingRollingCompactSeed()
                return
            }
            // Whether the previous turn succeeded, errored, or was cancelled,
            // drain the next queued prompt.
            DispatchQueue.main.async { [weak self] in self?.drainQueueIfReady() }
        case .systemError(let message):
            reportTurnError(message)
        case .harnessNotice(let notice):
            // Muted one-liner: "a background agent finished". The report
            // itself belongs to the model, not the transcript. Skip the
            // append if the same notice is already the last row — the same
            // task can notify more than once.
            if case .system = messages.last?.role,
               messages.last?.flatText == notice {
                break
            }
            messages.append(Message(role: .system,
                                    blocks: [.text(id: UUID(), text: notice)]))
        case .userTurnBegan:
            // The CLI began a turn — possibly one IT initiated (a steered
            // message that missed its window, queued and run after the
            // current turn ended). Reflect it so the tab shows running,
            // new sends queue app-side instead of racing into the CLI's
            // queue, and the watchdog gets proof of life. Idempotent for
            // turns we dispatched ourselves.
            // A turn beginning is proof the process is alive and that any
            // pending "empty response" verdict belongs to the boundary the
            // steered message created. Cancel it — the 5s grace was losing
            // the race against a steered turn that thinks for 6s before its
            // first output, which is what put a red error above "Thinking…".
            emptyResultGrace?.cancel()
            emptyResultGrace = nil
            cliInitiatedTurnPending = true
            steeredIntoCurrentTurn = false
            turnEpoch &+= 1
            if status != .running {
                // A fresh turn has produced nothing yet — without this reset
                // the previous turn's output would mask a genuinely empty one.
                turnProducedOutput = false
                status = .running
                currentPhase = "thinking"
        currentTool = ""
                if currentTurnStartedAt == nil {
                    currentTurnStartedAt = Date()
                }
            }
        }
    }

    /// Hold an "empty response" / "turn errored" verdict until the process has
    /// been SILENT for the grace window, not merely until a timer expires.
    ///
    /// A plain timer was wrong twice over: an empty result can arrive while the
    /// model is still working, and a long thinking phase produces streaming
    /// events but no assistant block — so the old 5s deadline kept firing
    /// underneath a turn that then thought for 6, 8 seconds and answered
    /// perfectly well. Any bridge event proves the process is alive, so re-arm
    /// instead of accusing it. Genuine silence still reports, a few seconds
    /// later than before; a turn that produced output, or a newer turn
    /// (`epoch`), cancels the verdict outright.
    private func scheduleEmptyVerdict(_ message: String, epoch: UInt64) {
        let armedAt = Date()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.emptyResultGrace != nil else { return }
            self.emptyResultGrace = nil
            guard self.turnEpoch == epoch, !self.turnProducedOutput,
                  self.status == .running else { return }
            if self.lastBridgeEventAt > armedAt {
                self.scheduleEmptyVerdict(message, epoch: epoch)
                return
            }
            self.steeredIntoCurrentTurn = false
            self.reportTurnError(message)
            self.currentTurnStartedAt = nil
            self.currentTurnIsBoardWake = false
            self.carriedTurnTokens = 0
            if !self.intentionalInterrupt {
                DispatchQueue.main.async { [weak self] in self?.drainQueueIfReady() }
            }
        }
        emptyResultGrace?.cancel()
        emptyResultGrace = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
    }

    /// Surface a turn-level error on the session (red dot, lastError) AND in
    /// the transcript — a red dot with no visible message left the user
    /// guessing what broke. lastError is set BEFORE status: setting status
    /// fires the turn-end signal synchronously, and the orchestrator report
    /// reads the error off the session.
    private func reportTurnError(_ message: String) {
        lastError = message
        appendErrorNotice(message)
        status = .error
    }

    /// Red "⚠" notice row in the transcript. MessageView keys on the prefix
    /// to style system text as an error.
    func appendErrorNotice(_ message: String) {
        messages.append(Message(role: .system,
                                blocks: [.text(id: UUID(), text: "⚠ \(message)")]))
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
