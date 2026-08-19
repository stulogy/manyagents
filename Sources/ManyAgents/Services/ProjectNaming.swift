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

    /// The directory that owns this one's PROJECT identity: for a git
    /// worktree, the main repo it was cut from; for anything else, itself.
    ///
    /// Worktrees are how the orchestrator runs tabs in parallel without them
    /// treading on each other, and every one of them sat in a sibling
    /// directory (`~/Sites/adapther-port-today`). Keying projects on the raw
    /// cwd made each its own top-level project — so the tabs vanished off the
    /// orchestrator's board, couldn't ping it, and produced no board digest,
    /// because all of that routing looks for an orchestrator "in this project".
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

    /// Paths don't move under a running app, and this is read on every
    /// sidebar layout pass, so the filesystem probe happens once per cwd.
    private static var rootCache: [String: String] = [:]
    private static let cacheLock = NSLock()

    private static func resolveProjectRoot(_ cwd: String) -> String {
        let fm = FileManager.default
        // Walk up: the cwd handed to a tab can sit below the repo root. Stop
        // AT the home directory — a dotfiles repo at ~ would otherwise adopt
        // every project on the machine as one giant "home" project.
        let home = NSHomeDirectory()
        var dir = cwd
        while dir != "/" && dir != home && !dir.isEmpty {
            let dotGit = (dir as NSString).appendingPathComponent(".git")
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: dotGit, isDirectory: &isDir) {
                // A real .git directory — this IS the main repo.
                if isDir.boolValue { return dir }
                // A .git file — a worktree pointing at its main repo.
                if let main = mainRepo(fromGitFile: dotGit) { return main }
                return dir
            }
            let parent = (dir as NSString).deletingLastPathComponent
            if parent == dir { break }
            dir = parent
        }
        return cwd
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
