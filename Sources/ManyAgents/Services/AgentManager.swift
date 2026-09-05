import Foundation
import Combine
import AppKit

/// Top-level state container. Owns every active AgentSession and persists
/// enough state to restore conversations across launches via `--resume`.
@MainActor
final class AgentManager: ObservableObject {
    @Published private(set) var sessions: [AgentSession] = []
    @Published var activeSessionId: UUID? {
        didSet {
            // Remember the last tab viewed in each project so switching back
            // to a project returns to where you were, not the last tab in
            // the list.
            // Keyed by repoRoot, which is what `projects` groups by and
            // what `activate(project:)` looks up. It used to store under
            // the TAB's own cwd, so any tab in a subdirectory or a worktree
            // was filed under a key nothing ever read — the lookup missed
            // every time and fell through to "the last tab in the list",
            // which is what switching projects always landed on.
            if let id = activeSessionId, let s = sessions.first(where: { $0.id == id }) {
                lastActiveTabPerProject[s.repoRoot] = id
            }
        }
    }
    /// repoRoot → last-active tab id, for per-project tab memory. Runtime
    /// only: which tab you were reading is not worth persisting across a
    /// relaunch, where every tab is equally cold.
    private var lastActiveTabPerProject: [String: UUID] = [:]

    // MARK: - Preview panel
    /// Preview URLs keyed by REPO root. A repo runs one dev server, and the
    /// tab that started it is rarely the tab you're reading — keying by tab
    /// meant the Preview Server tab held :3060 privately while every sibling
    /// tab in the same repo showed an empty panel. Set by the open_preview
    /// MCP tool, by the localhost pill in a message, and by the URL bar.
    @Published var previewURLs: [String: URL] = [:]
    /// Checkouts whose preview panel is showing instead of the
    /// conversation. Was a single app-wide flag, which meant opening the
    /// browser for one project blanked the transcript in every other.
    @Published var previewScopes: Set<String> = []

    /// Whether the preview is showing for the tab on screen right now.
    var previewActive: Bool {
        get { activePreviewScope.map { previewScopes.contains($0) } ?? false }
        set {
            guard let scope = activePreviewScope else { return }
            if newValue { previewScopes.insert(scope) } else { previewScopes.remove(scope) }
        }
    }

    /// The preview URL for the active tab's checkout, if any. Keyed by
    /// checkout rather than repo so two worktrees, each with its own dev
    /// server on its own port, don't overwrite each other's page.
    var activePreviewURL: URL? {
        guard let s = activeSession else { return nil }
        return previewURLs[s.previewScope]
    }

    /// Which checkouts currently have the preview showing instead of the
    /// conversation. Per-scope, so opening the browser in one project
    /// doesn't hide the transcript in another.
    var activePreviewScope: String? { activeSession?.previewScope }


    // MARK: - Attention log

    /// Questions asked of the user, oldest kept until answered. Persisted:
    /// the entire point is that a question survives you not noticing it,
    /// which includes not noticing it before a relaunch.
    @Published var attentionLog: [AttentionEntry] = [] {
        didSet { saveAttentionLog() }
    }

    private static let attentionKey = "manyagents.attention.v1"

    func loadAttentionLog() {
        guard let data = UserDefaults.standard.data(forKey: Self.attentionKey),
              let saved = try? JSONDecoder().decode([AttentionEntry].self, from: data)
        else { return }
        // Keep open items indefinitely; drop resolved ones after a week so
        // the store can't grow forever.
        let cutoff = Date().addingTimeInterval(-7 * 24 * 3600)
        attentionLog = saved.filter { $0.isOpen || ($0.resolvedAt ?? .distantPast) > cutoff }
    }

    private func saveAttentionLog() {
        guard let data = try? JSONEncoder().encode(attentionLog) else { return }
        UserDefaults.standard.set(data, forKey: Self.attentionKey)
    }

    /// Open entries, most pressing first.
    var openAttention: [AttentionEntry] {
        attentionLog.filter(\.isOpen).sorted(by: AttentionEntry.sortsBefore)
    }

    /// Tool calls and sign-ins blocking a tab right now — derived, not
    /// logged, because they vanish the moment they're answered.
    var liveBlockers: [LiveBlocker] {
        sessions.compactMap { s in
            let project = ProjectNaming.name(forCwd: s.projectRoot)
            let label = s.aiTitle ?? s.displayName
            if let p = s.pendingPermission {
                return LiveBlocker(id: "\(s.id)-perm", sessionId: s.id, tabLabel: label,
                                   projectName: project,
                                   text: "Waiting on you to allow or deny \(p.toolName)",
                                   icon: "lock.fill")
            }
            if let server = s.pendingMCPAuthServer {
                return LiveBlocker(id: "\(s.id)-mcp", sessionId: s.id, tabLabel: label,
                                   projectName: project,
                                   text: "Needs you to sign in to \(server)",
                                   icon: "person.badge.key.fill")
            }
            return nil
        }
    }

    var attentionCount: Int { openAttention.count + liveBlockers.count }

