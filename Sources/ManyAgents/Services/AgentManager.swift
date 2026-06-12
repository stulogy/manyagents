import Foundation
import Combine

/// Top-level state container. Owns every active AgentSession and persists
/// enough state to restore conversations across launches via `--resume`.
@MainActor
final class AgentManager: ObservableObject {
    @Published private(set) var sessions: [AgentSession] = []
    @Published var activeSessionId: UUID?

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
    func spawn(cwd: String, resumeSessionId: String? = nil) -> AgentSession {
        let session = AgentSession(cwd: cwd, resumeSessionId: resumeSessionId)
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
        sessions.append(session)
        activeSessionId = session.id
        session.connect()
        return session
    }

    /// Terminate the agent and drop it from the list.
    func close(_ session: AgentSession) {
        session.disconnect()
        sessionSubscriptions.removeValue(forKey: session.id)
        turnCompletionSubscriptions.removeValue(forKey: session.id)
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

    /// Per-session subscription to that session's turn-completed signal,
    /// feeding the orchestrator "watch & nudge" loop.
    private var turnCompletionSubscriptions: [UUID: AnyCancellable] = [:]

    private func wireTurnCompletion(for session: AgentSession) {
        turnCompletionSubscriptions[session.id] = session.turnCompleted
            .sink { [weak self, weak session] lastAssistantText in
                guard let self, let session else { return }
                self.handleTurnCompleted(on: session, payload: lastAssistantText)
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

    /// Called when a session's turn lands cleanly. Drives the orchestrator
    /// "watch & nudge" loop: a finished tab wakes the orchestrator so it can
    /// decide whether to act.
    private func handleTurnCompleted(on source: AgentSession, payload: String) {
        // The orchestrator's own turn finishing must not wake itself.
        if source.isCoordinator { return }
        // Anti-loop: a turn the orchestrator itself dispatched into this tab
        // doesn't ping back — the orchestrator already got the reply.
        if source.suppressNextOrchestratorPing {
            source.suppressNextOrchestratorPing = false
            return
        }
        // A watched tab finished — schedule a (debounced, rate-limited) wake.
        guard let orch = orchestrator,
              orch.id != source.id,
              source.cwd == orch.cwd,            // only tabs in the orchestrator's own project
              !source.hiddenFromOrchestrator,
              !orch.mutedTabIds.contains(source.id)
        else { return }
        scheduleOrchestratorWake()
    }

    // MARK: - Orchestrator (v2)

    /// The single tab currently wearing the orchestrator hat, if any.
    var orchestrator: AgentSession? { sessions.first { $0.isCoordinator } }

    /// Designate / un-designate a tab as the orchestrator. Exclusive: making
    /// one orchestrator clears the hat from any other tab.
    func toggleOrchestrator(_ session: AgentSession) {
        if session.isCoordinator {
            session.isCoordinator = false
        } else {
            for s in sessions where s.isCoordinator { s.isCoordinator = false }
            session.isCoordinator = true
        }
    }

    // Wake throttling. Tab completions are bursty and frequent; without this
    // the orchestrator narrated "holding" on every single turn of every tab.
    private var orchestratorWakeWork: DispatchWorkItem?
    private var lastOrchestratorWakeAt: Date = .distantPast
    private var lastOrchestratorStatusSig: String = ""
    /// Coalesce a burst of completions into one wake.
    private static let orchestratorWakeDebounce: TimeInterval = 12
    /// Never wake the orchestrator more often than this.
    private static let orchestratorMinWakeInterval: TimeInterval = 90

    /// Schedule a debounced, rate-limited wake. Each new completion resets the
    /// timer (coalescing bursts); the wake also can't fire sooner than
    /// `orchestratorMinWakeInterval` after the previous one, and is skipped
    /// entirely if no watched tab's STATUS changed since the last wake.
    private func scheduleOrchestratorWake() {
        orchestratorWakeWork?.cancel()
        let earliest = lastOrchestratorWakeAt.addingTimeInterval(Self.orchestratorMinWakeInterval)
        let delay = max(Self.orchestratorWakeDebounce, earliest.timeIntervalSinceNow)
        let work = DispatchWorkItem { [weak self] in
            guard let self, let orch = self.orchestrator else { return }
            // Busy → try again after the window rather than queueing onto it.
            if orch.status == .running { self.scheduleOrchestratorWake(); return }
            let sig = self.orchestratorStatusSignature(for: orch)
            // Nothing meaningfully changed since the last wake — stay quiet.
            guard sig != self.lastOrchestratorStatusSig else { return }
            self.lastOrchestratorStatusSig = sig
            self.lastOrchestratorWakeAt = Date()
            self.deliverOrchestratorPing(to: orch)
        }
        orchestratorWakeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Coarse signature of the board — just each tab's status, not its
    /// snippet — so token-level churn doesn't count as a change.
    private func orchestratorStatusSignature(for orch: AgentSession) -> String {
        sessions
            .filter { $0.cwd == orch.cwd && $0.id != orch.id && !$0.hiddenFromOrchestrator }
            .map { "\($0.id.uuidString.prefix(8)):\($0.status.boardLabel)" }
            .sorted()
            .joined(separator: "|")
    }

    /// Deliver a (non-visible) wake prompt to the orchestrator with the board.
    private func deliverOrchestratorPing(to orch: AgentSession) {
        let prompt = """
        [Board update — automatic, not from the user. Do NOT reply with a long status report.]
        Current board:
        \(orchestratorBoardText(for: orch))

        Decide if anything needs doing. If something does, act (read_agent / send_to_agent / new_agent) and update set_notes. If nothing does — which is common — reply with at most ONE short line (e.g. "Holding, nothing actionable.") and don't restate your reasoning. Update set_notes only when your plan actually changes.
        """
        orch.send(prompt, visible: false, boardWake: true)
    }

    /// Compact board snapshot the orchestrator sees on every wake. Hidden
    /// tabs are excluded entirely; muted tabs stay listed but flagged.
    func orchestratorBoardText(for orch: AgentSession) -> String {
        let others = sessions.filter { $0.cwd == orch.cwd && $0.id != orch.id && !$0.hiddenFromOrchestrator }
        if others.isEmpty { return "(no other tabs in this project)" }
        return others.map { s in
            let muted = orch.mutedTabIds.contains(s.id) ? " [muted]" : ""
            return "• \(s.aiTitle ?? s.displayName) [\(s.id)] — \(s.status.boardLabel)\(muted) — \(s.latestSnippet)"
        }.joined(separator: "\n")
    }

    // MARK: - Project grouping

    /// Unique project list derived from session cwds, preserving the order in
    /// which projects first appear in `sessions`.
    var projects: [ProjectEntry] {
        var seen = Set<String>()
        var ordered: [String] = []
        for s in sessions {
            if !seen.contains(s.cwd) {
                ordered.append(s.cwd)
                seen.insert(s.cwd)
            }
        }
        return ordered.map { cwd in
            ProjectEntry(cwd: cwd, sessions: sessions.filter { $0.cwd == cwd })
        }
    }

    var activeSession: AgentSession? {
        guard let id = activeSessionId else { return nil }
        return sessions.first { $0.id == id }
    }

    var activeProject: ProjectEntry? {
        guard let s = activeSession else { return nil }
        return ProjectEntry(cwd: s.cwd, sessions: sessions.filter { $0.cwd == s.cwd })
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
        let movedSessions = sessions.filter { $0.cwd == movedCwd }
        guard !movedSessions.isEmpty else { return }
        let others = sessions.filter { $0.cwd != movedCwd }
        if let targetCwd, let insertIdx = others.firstIndex(where: { $0.cwd == targetCwd }) {
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
        if let active = activeSession, active.cwd == project.cwd { return }
        if let last = project.sessions.last {
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

            var id: String { (claudeSessionId ?? "") + cwd }
        }
    }

    private func persist() {
        let snap = Snapshot(agents: sessions.map { s in
            Snapshot.SavedAgent(
                cwd: s.cwd,
                claudeSessionId: s.claudeSessionId ?? s.resumeSessionId,
                displayName: s.displayName,
                aiTitle: s.aiTitle,
                pendingPrompts: s.pendingPrompts.isEmpty ? nil : s.pendingPrompts,
                isOrchestrator: s.isCoordinator ? true : nil,
                hiddenFromOrchestrator: s.hiddenFromOrchestrator ? true : nil
            )
        })
        if snap.agents.isEmpty {
            UserDefaults.standard.removeObject(forKey: Self.snapshotKey)
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
            let session = spawn(cwd: a.cwd, resumeSessionId: a.claudeSessionId)
            session.displayName = a.displayName
            session.aiTitle = a.aiTitle
            session.isCoordinator = a.isOrchestrator ?? false
            session.hiddenFromOrchestrator = a.hiddenFromOrchestrator ?? false
            // Restore the queued stack as STAGED items (visible in the strip,
            // not auto-fired) — so reopening can't trigger a surprise burst;
            // they drain normally on the next turn. Never lose staged work.
            session.pendingPrompts = a.pendingPrompts ?? []
            if let sid = a.claudeSessionId, !sid.isEmpty {
                let prior = TranscriptLoader.load(cwd: a.cwd, sessionId: sid)
                if !prior.isEmpty {
                    session.messages = prior
                    session.status = .waiting
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

/// A project — a unique cwd with one or more agents.
struct ProjectEntry: Identifiable, Hashable {
    let cwd: String
    let sessions: [AgentSession]

    var id: String { cwd }
    var displayName: String { ProjectNaming.name(forCwd: cwd) }
    var prettyCwd: String { ProjectNaming.prettyCwd(cwd) }

    static func == (lhs: ProjectEntry, rhs: ProjectEntry) -> Bool {
        lhs.cwd == rhs.cwd && lhs.sessions.map(\.id) == rhs.sessions.map(\.id)
    }
    func hash(into hasher: inout Hasher) { hasher.combine(cwd) }
}
