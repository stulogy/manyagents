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
        // Hook the chain coordinator: every clean .result on this
        // session triggers an evaluation of its `chainTargetId`.
        wireChainCoordination(for: session)
        sessions.append(session)
        activeSessionId = session.id
        session.connect()
        return session
    }

    /// Terminate the agent and drop it from the list.
    func close(_ session: AgentSession) {
        session.disconnect()
        sessionSubscriptions.removeValue(forKey: session.id)
        chainSubscriptions.removeValue(forKey: session.id)
        // Any sessions chained TO this one lose their target.
        for other in sessions where other.chainTargetId == session.id {
            other.chainTargetId = nil
        }
        sessions.removeAll { $0.id == session.id }
        if activeSessionId == session.id {
            let sameProject = sessions.filter { $0.cwd == session.cwd }
            activeSessionId = sameProject.last?.id ?? sessions.last?.id
        }
        persist()
    }

    // MARK: - Chain coordination

    private var chainSubscriptions: [UUID: AnyCancellable] = [:]

    private func wireChainCoordination(for session: AgentSession) {
        chainSubscriptions[session.id] = session.turnCompleted
            .sink { [weak self, weak session] lastAssistantText in
                guard let self, let session else { return }
                self.handleTurnCompleted(on: session, payload: lastAssistantText)
            }
    }

    /// Called when a session's turn lands without error. Decides
    /// whether to forward to a chain target — respecting the hop budget,
    /// the self-loop guard, and the YOLO toggle on the source.
    private func handleTurnCompleted(on source: AgentSession, payload: String) {
        guard let targetId = source.chainTargetId,
              targetId != source.id,                          // no self-loop
              let target = sessions.first(where: { $0.id == targetId }),
              source.remainingHops > 0
        else { return }

        let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let hopsForTarget = max(0, source.remainingHops - 1)

        if source.chainYoloMode {
            dispatchHandOff(from: source,
                            to: target,
                            payload: trimmed,
                            hopsForTarget: hopsForTarget,
                            includeProvenance: true)
        } else {
            target.pendingHandOff = AgentSession.PendingHandOff(
                sourceAgentId: source.id,
                sourceProjectName: ProjectNaming.name(forCwd: source.cwd),
                sourceTitle: source.aiTitle ?? source.displayName,
                payload: trimmed,
                hopsRemaining: hopsForTarget
            )
        }
    }

    // MARK: - Hand-off (manual)

    /// Manual hand-off triggered from the "Send to →" message-row action.
    /// `autoSend = true` fires immediately; `false` stages a
    /// pendingHandOff on the target so the target's owner can review
    /// before the prompt runs.
    func handOff(from sourceId: UUID,
                 to targetId: UUID,
                 prompt: String,
                 autoSend: Bool) {
        guard sourceId != targetId,
              let source = sessions.first(where: { $0.id == sourceId }),
              let target = sessions.first(where: { $0.id == targetId })
        else { return }
        // Manual hand-offs start a fresh chain — give the target a full
        // budget allowance regardless of what state the source's chain
        // was in.
        let hopsForTarget = max(0, source.chainHopBudget - 1)
        if autoSend {
            dispatchHandOff(from: source,
                            to: target,
                            payload: prompt,
                            hopsForTarget: hopsForTarget,
                            includeProvenance: true)
        } else {
            target.pendingHandOff = AgentSession.PendingHandOff(
                sourceAgentId: source.id,
                sourceProjectName: ProjectNaming.name(forCwd: source.cwd),
                sourceTitle: source.aiTitle ?? source.displayName,
                payload: prompt,
                hopsRemaining: hopsForTarget
            )
            // Bring the target to the foreground so the banner is
            // visible — the user just initiated this, they want to see it.
            activeSessionId = target.id
        }
    }

    /// Approve the staged pending hand-off on `target`, optionally with
    /// an edited prompt. Clears the staging state and dispatches.
    func approvePendingHandOff(on target: AgentSession, editedPrompt: String? = nil) {
        guard let pending = target.pendingHandOff,
              let source = sessions.first(where: { $0.id == pending.sourceAgentId })
        else { target.pendingHandOff = nil; return }
        let text = (editedPrompt ?? pending.payload)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { target.pendingHandOff = nil; return }
        target.pendingHandOff = nil
        dispatchHandOff(from: source,
                        to: target,
                        payload: text,
                        hopsForTarget: pending.hopsRemaining,
                        includeProvenance: false)
    }

    /// Dismiss the staged pending hand-off without dispatching it.
    func dismissPendingHandOff(on target: AgentSession) {
        target.pendingHandOff = nil
    }

    /// Actually run a hand-off: tag the target with a "[Hand-off from X]"
    /// provenance line, set its chain source / remaining-hops, and
    /// send the payload as a user turn.
    private func dispatchHandOff(from source: AgentSession,
                                 to target: AgentSession,
                                 payload: String,
                                 hopsForTarget: Int,
                                 includeProvenance: Bool) {
        target.chainSourceId = source.id
        target.remainingHops = hopsForTarget
        let text: String
        if includeProvenance {
            let label = source.aiTitle?.isEmpty == false
                ? source.aiTitle!
                : ProjectNaming.name(forCwd: source.cwd)
            text = "[Hand-off from \(label)]\n\n\(payload)"
        } else {
            text = payload
        }
        target.send(text)
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

            var id: String { (claudeSessionId ?? "") + cwd }
        }
    }

    private func persist() {
        let snap = Snapshot(agents: sessions.map { s in
            Snapshot.SavedAgent(
                cwd: s.cwd,
                claudeSessionId: s.claudeSessionId ?? s.resumeSessionId,
                displayName: s.displayName,
                aiTitle: s.aiTitle
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
