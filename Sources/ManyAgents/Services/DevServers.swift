import Foundation
import Combine

/// Watches for dev servers agents started and never stopped.
///
/// This is not hypothetical tidiness. Seventeen `next-server` processes
/// accumulated across seventeen worktrees — one per checkout, each started
/// to verify some change and then left running. Idle, 0% CPU, swapped out,
/// and between them holding about 40GB of footprint. macOS bills a parent
/// for its children, so the Force Quit panel read "ManyAgents 30.17 GB"
/// while the app itself was 68MB, and the whole machine started pausing
/// applications to stay alive. One had been up for five days.
///
/// Agents can't be relied on to clean these up. A tab that started a server
/// may be compacted, closed, or simply finished, and the process outlives
/// all three. So the app watches instead: count them, notice when it has
/// got out of hand, and offer one button.
///
/// Deliberately advisory. Killing a server the user is looking at, on a
/// timer, without asking, would be a worse bug than the one it fixes.
@MainActor
final class DevServers: ObservableObject {
    static let shared = DevServers()

    /// One dev server, which on disk is a CHAIN of processes: `npm run dev`
    /// spawns `node …/next dev` spawns `next-server`. Counting those
    /// separately reported five servers where there were two, tripping the
    /// warning constantly — and killing only the leaf left the npm wrapper
    /// to start it straight back up.
    struct Server: Identifiable, Equatable {
        let id: String         // directory — the thing that is actually one server
        let pids: [Int32]      // the whole chain, oldest first
        let label: String
        let directory: String
        let startedAt: Date
        var age: TimeInterval { Date().timeIntervalSince(startedAt) }
    }

    @Published private(set) var servers: [Server] = []

    /// Over this many at once and something is being left behind — one per
    /// checkout you're actively verifying is a handful, not a dozen.
    nonisolated static let crowdThreshold = 5
    /// A server older than this has outlived whatever asked for it.
    nonisolated static let staleAfter: TimeInterval = 4 * 3600

    var stale: [Server] { servers.filter { $0.age > Self.staleAfter } }

    /// Worth telling the user about: too many, or old enough to be
    /// forgotten. Silent otherwise — a couple of fresh servers is just
    /// work in progress.
    var shouldWarn: Bool { servers.count >= Self.crowdThreshold || !stale.isEmpty }

    var summary: String {
        let n = servers.count
        let oldest = servers.map(\.age).max() ?? 0
        let hours = Int(oldest / 3600)
        let age = hours >= 24 ? "\(hours / 24)d" : (hours >= 1 ? "\(hours)h" : "under an hour")
        return "\(n) dev server\(n == 1 ? "" : "s") still running, oldest \(age) old. "
             + "They hold memory even when idle — a forgotten one can swap out and grow to several GB."
    }

    private var timer: AnyCancellable?

    private init() {}

    func start() {
        refresh()
        // Two minutes: these accumulate over hours, and scanning the
        // process table more often would cost more than it catches.
        timer = Timer.publish(every: 120, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.refresh() }
    }

    /// Signatures of the long-lived servers a dev loop starts. Deliberately
    /// narrow — matching "node" would sweep up every build and test run.
    private nonisolated static let signatures: [(needle: String, label: String)] = [
        ("next-server", "next dev"),
        ("next dev", "next dev"),
        ("vite", "vite"),
        ("webpack-dev-server", "webpack"),
        ("react-scripts start", "react-scripts"),
        ("nuxt dev", "nuxt"),
        ("ng serve", "ng serve"),
        ("rails server", "rails s"),
        ("http.server", "python http.server"),
        // The wrappers. Matched so they're killed with the chain, never
        // counted separately — they collapse into their directory's entry.
        ("npm run dev", "next dev"),
        ("yarn dev", "next dev"),
        ("pnpm dev", "next dev"),
    ]

    func refresh() {
        Task.detached(priority: .utility) {
            let found = Self.scan()
            await MainActor.run { self.servers = found }
        }
    }

    private nonisolated static func scan() -> [Server] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["ax", "-o", "pid=,lstart=,command="]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        guard (try? p.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard let text = String(data: data, encoding: .utf8) else { return [] }

        let fmt = DateFormatter()
        fmt.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        fmt.locale = Locale(identifier: "en_US_POSIX")

        var out: [(Int32, String, Date)] = []
        for line in text.split(separator: "\n") {
            let s = String(line)
            let parts = s.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count > 6, let pid = Int32(parts[0]) else { continue }
            // `lstart` is five fixed fields: "Wed Sep  2 08:44:29 2026".
            let stamp = parts[1...5].joined(separator: " ")
            let command = s.range(of: stamp).map { String(s[$0.upperBound...]) } ?? s
            guard let match = signatures.first(where: { command.contains($0.needle) })
            else { continue }
            // Not the shell that MENTIONS a dev command. An agent's
            // `zsh -c "... npm run dev ..."` matched on text alone, and its
            // cwd is the project root rather than the server's, so it
            // invented a whole extra "server" that could never be stopped.
            let exe = command.trimmingCharacters(in: .whitespaces)
                .split(separator: " ").first.map(String.init) ?? ""
            let shell = exe.hasSuffix("/zsh") || exe.hasSuffix("/bash")
                || exe.hasSuffix("/sh") || exe == "zsh" || exe == "bash" || exe == "sh"
            if shell { continue }
            // ps collapses lstart's day padding differently; try both.
            let started = fmt.date(from: stamp)
                ?? fmt.date(from: stamp.replacingOccurrences(of: "  ", with: " "))
                ?? Date()
            out.append((pid, match.label, started))
        }
        // Collapse the chain: everything serving the same directory is one
        // server. Its age is the oldest link's — the wrapper starts first.
        var byDirectory: [String: [(pid: Int32, label: String, started: Date)]] = [:]
        for entry in out {
            let dir = Self.workingDirectory(of: entry.0)
            guard !dir.isEmpty else { continue }
            byDirectory[dir, default: []].append((entry.0, entry.1, entry.2))
        }
        return byDirectory.map { dir, group in
            let sorted = group.sorted { $0.started < $1.started }
            return Server(id: dir,
                          pids: sorted.map(\.pid),
                          label: sorted.first?.label ?? "dev server",
                          directory: dir,
                          startedAt: sorted.first?.started ?? Date())
        }
        .sorted { $0.startedAt < $1.startedAt }
    }

    /// Where it's serving from, so the row says which checkout rather than
    /// just a pid. Best-effort: lsof is slow enough that a failure here
    /// must not stop the warning appearing.
    private nonisolated static func workingDirectory(of pid: Int32) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        p.arguments = ["-a", "-p", "\(pid)", "-d", "cwd", "-Fn"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        guard (try? p.run()) != nil else { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let text = String(data: data, encoding: .utf8) ?? ""
        guard let line = text.split(separator: "\n").first(where: { $0.hasPrefix("n") })
        else { return "" }
        return ProjectNaming.prettyCwd(String(line.dropFirst()))
    }

    /// SIGTERM, then SIGKILL for anything that ignores it — two of the
    /// seventeen did, including the five-day-old one.
    func stopAll() { stop(pids: servers.flatMap(\.pids)) }

    func stop(_ server: Server) { stop(pids: server.pids) }

    /// Parent first, so a supervisor can't restart the child we just
    /// killed — which is why stopping a server appeared not to work.
    /// SIGTERM, then SIGKILL for whatever ignores it.
    private func stop(pids: [Int32]) {
        for pid in pids { kill(pid, SIGTERM) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            for pid in pids where kill(pid, 0) == 0 { kill(pid, SIGKILL) }
            self?.refresh()
        }
    }
}
