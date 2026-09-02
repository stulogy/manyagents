import Foundation

enum ProjectNaming {
    /// Just the last path component (lowercased), trimmed of trailing slashes.
    static func name(forCwd cwd: String) -> String {
        let trimmed = cwd.hasSuffix("/") ? String(cwd.dropLast()) : cwd
        return (trimmed as NSString).lastPathComponent
    }

    /// "~/Sites/foo" form, for display.
    static func prettyCwd(_ cwd: String) -> String {
        let home = NSHomeDirectory()
        if cwd.hasPrefix(home) {
            return "~" + cwd.dropFirst(home.count)
        }
        return cwd
    }

    /// The directory that owns this one's PROJECT identity: the OUTERMOST git
    /// repo enclosing it. For a git worktree that's the main repo it was cut
    /// from; for a repo cloned inside another repo it's the outer one; for
    /// anything else, itself.
    ///
    /// Worktrees are how the orchestrator runs tabs in parallel without them
    /// treading on each other, and every one of them sat in a sibling
    /// directory (`~/Sites/adapther-port-today`). Keying projects on the raw
    /// cwd made each its own top-level project — so the tabs vanished off the
    /// orchestrator's board, couldn't ping it, and produced no board digest,
    /// because all of that routing looks for an orchestrator "in this project".
    ///
    /// Climbing PAST the nearest repo is what holds a workspace together: in
    /// `~/Sites/uhp` the product repos are cloned into (gitignored) `dev/`, so
    /// stopping at the first `.git` split one project into a dozen unrelated
    /// top-level entries, and a tab opened in `uhp/dev/operative-builder` fell
    /// off the uhp orchestrator's board entirely.
    ///
    /// Read straight off disk rather than by shelling out to git: a worktree's
    /// `.git` is a FILE containing `gitdir: /path/to/main/.git/worktrees/<name>`,
    /// which names the main repo without spawning a process on the main thread.
    static func projectRoot(forCwd cwd: String) -> String {
        let key = cwd.hasSuffix("/") ? String(cwd.dropLast()) : cwd
        cacheLock.lock()
        if let hit = rootCache[key] { cacheLock.unlock(); return hit }
        cacheLock.unlock()

        let resolved = resolveProjectRoot(key)

        cacheLock.lock()
        rootCache[key] = resolved
        cacheLock.unlock()
        return resolved
    }

    /// The REPO a directory belongs to: the nearest enclosing git repo, with
    /// a worktree resolved to the main repo it was cut from.
    ///
    /// This is the unit a tab actually works in — `uhp/dev/UHP-OPS-Agent` and
    /// six worktrees cut from it are one repo, six checkouts. `projectRoot`
    /// climbs further, to the workspace that owns the board (`uhp`), so the
    /// two answers differ for a repo cloned inside another.
    static func repoRoot(forCwd cwd: String) -> String {
        let key = cwd.hasSuffix("/") ? String(cwd.dropLast()) : cwd
        repoLock.lock()
        if let hit = repoCache[key] { repoLock.unlock(); return hit }
        repoLock.unlock()
        let resolved = nearestRepo(from: key) ?? key
        repoLock.lock()
        repoCache[key] = resolved
        repoLock.unlock()
        return resolved
    }

    private static var repoCache: [String: String] = [:]
    private static let repoLock = NSLock()

    /// Which CHECKOUT of its repo a tab is in: the worktree's own name, with
    /// the repo's name trimmed off the front ("UHP-OPS-Agent-mdrender" under
    /// "UHP-OPS-Agent" reads as "mdrender"). Empty when the tab sits in the
    /// repo itself. Tabs of one repo are otherwise indistinguishable in the
    /// tab strip once worktrees stopped getting rows of their own.
    static func checkoutLabel(forCwd cwd: String) -> String {
        let key = cwd.hasSuffix("/") ? String(cwd.dropLast()) : cwd
        let repo = repoRoot(forCwd: key)
        guard repo != key else { return "" }
        let own = name(forCwd: key)
        let repoName = name(forCwd: repo)
        if own.hasPrefix(repoName + "-") { return String(own.dropFirst(repoName.count + 1)) }
        return own
    }

    /// How a tab's directory reads against its project root: the path below
    /// the project (`dev/operative-builder`), or the bare directory name when
    /// it sits outside it (a worktree in a sibling directory). Empty when the
    /// tab is simply at the project root.
    static func subprojectLabel(forCwd cwd: String) -> String {
        let key = cwd.hasSuffix("/") ? String(cwd.dropLast()) : cwd
        let root = projectRoot(forCwd: key)
        if key == root { return "" }
        if key.hasPrefix(root + "/") { return String(key.dropFirst(root.count + 1)) }
        return name(forCwd: key)
    }

