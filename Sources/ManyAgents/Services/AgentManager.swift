import Foundation
import Combine

/// Top-level state container. Owns every active AgentSession and persists
/// enough state to restore conversations across launches via `--resume`.
@MainActor
final class AgentManager: ObservableObject {
    @Published private(set) var sessions: [AgentSession] = []
    @Published var activeSessionId: UUID?

    private static let snapshotKey = "manyagents.snapshot.v1"
    private var sessionSubscriptions: [UUID: AnyCancellable] = [:]
    private var cancellables: Set<AnyCancellable> = []
    private let sessionsDirty = PassthroughSubject<Void, Never>()

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
        sessions.append(session)
        activeSessionId = session.id
        session.connect()
        return session
    }

    /// Terminate the agent and drop it from the list.
    func close(_ session: AgentSession) {
        session.disconnect()
        sessionSubscriptions.removeValue(forKey: session.id)
        sessions.removeAll { $0.id == session.id }
        if activeSessionId == session.id {
            let sameProject = sessions.filter { $0.cwd == session.cwd }
            activeSessionId = sameProject.last?.id ?? sessions.last?.id
        }
        persist()
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

    /// Activate the most-recent session in `project`. If no session is
    /// currently active for that cwd, fall back to the last one added.
    func activate(project: ProjectEntry) {
        if let active = activeSession, active.cwd == project.cwd { return }
        if let last = project.sessions.last {
            activeSessionId = last.id
        }
    }

    // MARK: - Persistence

    private struct Snapshot: Codable {
        let agents: [SavedAgent]
        struct SavedAgent: Codable {
            let cwd: String
            let claudeSessionId: String?
            let displayName: String
            let aiTitle: String?
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

    /// Reload previously-running agents from the persisted snapshot. Called
    /// once at app launch.
    func restorePersisted() {
        guard let data = UserDefaults.standard.data(forKey: Self.snapshotKey),
              let snap = try? JSONDecoder().decode(Snapshot.self, from: data)
        else { return }
        let fm = FileManager.default
        for a in snap.agents {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: a.cwd, isDirectory: &isDir), isDir.boolValue else {
                continue
            }
            let session = spawn(cwd: a.cwd, resumeSessionId: a.claudeSessionId)
            session.displayName = a.displayName
            session.aiTitle = a.aiTitle
            // Replay the prior transcript so the conversation pane shows
            // history. Without this the restored tab looks blank ("Ready"
            // with no messages) even though the model has full context.
            if let sid = a.claudeSessionId, !sid.isEmpty {
                let prior = TranscriptLoader.load(cwd: a.cwd, sessionId: sid)
                if !prior.isEmpty {
                    session.messages = prior
                    session.status = .waiting
                }
            }
        }
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
