import Foundation

/// How a tool call is described while it's happening.
///
/// The finished call has always rendered nicely — "Orchestrator started a
/// tab" on a grey pill. The LIVE line didn't: it showed the wire name,
/// truncated, as "Preparing mcp__manyagents__new_agent…". Same event, two
/// registers, and the raw one is the register of a third-party plugin
/// rather than the app's own machinery.
enum ToolNaming {
    static let manyAgentsPrefix = "mcp__manyagents__"

    /// ManyAgents' own MCP tools. These are the app talking to itself, and
    /// they get the app's own voice and icon rather than being presented
    /// like an outside integration.
    static func isManyAgents(_ name: String) -> Bool {
        name.hasPrefix(manyAgentsPrefix)
    }

    /// The bare tool name for a ManyAgents tool, e.g. "new_agent".
    static func manyAgentsAction(_ name: String) -> String? {
        guard isManyAgents(name) else { return nil }
        return String(name.dropFirst(manyAgentsPrefix.count))
    }

    /// What the status line says while this tool is running. Present tense,
    /// lower case — the caller capitalizes the first word.
    static func phase(for name: String) -> String {
        if let action = manyAgentsAction(name) {
            return manyAgentsPhase(action)
        }
        switch name {
        case "Bash":                         return "running Bash"
        case "Edit", "MultiEdit", "Write":   return "editing"
        case "Read", "NotebookEdit":         return "reading"
        case "Grep", "Glob":                 return "searching"
        case "WebFetch", "WebSearch":        return "searching the web"
        case "TodoWrite":                    return "planning"
        default: break
        }
        // Another server's MCP tool: name the server, since "search_threads"
        // alone doesn't say whose threads. mcp__claude_ai_Gmail__reply
        // reads as "Gmail: reply".
        if let (server, action) = mcpParts(name) {
            return "\(server): \(action)"
        }
        return "running \(name)"
    }

    /// Title for a tool card's header. Built-ins keep their familiar names
    /// ("Bash", "Edit"); everything reached over MCP gets read as words,
    /// with the server named when it isn't ours.
    static func cardTitle(for name: String) -> String {
        if let action = manyAgentsAction(name) {
            if let title = manyAgentsTitles[action] { return title }
            let words = humanize(action)
            return words.prefix(1).uppercased() + words.dropFirst()
        }
        guard let (server, action) = mcpParts(name) else { return name }
        return "\(server) · \(action)"
    }

    /// Where reading the name as words isn't enough — "preview_do" becomes
    /// "Preview do", which says nothing.
    private static let manyAgentsTitles: [String: String] = [
        "preview_do":            "Drive preview",
        "preview_look":          "Read preview",
        "open_preview":          "Open preview",
        "new_agent":             "Start a tab",
        "send_to_agent":         "Message a tab",
        "read_agent":            "Read a tab",
        "close_agent":           "Close a tab",
        "compact_agent":         "Compact a tab",
        "rename_agent":          "Rename a tab",
        "list_agents":           "The board",
        "set_notes":             "Notes",
        "notify_orchestrator":   "Ping the orchestrator",
        "delegate_orchestrator": "Hand over a repo",
        "remove_worktree":       "Remove a worktree",
    ]

    private static func manyAgentsPhase(_ action: String) -> String {
        switch action {
        case "list_agents":           return "checking the board"
        case "read_agent":            return "reading a tab"
        case "send_to_agent":         return "messaging a tab"
        case "new_agent":             return "starting a tab"
        case "rename_agent":          return "renaming a tab"
        case "compact_agent":         return "compacting a tab"
        case "close_agent":           return "closing a tab"
        case "set_notes":             return "updating its notes"
        case "mute_agent":            return "muting a tab"
        case "unmute_agent":          return "unmuting a tab"
        case "notify_orchestrator":   return "pinging the orchestrator"
        case "delegate_orchestrator": return "handing over a repo"
        case "remove_worktree":       return "removing a worktree"
        case "open_preview":          return "opening the preview"
        case "preview_look":          return "reading the preview"
        case "preview_do":            return "driving the preview"
        default:                      return humanize(action)
        }
    }

    /// Splits `mcp__<server>__<action>` into a readable server and action.
    /// The claude.ai connectors arrive as `mcp__claude_ai_Gmail__…`, where
    /// the `claude_ai_` half is plumbing the user never needs to see.
    static func mcpParts(_ name: String) -> (server: String, action: String)? {
        guard name.hasPrefix("mcp__") else { return nil }
        let body = String(name.dropFirst("mcp__".count))
        guard let range = body.range(of: "__") else { return nil }
        var server = String(body[body.startIndex..<range.lowerBound])
        let action = String(body[range.upperBound...])
        if server.hasPrefix("claude_ai_") {
            server = String(server.dropFirst("claude_ai_".count))
        }
        return (humanize(server, capitalized: true), humanize(action))
    }

    private static func humanize(_ s: String, capitalized: Bool = false) -> String {
        let words = s.split(whereSeparator: { $0 == "_" || $0 == "-" }).map(String.init)
        guard !words.isEmpty else { return s }
        guard capitalized else { return words.joined(separator: " ") }
        // Title case, but leave the joining words lower so
        // "claude-in-chrome" reads as "Claude in Chrome" rather than
        // "Claude In Chrome". An already-capitalized word is left exactly
        // as it came: "Gmail" must not become "GMail", and "Google_Drive"
        // must keep both capitals.
        let small: Set<String> = ["in", "of", "to", "the", "and", "for", "on", "at", "by"]
        return words.enumerated().map { i, w in
            if w.first?.isUppercase == true { return w }
            if i > 0, small.contains(w.lowercased()) { return w.lowercased() }
            return w.prefix(1).uppercased() + w.dropFirst()
        }.joined(separator: " ")
    }
}
