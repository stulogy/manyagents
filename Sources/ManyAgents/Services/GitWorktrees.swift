import Foundation

/// Reading and removing git worktrees.
///
/// The orchestrator cuts a worktree per parallel task, which is right — two
/// tabs sharing one checkout fight over HEAD — but nothing ever removed them.
/// One repo here reached 86 worktrees, ~13 GiB, most of them on branches that
/// merged weeks earlier and each carrying its own `node_modules`. Creating was
/// one tool call; removing was a manual chore nobody did.
///
/// So removal lives here, behind a safety gate: a worktree goes only when its
/// tree is clean AND its commits are somewhere else (merged into an
/// integration branch, or pushed to its upstream). Everything else is refused
/// with the reason, and `git worktree remove` runs WITHOUT `--force`, so git
/// gets the last word even if this check is wrong.
enum GitWorktrees {

    /// What a tab's directory is, relative to the project it belongs to.
    /// The sidebar draws a different glyph for each — every nested row used
    /// to wear the branch icon, which called a separately-cloned repo a
    /// worktree and a plain subfolder a branch.
    enum Kind {
        case root           // the project root itself
        case worktree       // `.git` FILE pointing at a main repo
        case nestedRepo     // its own `.git` DIRECTORY, inside another repo
        case subdirectory   // no `.git` at all, just a folder in the project
    }

    static func kind(forCwd cwd: String) -> Kind {
        let path = cwd.hasSuffix("/") ? String(cwd.dropLast()) : cwd
        kindLock.lock()
        if let hit = kindCache[path] { kindLock.unlock(); return hit }
        kindLock.unlock()
        let resolved = resolveKind(path)
        kindLock.lock()
        kindCache[path] = resolved
        kindLock.unlock()
        return resolved
    }

    /// Cached forever, like `projectRoot`: a directory does not change from
    /// worktree to clone under a running app. A directory that is DELETED is
    /// a different question, and the sidebar already flags that separately.
    private static var kindCache: [String: Kind] = [:]
    private static let kindLock = NSLock()

    private static func resolveKind(_ path: String) -> Kind {
        if ProjectNaming.projectRoot(forCwd: path) == path { return .root }
        let dotGit = (path as NSString).appendingPathComponent(".git")
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dotGit, isDirectory: &isDir) else {
            return .subdirectory
        }
        return isDir.boolValue ? .nestedRepo : .worktree
    }

    /// Whether this worktree can go, and the sentence explaining either way.
    struct Safety {
        let removable: Bool
        /// User-facing reason: "merged into main", "3 unpushed commits".
        let reason: String
    }

    /// Branches that count as "the work landed". Checked in order; the first
    /// that exists in the repo is used.
    private static let integrationBranches = ["origin/main", "origin/master", "origin/dev"]

    /// Inspect a worktree without touching it. Runs git, so call it off the
    /// main thread (it is `nonisolated` and every caller awaits it).
    static func safety(ofWorktree path: String) -> Safety {
        guard kind(forCwd: path) == .worktree else {
            return Safety(removable: false, reason: "not a git worktree")
        }
        let dirty = run(["status", "--porcelain"], in: path).out
            .split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        if !dirty.isEmpty {
            let n = dirty.count
            return Safety(removable: false,
                          reason: "\(n) uncommitted change\(n == 1 ? "" : "s")")
        }
        let head = run(["rev-parse", "HEAD"], in: path).out
        guard !head.isEmpty else {
            return Safety(removable: false, reason: "can't read HEAD")
        }
        for branch in integrationBranches {
            guard run(["rev-parse", "--verify", "-q", branch], in: path).code == 0 else { continue }
            if run(["merge-base", "--is-ancestor", head, branch], in: path).code == 0 {
                return Safety(removable: true,
                              reason: "merged into \(branch.replacingOccurrences(of: "origin/", with: ""))")
            }
        }
        let upstream = run(["rev-parse", "--abbrev-ref", "@{u}"], in: path)
        guard upstream.code == 0, !upstream.out.isEmpty else {
            return Safety(removable: false, reason: "branch was never pushed")
        }
        let ahead = Int(run(["rev-list", "--count", "\(upstream.out)..HEAD"], in: path).out) ?? 0
        if ahead == 0 {
            return Safety(removable: true, reason: "pushed to \(upstream.out)")
        }
        return Safety(removable: false,
                      reason: "\(ahead) unpushed commit\(ahead == 1 ? "" : "s")")
    }

    /// Remove the worktree. Re-checks safety first — the caller's verdict may
    /// be seconds old, and an agent can have written a file since. Never
    /// passes `--force`: if git disagrees, git wins and the reason comes back.
    static func remove(worktree path: String) -> Result<String, RemovalError> {
        let verdict = safety(ofWorktree: path)
        guard verdict.removable else {
            return .failure(.unsafe(verdict.reason))
        }
        // `git worktree remove` is run FROM the worktree: git resolves the
        // administrative files from there, so the main repo's path never has
        // to be worked out separately.
        let result = run(["worktree", "remove", path], in: path)
        guard result.code == 0 else {
            return .failure(.git(result.err.isEmpty ? result.out : result.err))
        }
        return .success(verdict.reason)
    }

    enum RemovalError: Error {
        /// Refused here: uncommitted or unpushed work would be lost.
        case unsafe(String)
        /// git refused (locked, submodules, something we didn't model).
        case git(String)

        var message: String {
            switch self {
            case .unsafe(let why): return why
            case .git(let why): return why
            }
        }
    }

    // MARK: - git

    private static func run(_ args: [String], in dir: String) -> (code: Int32, out: String, err: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-C", dir] + args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        // A worktree whose directory was deleted makes git exit non-zero
        // rather than hang, so no timeout is needed here.
        do { try p.run() } catch { return (127, "", "\(error)") }
        let o = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let e = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        p.waitUntilExit()
        return (p.terminationStatus,
                o.trimmingCharacters(in: .whitespacesAndNewlines),
                e.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