    /// Does this directory still exist? Worktrees get deleted out from under
    /// open tabs — the cleanup that removes six port worktrees leaves six
    /// tabs pointing at nothing, and the sidebar showed them as healthy.
    ///
    /// Unlike `projectRoot`, this answer CHANGES under a running app, so it
    /// carries a short TTL rather than a permanent cache: long enough that a
    /// sidebar layout pass isn't a burst of stat() calls, short enough that a
    /// deletion shows up while the user is still looking at it.
    static func directoryExists(_ path: String) -> Bool {
        let key = path.hasSuffix("/") ? String(path.dropLast()) : path
        let now = Date()
        cacheLock.lock()
        if let hit = existsCache[key], now.timeIntervalSince(hit.at) < 5 {
            cacheLock.unlock()
            return hit.exists
        }
        cacheLock.unlock()

        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: key, isDirectory: &isDir) && isDir.boolValue

        cacheLock.lock()
        existsCache[key] = (exists, now)
        cacheLock.unlock()
        return exists
    }

    private static var existsCache: [String: (exists: Bool, at: Date)] = [:]

    /// Paths don't move under a running app, and this is read on every
    /// sidebar layout pass, so the filesystem probe happens once per cwd.
    private static var rootCache: [String: String] = [:]
    private static let cacheLock = NSLock()

    private static func resolveProjectRoot(_ cwd: String) -> String {
        guard var root = nearestRepo(from: cwd) else { return cwd }
        // Climb out of nested repos. Only a repo that genuinely CONTAINS the
        // one below it takes over — a worktree redirect can point sideways,
        // and following that would wander into an unrelated project (and,
        // without the ancestor check, could fail to terminate).
        while true {
            let above = (root as NSString).deletingLastPathComponent
            guard above != root,
                  let outer = nearestRepo(from: above),
                  root.hasPrefix(outer + "/")
            else { break }
            root = outer
        }
        return root
    }

    /// The nearest git repo at or above `dir`, worktree-resolved to the main
    /// repo it was cut from. nil when the walk finds none.
    ///
    /// The walk stops AT the home directory — a dotfiles repo at `~` would
    /// otherwise adopt every project on the machine as one giant "home".
    /// The CHECKOUT a directory sits in: a worktree's own root, or the repo
    /// root when it isn't one. Unlike `repoRoot`, this does NOT collapse a
    /// worktree into the repo it was cut from.
    ///
    /// This is the unit a dev server belongs to. Two worktrees of one repo
    /// run two servers on two ports — `:3015` and `:3020` — and keying the
    /// preview by repo made them fight over a single panel, each one
    /// navigating it away from the other.
    static func checkoutRoot(forCwd cwd: String) -> String {
        let key = cwd.hasSuffix("/") ? String(cwd.dropLast()) : cwd
        checkoutLock.lock()
        if let hit = checkoutCache[key] { checkoutLock.unlock(); return hit }
        checkoutLock.unlock()
        let resolved = nearestCheckout(from: key) ?? repoRoot(forCwd: key)
        checkoutLock.lock()
        checkoutCache[key] = resolved
        checkoutLock.unlock()
        return resolved
    }

    private static var checkoutCache: [String: String] = [:]
    private static let checkoutLock = NSLock()

    /// Nearest directory holding a `.git` of either kind — stopping at the
    /// worktree rather than following its pointer home.
    private static func nearestCheckout(from dir: String) -> String? {
        let fm = FileManager.default
        let home = NSHomeDirectory()
        var d = dir
        while d != "/" && d != home && !d.isEmpty {
            if fm.fileExists(atPath: (d as NSString).appendingPathComponent(".git")) {
                return d
            }
            let parent = (d as NSString).deletingLastPathComponent
            if parent == d { break }
            d = parent
        }
        return nil
    }

    private static func nearestRepo(from dir: String) -> String? {
        let fm = FileManager.default
        let home = NSHomeDirectory()
        var d = dir
        while d != "/" && d != home && !d.isEmpty {
            let dotGit = (d as NSString).appendingPathComponent(".git")
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: dotGit, isDirectory: &isDir) {
                // A real .git directory — this IS a repo root.
                if isDir.boolValue { return d }
                // A .git file — a worktree pointing at its main repo.
                return mainRepo(fromGitFile: dotGit) ?? d
            }
            let parent = (d as NSString).deletingLastPathComponent
            if parent == d { break }
            d = parent
        }
        return nil
    }

    /// `gitdir: /Users/me/Sites/app/.git/worktrees/app-feature` → `/Users/me/Sites/app`.
    private static func mainRepo(fromGitFile path: String) -> String? {
        guard let raw = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard line.hasPrefix("gitdir:") else { return nil }
        let gitDir = String(line.dropFirst("gitdir:".count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let range = gitDir.range(of: "/.git/worktrees/") else { return nil }
        return String(gitDir[gitDir.startIndex..<range.lowerBound])
    }
}
