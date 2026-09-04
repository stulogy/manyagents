import Foundation

/// A log of things that were asked of you and might otherwise be lost.
///
/// The first version of this was a live view of "which tabs are idle",
/// which turned out to be the wrong thing entirely: it filled with
/// completion reports ("Done. Three files written, builds clean") because
/// a tab that has finished is also a tab that isn't running, and it emptied
/// itself the moment a tab moved on — losing precisely the question it was
/// supposed to hold onto.
///
/// This is a log, not a view. An agent asks "do you want me to go ahead
/// and build this?", you're deep in something else and never see it, and
/// the entry stays until it's answered or you say it's done. Entries are
/// appended once and persist across launches.
struct AttentionEntry: Identifiable, Codable, Equatable {
    enum Kind: String, Codable {
        /// Work is stopped until you answer.
        case decision
        /// Worth knowing; nothing is blocked.
        case notice
    }

    let id: UUID
    let sessionId: UUID
    /// Captured at the time. The tab may be renamed or closed later, and
    /// the entry still has to read as something.
    let tabLabel: String
    let projectName: String
    let kind: Kind
    /// What was actually asked, in the agent's own words.
    let text: String
    /// What the orchestrator would do absent an answer, when it flagged
    /// this deliberately. Turns most rows into a one-tap yes.
    let recommendation: String?
    /// Carried verbatim — "before Tuesday". Sorts to the top.
    let deadline: String?
    let raisedAt: Date
    /// Set when it stops needing you: you replied to that tab, or you
    /// marked it done by hand.
    var resolvedAt: Date?
    /// Message count in the tab when this was raised, so a later reply can
    /// be recognised as the answer.
    let markAtRaise: Int

    var isOpen: Bool { resolvedAt == nil }

    init(sessionId: UUID, tabLabel: String, projectName: String, kind: Kind,
         text: String, recommendation: String? = nil, deadline: String? = nil,
         markAtRaise: Int) {
        self.id = UUID()
        self.sessionId = sessionId
        self.tabLabel = tabLabel
        self.projectName = projectName
        self.kind = kind
        self.text = text
        self.recommendation = recommendation
        self.deadline = deadline
        self.raisedAt = Date()
        self.resolvedAt = nil
        self.markAtRaise = markAtRaise
    }

    static func sortsBefore(_ a: AttentionEntry, _ b: AttentionEntry) -> Bool {
        if a.kind != b.kind { return a.kind == .decision }
        // A stated deadline outranks one without. We can't parse "before
        // Tuesday" into a date and shouldn't pretend to — but an
        // orchestrator only writes one when something really is expiring.
        let aDue = a.deadline?.isEmpty == false, bDue = b.deadline?.isEmpty == false
        if aDue != bDue { return aDue }
        return a.raisedAt > b.raisedAt
    }
}

/// Something blocking a tab RIGHT NOW that isn't a question: a tool call
/// suspended on allow/deny, an MCP server wanting a sign-in.
///
/// These stay derived rather than logged, because they're modal — they
/// exist only while the tab is stopped on them, and logging them would
/// leave rows describing a prompt that closed minutes ago.
struct LiveBlocker: Identifiable {
    let id: String
    let sessionId: UUID
    let tabLabel: String
    let projectName: String
    let text: String
    let icon: String
}