    /// Log a question a tab has asked. Deduplicated on text, so a tab that
    /// re-states the same ask after a compaction doesn't stack up.
    func noteAsked(_ session: AgentSession, text: String, kind: AttentionEntry.Kind = .decision,
                   recommendation: String? = nil, deadline: String? = nil,
                   messageId: UUID? = nil) {
        // Stored as plain prose. The drawer is a narrow column, and raw
        // syntax there is just noise — "**Seafoam and Atlas teal are one
        // color**" reads worse than the sentence it wraps.
        let clean = Self.plainText(text)
        guard clean.count >= 12 else { return }
        if attentionLog.contains(where: { $0.isOpen && $0.sessionId == session.id
                                          && $0.text == clean }) { return }
        attentionLog.append(AttentionEntry(
            sessionId: session.id,
            tabLabel: session.aiTitle ?? session.displayName,
            projectName: ProjectNaming.name(forCwd: session.projectRoot),
            kind: kind, text: clean,
            recommendation: recommendation.map(Self.plainText), deadline: deadline,
            markAtRaise: session.messages.count,
            messageId: messageId ?? session.messages.last(where: { $0.role == .assistant })?.id))
    }

    /// Markdown read as a person would read it aloud. Deliberately small:
    /// emphasis, code fences, headings, list bullets and link syntax, which
    /// is everything that actually turns up in an agent's closing sentence.
    /// Full rendering belongs in the transcript, not in a sidebar row.
    static func plainText(_ raw: String) -> String {
        var t = raw
        // Fenced blocks go entirely — a row is no place for a code listing.
        t = t.replacingOccurrences(of: "```[\\s\\S]*?```", with: " ",
                                   options: .regularExpression)
        // [label](url) → label
        t = t.replacingOccurrences(of: "\\[([^\\]]+)\\]\\([^)]*\\)", with: "$1",
                                   options: .regularExpression)
        // Leading heading hashes and list markers, per line.
        t = t.replacingOccurrences(of: "(?m)^\\s{0,3}#{1,6}\\s*", with: "",
                                   options: .regularExpression)
        t = t.replacingOccurrences(of: "(?m)^\\s*[-*+]\\s+", with: "• ",
                                   options: .regularExpression)
        t = t.replacingOccurrences(of: "(?m)^\\s*>\\s?", with: "",
                                   options: .regularExpression)
        // Emphasis and inline code markers.
        for mark in ["***", "**", "__", "`", "*", "_", "~~"] {
            t = t.replacingOccurrences(of: mark, with: "")
        }
        return t
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func resolveAttention(_ id: UUID) {
        guard let i = attentionLog.firstIndex(where: { $0.id == id }) else { return }
        attentionLog[i].resolvedAt = Date()
    }

    func resolveAllAttention() {
        let now = Date()
        for i in attentionLog.indices where attentionLog[i].isOpen {
            attentionLog[i].resolvedAt = now
        }
    }

    /// Close entries the user has effectively answered: anything raised
    /// before a later message the user typed into that tab. Called on each
    /// turn end, so answering in the tab clears the row without a trip to
    /// the drawer.
    func resolveAnsweredAttention(for session: AgentSession) {
        let userMessagesAfter: (Int) -> Bool = { mark in
            session.messages.count > mark &&
            session.messages[mark...].contains { $0.role == .user }
        }
        let now = Date()
        for i in attentionLog.indices
        where attentionLog[i].isOpen
            && attentionLog[i].sessionId == session.id
            && userMessagesAfter(attentionLog[i].markAtRaise) {
            attentionLog[i].resolvedAt = now
        }
    }

    private static let snapshotKey = "manyagents.snapshot.v1"
    /// Bundle ids we'll look under when restoring. The first entry is the
    /// active bundle (where we WRITE), the rest are historical ids we read
    /// from for one-time migration so users don't lose work when the bundle
    /// id changes (which happened when ManyAgents went open source).
    private static let legacyBundleIds = ["co.ailogy.manyagents"]

    private var sessionSubscriptions: [UUID: AnyCancellable] = [:]
    private var cancellables: Set<AnyCancellable> = []
    private let sessionsDirty = PassthroughSubject<Void, Never>()

    /// Set when a snapshot was found at launch and is waiting on the user
    /// to confirm restoration via the sheet. Cleared on Reopen / Start fresh.
    @Published var pendingRestore: Snapshot?

    // MARK: - Orchestrator dispatch log

    /// One coordinator → agent dispatch, surfaced live in the Orchestrator
    /// panel so the user can watch an orchestration unfold.
    struct DispatchRecord: Identifiable, Equatable {
        enum State: Equatable { case running, done, failed }
        let id = UUID()
        let coordinatorId: UUID?
        let targetId: UUID
        let targetLabel: String
        let promptSummary: String
        var state: State
        let startedAt: Date
    }

    /// Newest-last list of dispatches, capped so it can't grow unbounded.
    @Published private(set) var dispatchLog: [DispatchRecord] = []

    /// Record the start of a dispatch; returns the record id for the
    /// completion update. Called from `MCPRelay.dispatch` (main actor).
    func recordDispatchStart(coordinatorId: UUID?, target: AgentSession,
                             prompt: String) -> UUID {
        let summary = prompt
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
            .prefix(80)
        let record = DispatchRecord(
            coordinatorId: coordinatorId,
            targetId: target.id,
            targetLabel: target.aiTitle ?? target.displayName,
            promptSummary: String(summary),
            state: .running,
            startedAt: Date()
        )
        dispatchLog.append(record)
        if dispatchLog.count > 50 { dispatchLog.removeFirst(dispatchLog.count - 50) }
        return record.id
    }

    /// Mark a previously-started dispatch as done or failed.
    func recordDispatchEnd(_ recordId: UUID, success: Bool) {
        guard let idx = dispatchLog.firstIndex(where: { $0.id == recordId }) else { return }
        dispatchLog[idx].state = success ? .done : .failed
    }

    init() {
        // Persist on any session-array change (add/remove) AND on any inner
        // session @Published change (aiTitle rename, claudeSessionId arrival,
        // status flip). Debounced so we don't churn UserDefaults on every
        // token of a streaming response.
        $sessions
            // The initial [] emission must never persist: it fires on
            // launch BEFORE the user accepts the restore sheet, and an
            // empty persist deletes the stored snapshot — losing every
            // tab if the sheet is dismissed or the timing races.
            .dropFirst()
            .debounce(for: .milliseconds(500), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.persist() }
            .store(in: &cancellables)
        sessionsDirty
            .debounce(for: .milliseconds(800), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.persist() }
            .store(in: &cancellables)
        // Hand the MCP relay a back-pointer so coordinator sessions
        // can dispatch into the session list without needing to drag
        // a manager reference around through every call.
        MCPRelay.shared.attach(manager: self)
        loadAttentionLog()
        // Pre-start the relay so the Unix socket is ready before any
        // session fires. Without this the socket races against claude's
        // MCP subprocess connect attempt and the tool shows as unavailable.
        try? MCPRelay.shared.startIfNeeded()
        // Auto-resumer: every time the network flips off → on, retry
        // any session that errored out while we were offline. The
        // session keeps the prompt that failed in `lastSentPrompt`
        // and clears it on a clean .result, so we know exactly what
        // to re-dispatch and we won't double-fire after a real success.
        NetworkMonitor.shared.cameOnline
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.resumeOfflineFailures() }
            .store(in: &cancellables)

        // Clicking a "agent finished" notification focuses that agent.
        NotificationCenter.default.publisher(for: .maFocusSession)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] note in
                guard let self,
                      let id = note.userInfo?["sessionId"] as? UUID,
                      self.sessions.contains(where: { $0.id == id })
                else { return }
                self.activeSessionId = id
            }
            .store(in: &cancellables)

        // Flush the snapshot immediately on quit — the debounced pipeline
        // above may not fire in time when the user quits mid-stream.
        NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.persist() }
            .store(in: &cancellables)

        // MCP credentials changed (user completed `claude mcp login` via
        // the Connectors UI). Idle session processes are recycled so their
        // next turn respawns and connects to the newly-authorized server;
        // busy ones pick it up whenever their process next restarts.
        NotificationCenter.default.publisher(for: MCPConnectors.authChanged)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                for session in self.sessions {
                    session.bridge.recycleIfIdle()
                    // Auth landed — the banner's job is done.
                    session.pendingMCPAuthServer = nil
                }
            }
            .store(in: &cancellables)
    }

    /// Re-dispatch every session that was flagged as awaiting network.
    /// Belt-and-braces 800 ms delay so the path actually settles before
    /// we spawn — `cameOnline` can fire while DNS hasn't fully resolved.
    private func resumeOfflineFailures() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self else { return }
            for session in self.sessions where session.awaitingNetworkResume {
                guard let prompt = session.lastSentPrompt else {
                    session.awaitingNetworkResume = false
                    continue
                }
                // Clear flags first so the auto-resumer doesn't loop if
                // the retry itself goes offline → online again instantly.
                session.awaitingNetworkResume = false
                session.lastError = nil
                session.send(prompt.text, images: prompt.images)
            }
        }
    }

    // MARK: - Sessions

    /// Spawn a fresh agent in `cwd`. Returns the new session.
    @discardableResult
    func spawn(cwd: String, resumeSessionId: String? = nil, id: UUID = UUID()) -> AgentSession {
        let session = AgentSession(cwd: cwd, resumeSessionId: resumeSessionId, id: id)
        // Forward inner-session changes both to UI (objectWillChange) and to
        // the debounced persist pipeline (sessionsDirty). Without the latter,
        // a tab rename or a freshly-arrived claudeSessionId wouldn't make
        // it back to disk because $sessions only fires on add/remove.
        sessionSubscriptions[session.id] = session.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
                self?.sessionsDirty.send()
            }
        // Every clean turn-completion on this session feeds the orchestrator
        // "watch & nudge" wake. Tracked separately so it can tear down with
        // the session.
        wireTurnCompletion(for: session)
        wireFinishNotifications(for: session)
        hadSessionsThisRun = true
        sessions.append(session)
        activeSessionId = session.id
        session.connect()
        return session
    }

    /// Terminate the agent and drop it from the list.
    func close(_ session: AgentSession) {
        session.disconnect()
        sessionSubscriptions.removeValue(forKey: session.id)
        turnEndSubscriptions.removeValue(forKey: session.id)
        notifySubscriptions.removeValue(forKey: session.id)
        // If the orchestrator is closing, any muted/hidden state it held is
        // gone with it; nothing else references this id. Drop it from every
        // orchestrator's mute set just in case another tab held it.
        for s in sessions where s.mutedTabIds.contains(session.id) {
            s.mutedTabIds.remove(session.id)
        }
        // Drop any lingering coordinator mcp.json for the session
        // so /tmp/manyagents/configs/ doesn't accumulate stale files.
        CoordinatorConfig.cleanup(for: session)
        sessions.removeAll { $0.id == session.id }
        if activeSessionId == session.id {
            let sameProject = sessions.filter { $0.cwd == session.cwd }
            activeSessionId = sameProject.last?.id ?? sessions.last?.id
        }
        persist()
    }

    // MARK: - Turn completion → orchestrator wake

    /// Per-session subscription to that session's turn-END signal, feeding the
    /// orchestrator "watch & nudge" loop. Deliberately the end signal and not
    /// `turnCompleted`: a turn that errors, returns nothing, or dies with its
    /// process never completes, and hanging the orchestrator's loop off the
    /// clean-only signal is what left it waiting on tabs forever.
    private var turnEndSubscriptions: [UUID: AnyCancellable] = [:]

    private func wireTurnCompletion(for session: AgentSession) {
        turnEndSubscriptions[session.id] = session.turnEnded
            .sink { [weak self, weak session] end in
                guard let self, let session else { return }
                self.handleTurnEnded(on: session, end: end)
                // Log a real ask, and close anything the user has since
                // answered in that tab.
                if session.status == .waiting, !session.waitingSummary.isEmpty {
                    self.noteAsked(session, text: session.waitingSummary)
                }
                self.resolveAnsweredAttention(for: session)
            }
    }

    /// Per-session subscription that fires a system notification / sound when
    /// the agent stops working (settings permitting).
    private var notifySubscriptions: [UUID: AnyCancellable] = [:]

    private func wireFinishNotifications(for session: AgentSession) {
        notifySubscriptions[session.id] = session.finishedWorking
            .sink { [weak session] status in
                guard let session else { return }
                NotificationService.shared.agentFinished(
                    sessionId: session.id,
                    projectName: ProjectNaming.name(forCwd: session.cwd),
                    title: session.aiTitle ?? session.displayName,
                    status: status
                )
            }
    }

    /// Called when a session's turn lands cleanly. Appends one line to the
    /// orchestrator's pending board digest — zero tokens; the digest rides
    /// along with the orchestrator's next prompt. (Replaced the timed
    /// board-wake turns, which burned a full context read per wake.)
    private func handleTurnEnded(on source: AgentSession, end: AgentSession.TurnEnd) {
        // The orchestrator's own turn finishing must not log itself.
        if source.isCoordinator { return }
        // A deliberate interrupt isn't the tab stopping — a replacement turn is
        // already queued behind it. Wait for that one to end instead.
        if end.interrupted { return }
        // Auto-report: a worker the orchestrator dispatched fire-and-forget
        // (or spawned with a task) has stopped and has no more queued work —
        // wake the orchestrator ONCE so it can act (is it done? did it break?
        // does it need a decision?). Runs even for suppressed turns, since
        // this IS the intended ping. Fires only when the tab goes quiet, not
        // every turn, so it won't reintroduce the noisy timed wakes.
        if source.pendingOrchestratorReport, source.pendingPrompts.isEmpty,
           let orch = reportTarget(for: source), orch.id != source.id {
            source.pendingOrchestratorReport = false
            // The report flag is one-shot; the ORCHESTRATOR LINK is not. It
            // stays so the tab's own notify_orchestrator calls keep landing
            // for the rest of its life — clearing it here orphaned any tab
            // dispatched outside the orchestrator's project after its very
            // first turn.
            let name = source.aiTitle ?? source.displayName
            let snippet = String(end.text.prefix(240))
            let headline = end.status == .error
                ? "[Tab \"\(name)\" you dispatched STOPPED ON AN ERROR — it did not finish. Decide whether to retry it, reassign the work, or route around it]"
                : "[Tab \"\(name)\" you dispatched has stopped. Check whether it finished or needs a decision]"
            // Steered into the orchestrator's RUNNING turn when it's busy —
            // a queued report used to sit unread behind a long orchestrator
            // turn, which kept "waiting on tabs" for work that had already
            // stopped. Same delivery as notify_orchestrator pings.
            orch.deliverInterjection("\(headline)\n\n\(snippet)")
        }
        // A turn the orchestrator itself dispatched doesn't need logging —
        // the orchestrator already got the reply via the dispatch tool.
        if let promptId = end.promptId,
           source.suppressedPromptIds.remove(promptId) != nil {
            return
        }
        guard let orch = orchestrator(for: source.cwd),
              orch.id != source.id,
              !source.hiddenFromOrchestrator,
              !orch.mutedTabIds.contains(source.id)
        else { return }
        let time = Self.digestTimeFormatter.string(from: Date())
        let snippet = String(end.text.prefix(140))
        let verb = end.status == .error ? "errored" : "finished"
        orch.pendingBoardUpdates.append(
            "• \(time) \(source.aiTitle ?? source.displayName) [\(source.id)] \(verb) — \(snippet)")
        // Cap: keep the newest entries; an old flood isn't actionable.
        if orch.pendingBoardUpdates.count > 30 {
            orch.pendingBoardUpdates.removeFirst(orch.pendingBoardUpdates.count - 30)
        }
    }

    private static let digestTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    // MARK: - Orchestrator (v2)

    /// The orchestrator a tab at `cwd` answers to — the NEAREST one. A repo
    /// lead (an orchestrator inside a nested repo) takes precedence over the
    /// workspace orchestrator for tabs in its repo; everything else falls
    /// through to the workspace.
    ///
    /// Matched on roots, not the raw cwd: a tab running in a git worktree
    /// belongs to the repo it was cut from, and keying on cwd meant a
    /// worktree tab found no orchestrator at all — its pings failed with "no
    /// orchestrator in this project" and its turn-ends never reached a board.
    func orchestrator(for cwd: String) -> AgentSession? {
        let repo = ProjectNaming.repoRoot(forCwd: cwd)
        if let lead = sessions.first(where: { $0.isCoordinator && $0.boardScope == repo }) {
            return lead
        }
        let workspace = ProjectNaming.projectRoot(forCwd: cwd)
        return sessions.first { $0.isCoordinator && $0.boardScope == workspace }
    }

    /// The orchestrator ABOVE this one: for a repo lead, the workspace
    /// orchestrator that delegated its hat. nil for the workspace
    /// orchestrator itself, which has nobody above it.
    ///
    /// `orchestrator(for:)` can't answer this — asked from inside a repo
    /// lead it finds the lead itself, which is why a lead's ping used to
    /// come back "you are the orchestrator" with no way up.
    func parentOrchestrator(of session: AgentSession) -> AgentSession? {
        guard session.isRepoLead else { return nil }
        return sessions.first { $0.isCoordinator
            && $0.id != session.id
            && $0.boardScope == session.projectRoot }
    }

    /// Who a dispatched tab reports back to: the orchestrator that actually
    /// dispatched it (recorded on the tab at dispatch time), falling back to
    /// whichever orchestrator owns its project. The recorded id is what makes
    /// the report land when the worker's cwd differs from the orchestrator's —
    /// a subdir, a worktree, or another repo entirely — where the cwd lookup
    /// finds nobody and the report used to vanish without a trace.
    ///
    /// Both the automatic turn-end report and the worker's own
    /// notify_orchestrator ping route through here, so a tab pings whoever
    /// dispatched it rather than whoever happens to share its directory.
    func reportTarget(for source: AgentSession) -> AgentSession? {
        if let id = source.reportToOrchestratorId,
           let orch = sessions.first(where: { $0.id == id }) {
            return orch
        }
        return orchestrator(for: source.cwd)
    }

    /// Designate / un-designate a tab as the orchestrator. Exclusive: making
    /// one orchestrator clears the hat from any other tab.
    func toggleOrchestrator(_ session: AgentSession) {
        if session.isCoordinator {
            undesignateOrchestrator(session)
        } else {
            designateOrchestrator(session)
        }
    }

    /// Drop the orchestrator hat AND shed the fixed "Orchestrator" name so
    /// the tab doesn't linger as a mis-named, icon-less ghost orchestrator
    /// (which then still behaves like one). AutoNamer regenerates a real
    /// title from its conversation.
    func undesignateOrchestrator(_ session: AgentSession) {
        session.isCoordinator = false
        if session.aiTitle == "Orchestrator" || session.aiTitle == "Repo Lead" {
            session.aiTitle = nil
        }
    }

    /// Put the hat on `session` and immediately deliver the catch-up brief.
    /// Without this, a newly-designated orchestrator sat blind until the
    /// next watched-tab completion — potentially forever if every tab was
    /// idle or mid-task — and was never even told it had the job.
    func designateOrchestrator(_ session: AgentSession) {
        // Exclusive PER SCOPE, not per workspace. Making a tab in
        // `uhp/dev/UHP-OPS-Agent` an orchestrator used to strip the hat off
        // the `uhp` orchestrator, because both share a project root — so a
        // workspace could never have a repo lead under it. Now the workspace
        // board and each repo's board coexist, and only a same-scope
        // orchestrator is displaced.
        for s in sessions where s.isCoordinator && s.boardScope == session.boardScope {
            undesignateOrchestrator(s)
        }
        session.isCoordinator = true
        // Fixed role names, so the strip says which hat this is. AutoNamer
        // skips coordinator tabs, so they stay put.
        session.aiTitle = session.boardScope == session.projectRoot ? "Orchestrator" : "Repo Lead"
        deliverOrchestratorCatchUp(to: session)
    }

    /// One-time onboarding turn on designation. The prompt is hidden but —
    /// unlike routine board wakes — the REPLY is visible: the digest of
    /// what every tab is doing is the payoff of flipping the hat on.
    private func deliverOrchestratorCatchUp(to orch: AgentSession) {
        let prompt = """
        [Orchestrator catch-up — automatic, sent because the user just designated this tab as this project's orchestrator. Not typed by the user.]
        You now coordinate the user's other open tabs in this project via the manyagents tools: list_agents, read_agent, send_to_agent, new_agent, set_notes, mute_agent/unmute_agent.

        Current board:
        \(orchestratorBoardText(for: orch))

        Catch up now:
        1. Call read_agent on each tab that is running or waiting. Skip idle tabs unless their board line looks relevant.
        2. Reply to the user with a short digest: one line per tab saying what it's doing, then flag any overlap or conflict you can see (e.g. two tabs touching the same files or branches). No preamble, no restating these instructions.
        3. Call set_notes with your running understanding.

        From here on, watched-tab activity accumulates silently and arrives as an automatic board digest attached to your next message — you are NOT woken for it. Act on digests when they arrive; use read_agent when something needs a closer look.
        """
        orch.send(prompt, visible: false)
    }

    /// Compact board snapshot the orchestrator sees on every wake. Its own
    /// project's tabs plus any tab it dispatched elsewhere. Hidden tabs are
    /// excluded entirely; muted tabs stay listed but flagged.
    func orchestratorBoardText(for orch: AgentSession) -> String {
        let others = sessions.filter {
            $0.id != orch.id && !$0.hiddenFromOrchestrator
                && (orch.coordinates($0) || $0.reportToOrchestratorId == orch.id)
        }
        if others.isEmpty { return "(no other tabs on your board)" }
        return others.map { s in
            let muted = orch.mutedTabIds.contains(s.id) ? " [muted]" : ""
            // Say where a tab lives when it isn't simply the project root:
            // a worktree or a nested repo inside this project, or a tab this
            // orchestrator dispatched into a different project altogether.
            let where_: String
            if s.projectRoot != orch.projectRoot {
                where_ = " (other project: \(ProjectNaming.name(forCwd: s.projectRoot)))"
            } else if s.repoRoot != orch.repoRoot {
                // A workspace orchestrator spans repos, so name the repo AND
                // the checkout: "UHP-OPS-Agent/mdrender".
                let checkout = ProjectNaming.checkoutLabel(forCwd: s.cwd)
                let repo = ProjectNaming.name(forCwd: s.repoRoot)
                where_ = " (repo: \(repo)\(checkout.isEmpty ? "" : "/\(checkout)"))"
            } else if s.isWorktree {
                where_ = " (checkout: \(ProjectNaming.checkoutLabel(forCwd: s.cwd)))"
            } else {
                where_ = ""
            }
            // A tab whose directory was deleted can't do anything else —
            // say so plainly so the orchestrator closes it rather than
            // dispatching work into a hole.
            let gone = s.cwdMissing ? " [DIRECTORY GONE — close this tab]" : ""
            return "• \(s.boardTitle) [\(s.id)]\(where_)\(gone) — \(s.status.boardLabel)\(muted) — \(s.latestSnippet)"
        }.joined(separator: "\n")
    }

    // MARK: - Project grouping

    /// Unique project list derived from session REPOS, preserving the order
    /// in which they first appear in `sessions`. A tab in a worktree (or any
    /// subdirectory) belongs to the repo it was cut from, so six parallel
    /// worktree tabs are six tabs of one repo rather than six rows sitting
    /// beside it — which is how people talk about them ("the Preview Server
    /// tab", never "the -preview project"). `projectTree` adds the workspace
    /// nesting on top; this stays flat because ordering, drag-reorder and
    /// activation all address a single repo.
    var projects: [ProjectEntry] {
        var seen = Set<String>()
        var ordered: [String] = []
        for s in sessions {
            let key = s.repoRoot
            if !seen.contains(key) {
                ordered.append(key)
                seen.insert(key)
            }
        }
        return ordered.map { root in
            ProjectEntry(cwd: root, sessions: sessions.filter { $0.repoRoot == root })
        }
    }

    /// The sidebar's shape: workspaces on top, each carrying the repos cloned
    /// inside it. `~/Sites/uhp` holds its product repos in `dev/`, and they
    /// belong under it rather than scattered across the top level — the uhp
    /// orchestrator coordinates all of them as one board.
    /// A nested repo whose workspace has no tabs open stands on its own
    /// rather than disappearing.
    var projectTree: [ProjectGroup] {
        let all = projects
        let rootsWithEntries = Set(all.map(\.cwd))
        var childrenByRoot: [String: [ProjectEntry]] = [:]
        var tops: [ProjectEntry] = []
        for entry in all {
            let root = ProjectNaming.projectRoot(forCwd: entry.cwd)
            if root != entry.cwd, rootsWithEntries.contains(root) {
                childrenByRoot[root, default: []].append(entry)
            } else {
                tops.append(entry)
            }
        }
        return tops.map { ProjectGroup(project: $0, worktrees: childrenByRoot[$0.cwd] ?? []) }
    }

    var activeSession: AgentSession? {
        guard let id = activeSessionId else { return nil }
        return sessions.first { $0.id == id }
    }

    var activeProject: ProjectEntry? {
        guard let s = activeSession else { return nil }
        let root = s.repoRoot
        return ProjectEntry(cwd: root, sessions: sessions.filter { $0.repoRoot == root })
    }

    // MARK: - Reordering

    /// Move `movedId` so it sits immediately before `targetId` in the
    /// sessions array. With `targetId == nil`, the session moves to the end.
    /// Drives drag-and-drop tab reorder.
    func reorderSession(movedId: UUID, before targetId: UUID?) {
        guard movedId != targetId,
              let movingIdx = sessions.firstIndex(where: { $0.id == movedId })
        else { return }
        let moving = sessions.remove(at: movingIdx)
        if let targetId, let targetIdx = sessions.firstIndex(where: { $0.id == targetId }) {
            sessions.insert(moving, at: targetIdx)
        } else {
            sessions.append(moving)
        }
    }

    // MARK: - Cycling shortcuts

    /// Activate the next project in the sidebar order, wrapping around.
    /// Driven by ⌘`.
    func cycleNextProject() {
        let order = projects
        guard !order.isEmpty else { return }
        let currentCwd = activeSession?.cwd
        let currentIdx = order.firstIndex(where: { $0.cwd == currentCwd }) ?? -1
        let next = order[(currentIdx + 1) % order.count]
        activate(project: next)
    }

    /// Activate the next session within the current project, wrapping
    /// around. Driven by ⌘⇧`.
    func cycleNextTabInActiveProject() {
        guard let project = activeProject, project.sessions.count > 1 else { return }
        let tabs = project.sessions
        let currentIdx = tabs.firstIndex(where: { $0.id == activeSessionId }) ?? -1
        activeSessionId = tabs[(currentIdx + 1) % tabs.count].id
    }

    /// Spawn a new session in the currently active project's cwd.
    /// No-op if nothing is active. Driven by ⌘T.
    @discardableResult
    func spawnInActiveProject() -> AgentSession? {
        guard let cwd = activeProject?.cwd else { return nil }
        return spawn(cwd: cwd)
    }

    /// Move every session belonging to `movedCwd` as a block so the
    /// project sits before `targetCwd`. nil target moves to the end.
    /// `projects` is derived from the first-appearance order in sessions,
    /// so reshuffling sessions of one cwd reshuffles the project rows.
    func reorderProject(movedCwd: String, before targetCwd: String?) {
        guard movedCwd != targetCwd else { return }
        let movedSessions = sessions.filter { $0.repoRoot == movedCwd }
        guard !movedSessions.isEmpty else { return }
        let others = sessions.filter { $0.repoRoot != movedCwd }
        if let targetCwd, let insertIdx = others.firstIndex(where: { $0.repoRoot == targetCwd }) {
            var result = others
            result.insert(contentsOf: movedSessions, at: insertIdx)
            sessions = result
        } else {
            sessions = others + movedSessions
        }
    }

    /// Activate the most-recent session in `project`. If no session is
    /// currently active for that cwd, fall back to the last one added.
    func activate(project: ProjectEntry) {
        if let active = activeSession, active.repoRoot == project.cwd { return }
        // Return to the last tab you were on in this project, if it's still
        // open; otherwise fall back to the most recent tab.
        if let remembered = lastActiveTabPerProject[project.cwd],
           project.sessions.contains(where: { $0.id == remembered }) {
            activeSessionId = remembered
        } else if let last = project.sessions.last {
            activeSessionId = last.id
        }
    }

    // MARK: - Persistence

    struct Snapshot: Codable {
        let agents: [SavedAgent]
        struct SavedAgent: Codable, Identifiable {
            let cwd: String
            let claudeSessionId: String?
            let displayName: String
            let aiTitle: String?
            /// Queued-but-not-yet-sent prompts, persisted so a relaunch or
            /// crash never loses a staged stack. Optional for back-compat
            /// with snapshots written before this field existed.
            let pendingPrompts: [AgentSession.PendingPrompt]?
            /// Orchestrator designation + hide flag, so the orchestrator hat
            /// survives a relaunch instead of silently dropping. Optional for
            /// back-compat. (mutedTabIds isn't persisted — tab UUIDs are
            /// regenerated on relaunch, so it wouldn't round-trip meaningfully.)
            let isOrchestrator: Bool?
            let hiddenFromOrchestrator: Bool?
            /// Stable tab UUID, restored on relaunch so ids the
            /// orchestrator memorized keep working. Optional for
            /// back-compat with older snapshots.
            let tabId: UUID?
            /// True if the session was mid-turn (.running) when the app
            /// quit. On restore we auto-continue these so the user never
            /// has to type "continue"/"try again" in each interrupted tab.
            /// Optional for back-compat.
            let wasRunning: Bool?
            /// Canonical context window for this session's model, so the
            /// restored context gauge has the right denominator (and
            /// doesn't false-alarm at "100%" against a default guess).
            let contextWindow: Int?
            /// claude sessions this tab used before its current one, oldest
            /// first — see AgentSession.priorSessionIds. Optional for
            /// back-compat with snapshots written before rolling compaction.
            let priorSessionIds: [String]?
            /// Per-tab model choice, when it isn't just following settings.
            /// Optional for back-compat with older snapshots.
            let modelTier: AgentSession.ModelTier?

            var id: String { (claudeSessionId ?? "") + cwd }
        }
    }

    /// True once this run has had at least one live session. Gates the
    /// empty-snapshot delete below: a run that never had sessions has no
    /// business erasing the previous run's snapshot.
    private var hadSessionsThisRun = false

    private func persist() {
        let snap = Snapshot(agents: sessions.map { s in
            Snapshot.SavedAgent(
                cwd: s.cwd,
                claudeSessionId: s.claudeSessionId ?? s.resumeSessionId,
                displayName: s.displayName,
                aiTitle: s.aiTitle,
                pendingPrompts: s.pendingPrompts.isEmpty ? nil : s.pendingPrompts,
                isOrchestrator: s.isCoordinator ? true : nil,
                hiddenFromOrchestrator: s.hiddenFromOrchestrator ? true : nil,
                tabId: s.id,
                wasRunning: s.status == .running ? true : nil,
                contextWindow: s.lastTurnContextWindow,
                priorSessionIds: s.priorSessionIds.isEmpty ? nil : s.priorSessionIds,
                modelTier: s.modelTier == .auto ? nil : s.modelTier
            )
        })
        if snap.agents.isEmpty {
            // Deleting the snapshot is only legitimate when the user
            // actually closed their sessions this run — never as the
            // side effect of an empty launch.
            if hadSessionsThisRun {
                UserDefaults.standard.removeObject(forKey: Self.snapshotKey)
            }
        } else if let data = try? JSONEncoder().encode(snap) {
            UserDefaults.standard.set(data, forKey: Self.snapshotKey)
        }
    }

    /// Look for a persisted snapshot under the current bundle id, falling
    /// back to historical ids so a bundle-id change doesn't orphan the
    /// user's data. Stashes the result in `pendingRestore` for the sheet
    /// to surface — does NOT spawn anything yet.
    func loadPendingSnapshot() {
        if let snap = readSnapshot(from: UserDefaults.standard), !snap.agents.isEmpty {
            pendingRestore = snap
            return
        }
        for bid in Self.legacyBundleIds {
            guard let defaults = UserDefaults(suiteName: bid),
                  let snap = readSnapshot(from: defaults),
                  !snap.agents.isEmpty
            else { continue }
            // Copy forward so future launches read it from the current
            // bundle directly, then drop the legacy entry.
            if let data = try? JSONEncoder().encode(snap) {
                UserDefaults.standard.set(data, forKey: Self.snapshotKey)
            }
            defaults.removeObject(forKey: Self.snapshotKey)
            pendingRestore = snap
            return
        }
    }

    private func readSnapshot(from defaults: UserDefaults) -> Snapshot? {
        guard let data = defaults.data(forKey: Self.snapshotKey) else { return nil }
        return try? JSONDecoder().decode(Snapshot.self, from: data)
    }

    /// Transcript parsing for a restore, one file at a time. Serial on
    /// purpose: 25 concurrent parses of multi-megabyte tails would put the
    /// peak right back where it was.
    private static let restoreQueue = DispatchQueue(label: "app.manyagents.transcript-restore",
                                                    qos: .userInitiated)

    /// Spawn every agent in `pendingRestore`. Called by the restore sheet
    /// when the user clicks Reopen.
    func acceptPendingSnapshot() {
        guard let snap = pendingRestore else { return }
        pendingRestore = nil
        let fm = FileManager.default
        for a in snap.agents {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: a.cwd, isDirectory: &isDir), isDir.boolValue else {
                continue
            }
            let session = spawn(cwd: a.cwd, resumeSessionId: a.claudeSessionId,
                                id: a.tabId ?? UUID())
            session.displayName = a.displayName
            session.aiTitle = a.aiTitle
            session.isCoordinator = a.isOrchestrator ?? false
            // Enforce the fixed role name on restore too — orchestrators
            // designated before this rule kept their old auto-names.
            if session.isCoordinator {
                session.aiTitle = "Orchestrator"
                // didSet doesn't fire for a value assigned during restore
                // setup in every path; publish explicitly so the bridge can
                // find the orchestrator before its first turn.
                session.publishRelayConfig()
            }
            session.hiddenFromOrchestrator = a.hiddenFromOrchestrator ?? false
            session.modelTier = a.modelTier ?? .auto
            // Restore the real window so the gauge's denominator is right.
            session.lastTurnContextWindow = a.contextWindow
            // Restore the queued stack as STAGED items (visible in the strip,
            // not auto-fired) — so reopening can't trigger a surprise burst;
            // they drain normally on the next turn. Never lose staged work.
            session.pendingPrompts = a.pendingPrompts ?? []
            if let sid = a.claudeSessionId, !sid.isEmpty {
                // Off the main thread, and one file at a time.
                //
                // This used to parse every tab's transcript inline, here, in
                // one main-thread pass. With 25 tabs and JSONLs up to 100 MB
                // that peaked at tens of GB — the parse allocations of tab 1
                // were still alive while tab 25 was reading, because nothing
                // drains until the run-loop pass ends. A serial queue bounds
                // the peak to a single tail, and the UI stays live while it
                // works through them.
                let cwd = a.cwd
                let wasRunning = a.wasRunning == true
                // Oldest first, current last: a tab that has been through a
                // rolling compact spans more than one claude session, and its
                // thread on screen spans all of them.
                let chain = (a.priorSessionIds ?? []) + [sid]
                session.priorSessionIds = a.priorSessionIds ?? []
                Self.restoreQueue.async { [weak session] in
                    let restored = TranscriptLoader.restoreChain(cwd: cwd, sessionIds: chain)
                    DispatchQueue.main.async {
                        guard let session else { return }
                        if !restored.messages.isEmpty {
                            var msgs = restored.messages
                            if restored.truncated {
                                // Say so rather than silently showing a
                                // conversation that appears to begin mid-thought.
                                msgs.insert(Message(role: .system, blocks: [
                                    .text(id: UUID(),
                                          text: "Earlier history kept on disk — showing the most recent part of this conversation.")
                                ]), at: 0)
                            }
                            session.messages = msgs
                            session.status = .waiting
                        }
                        // Seed the context gauge from the transcript's last
                        // usage so restored tabs don't sit empty until their
                        // next turn. Same pass, so the file is read once.
                        if let ctx = restored.contextTokens, session.lastTurnContextTokens == 0 {
                            session.lastTurnContextTokens = ctx
                        }
                        // Auto-continue turns the app restart interrupted, so
                        // the user never has to type "continue" per tab.
                        if wasRunning { session.continueAfterRestart() }
                    }
                }
            }
        }
    }

    /// Drop the pending snapshot without spawning anything. Triggered by
    /// "Start fresh" in the restore sheet.
    func discardPendingSnapshot() {
        pendingRestore = nil
        UserDefaults.standard.removeObject(forKey: Self.snapshotKey)
    }

    /// Dismiss the sheet WITHOUT touching the persisted snapshot — the user
    /// just wants to defer the decision (Escape / background click).
    func dismissPendingSnapshot() {
        pendingRestore = nil
    }
}

