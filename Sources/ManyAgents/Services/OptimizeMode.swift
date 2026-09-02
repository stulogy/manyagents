import Foundation

/// Cost/performance controls for people running many orchestrators across
/// many projects and worktrees at once — each one piling up its own context
/// and dispatching tabs and subagents that pile up more, all on whatever
/// model the app defaults to. Disabled by default; opting in unlocks two
/// independent levers:
///
/// 1. A cheaper model for tabs an orchestrator spawns or dispatches. The
///    orchestrator itself (and any repo lead) keeps the real model — it's
///    the one doing the coordinating and needs to reason well; a tab it
///    hands a scoped task to often doesn't.
/// 2. A rolling auto-compact that fires well before the CLI's own
///    context-ceiling compaction, on every tab, orchestrators included.
///    Unlike the existing Compact button, the visible transcript is never
///    cleared — only the model's live context resets — so scrollback and
///    search keep working across it.
enum OptimizeMode {
    enum Keys {
        static let enabled = "manyagents.optimize.enabled"
        static let subagentModel = "manyagents.optimize.subagentModel"
        static let autoCompactThreshold = "manyagents.optimize.autoCompactThreshold"
    }

    enum Defaults {
        static let subagentModel = "claude-sonnet-5"
        /// 25% — frequent enough that a tab rarely nears the CLI's own
        /// ceiling, without compacting so often that the summarize turns
        /// themselves become a real cost.
        static let autoCompactThreshold = 0.25
    }

    /// Ceiling safety net for WORKER tabs, applied whether or not Optimize
    /// Mode is on. Optimize Mode's 25% is a cost decision the user opts
    /// into; this is a different thing — a tab that fills its window gets
    /// compacted by the CLI itself, mid-turn, in the middle of whatever it
    /// was doing. Doing it here instead means it happens between turns,
    /// while the tab is idle, with the transcript left intact.
    ///
    /// Orchestrators are deliberately excluded: their context IS the
    /// coordination state, and summarizing it unasked loses the thread of
    /// what every tab is doing. They still compact on the Optimize Mode
    /// path, or when the user asks.
    static let workerCeilingThreshold = 0.90

    static var enabled: Bool {
        UserDefaults.standard.bool(forKey: Keys.enabled)
    }

    /// Empty means "no override" — a picked-but-empty ("Default") choice is
    /// a legitimate way to say "leave subagent tabs on my normal model".
    static var subagentModel: String {
        UserDefaults.standard.string(forKey: Keys.subagentModel) ?? Defaults.subagentModel
    }

    /// Fraction of the context window (0..1) that triggers a rolling
    /// auto-compact. A never-set key reads back as 0.0 from UserDefaults,
    /// which would mean "always compact" rather than "unset" — treat it as
    /// the default instead.
    static var autoCompactThreshold: Double {
        let stored = UserDefaults.standard.double(forKey: Keys.autoCompactThreshold)
        return stored > 0 ? stored : Defaults.autoCompactThreshold
    }
}
