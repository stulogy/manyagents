import Foundation

/// One thing waiting on the user, from anywhere in the workspace.
///
/// With a dozen tabs running, the moment a tab stops and asks something is
/// the moment it disappears: the question lands in a transcript nobody is
/// looking at, and the only trace is a count in the sidebar that says four
/// tabs want you without saying what any of them want.
///
/// Two sources feed this, deliberately.
///
/// AUTOMATIC items come from state the app already tracks — a tab that
/// ended its turn on a question, a permission prompt, an MCP sign-in, a
/// turn that errored. They cost nothing, they cannot be forgotten, and
/// they work with no cooperation from any agent.
///
/// ESCALATED items come from an orchestrator calling `flag_for_user`. That
/// is the judgement the automatic signals can't make: a worker's blocker
/// bubbles to the orchestrator via notify_orchestrator, the orchestrator
/// decides whether it can settle it or whether it's genuinely the user's
/// call, and only the second kind lands here. Without the automatic half
/// underneath, an orchestrator that forgets to escalate produces silence —
/// which is the failure this is meant to fix, with extra steps.
struct AttentionItem: Identifiable, Equatable {
    enum Kind: Equatable {
        /// Needs an answer before work continues.
        case decision
        /// Worth knowing; nothing is blocked on it.
        case notice

        var sortRank: Int { self == .decision ? 0 : 1 }
    }

    /// Why this is here. The automatic cases carry their own icon and
    /// wording; `.flagged` is whatever the orchestrator wrote.
    enum Source: Equatable {
        case waiting            // turn ended asking something
        case question           // AskUserQuestion picker is open
        case permission         // a tool is waiting on allow/deny
        case mcpAuth(String)    // an MCP server needs signing in to
        case failed             // the turn ended on an error
        case flagged            // an orchestrator escalated it

        var icon: String {
            switch self {
            case .waiting:    return "hand.raised.fill"
            case .question:   return "questionmark.circle.fill"
            case .permission: return "lock.fill"
            case .mcpAuth:    return "person.badge.key.fill"
            case .failed:     return "exclamationmark.triangle.fill"
            case .flagged:    return "flag.fill"
            }
        }

        /// Ranks within a kind: a blocked tool call is more urgent than a
        /// tab that merely asked a question and can wait.
        var urgency: Int {
            switch self {
            case .permission: return 0
            case .mcpAuth:    return 1
            case .question:   return 2
            case .failed:     return 3
            case .waiting:    return 4
            case .flagged:    return 2
            }
        }
    }

    let id: String
    let sessionId: UUID
    /// Tab title at the time, so the row reads without a lookup.
    let tabLabel: String
    let projectName: String
    let kind: Kind
    let source: Source
    /// What it wants, in one line.
    let summary: String
    /// What the orchestrator would do absent an answer. The point of
    /// asking for this is that most items become one tap — and an
    /// orchestrator that can't state a default usually hasn't thought hard
    /// enough to be asking yet.
    let recommendation: String?
    /// When it stops mattering, in the orchestrator's own words — "before
    /// Tuesday", "Team Chat launches in 5 days". Asked to order its list,
    /// an orchestrator sorts by what expires soonest, so the drawer has to
    /// carry that or it reorders the list into something less useful than
    /// the message it replaced.
    let deadline: String?
    let raisedAt: Date

    static func sortsBefore(_ a: AttentionItem, _ b: AttentionItem) -> Bool {
        if a.kind.sortRank != b.kind.sortRank { return a.kind.sortRank < b.kind.sortRank }
        // A stated deadline beats one without. We can't parse "before
        // Tuesday" into a date and shouldn't pretend to — but an
        // orchestrator only writes one when something really is expiring.
        let aDue = a.deadline?.isEmpty == false, bDue = b.deadline?.isEmpty == false
        if aDue != bDue { return aDue }
        if a.source.urgency != b.source.urgency { return a.source.urgency < b.source.urgency }
        return a.raisedAt > b.raisedAt
    }
}

/// An orchestrator's escalation, held until the tab it belongs to moves on.
///
/// Deliberately NOT dismissible by hand. Everything here clears itself: an
/// automatic item goes when the tab stops waiting, an escalation goes when
/// that tab takes another turn (you answered, or it moved on without you).
/// The moment a list like this needs grooming it becomes another inbox to
/// ignore, which is precisely what it exists to prevent.
struct Escalation: Identifiable, Equatable {
    let id = UUID()
    let sessionId: UUID
    let kind: AttentionItem.Kind
    let summary: String
    let recommendation: String?
    let deadline: String?
    let raisedAt: Date
    /// The tab's turn count when this was raised. It clears once the tab
    /// has taken another turn, which is the signal that it either got its
    /// answer or carried on regardless.
    let turnMark: Int
}