/// A top-level project plus the git worktrees cut from it, which the sidebar
/// renders indented beneath it.
struct ProjectGroup: Identifiable, Hashable {
    let project: ProjectEntry
    let worktrees: [ProjectEntry]
    var id: String { project.cwd }
}

/// A project — a unique cwd with one or more agents.
struct ProjectEntry: Identifiable, Hashable {
    let cwd: String
    let sessions: [AgentSession]

    var id: String { cwd }
    var displayName: String { ProjectNaming.name(forCwd: cwd) }
    /// A worktree row is labelled by what makes it different from its parent
    /// ("adapther-port-today" under "adapther" reads as "port-today").
    var worktreeLabel: String {
        let root = ProjectNaming.projectRoot(forCwd: cwd)
        let full = displayName
        guard root != cwd else { return full }
        let parent = ProjectNaming.name(forCwd: root)
        if full.hasPrefix(parent + "-") { return String(full.dropFirst(parent.count + 1)) }
        return full
    }
    var prettyCwd: String { ProjectNaming.prettyCwd(cwd) }

    static func == (lhs: ProjectEntry, rhs: ProjectEntry) -> Bool {
        lhs.cwd == rhs.cwd && lhs.sessions.map(\.id) == rhs.sessions.map(\.id)
    }
    func hash(into hasher: inout Hasher) { hasher.combine(cwd) }
}
