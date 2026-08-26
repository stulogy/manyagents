import Foundation
import CryptoKit
import Combine
import UIKit

/// The phone half of the link. Mirrors `PhoneLink.swift` on the Mac: same
/// relay, same room, same AES-GCM envelope. Everything it shows comes
/// straight from a tab's own state — there is no model in between
/// deciding what you get to see.
@MainActor
final class MacLink: ObservableObject {

    struct Pairing: Codable, Equatable {
        var relay: String
        var room: String
        var key: String        // base64, 32 bytes
        var access: String     // relay door token
        var mac: String

        /// Parses the `manyagents://pair?d=<base64 json>` string the Mac's
        /// QR encodes.
        static func parse(_ raw: String) -> Pairing? {
            guard let comps = URLComponents(string: raw),
                  comps.scheme == "manyagents",
                  let d = comps.queryItems?.first(where: { $0.name == "d" })?.value,
                  let json = Data(base64Encoded: d),
                  let obj = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any],
                  let relay = obj["relay"] as? String,
                  let room = obj["room"] as? String,
                  let key = obj["key"] as? String
            else { return nil }
            return Pairing(relay: relay, room: room, key: key,
                           access: obj["access"] as? String ?? "",
                           mac: obj["mac"] as? String ?? "Mac")
        }
    }

    struct Tab: Identifiable, Equatable {
        let id: String
        var title: String
        /// The repo this tab works in — the grouping unit, matching the Mac.
        var project: String
        var repo: String
        /// The workspace the repo sits in — `~/Sites/uhp` for a repo cloned
        /// at `~/Sites/uhp/dev/UHP-OPS-Agent`. Equal to `repo` for a repo
        /// that isn't nested in one.
        var workspace: String
        var workspaceName: String
        /// Which checkout of that repo: a worktree's own name with the repo
        /// prefix trimmed, empty when the tab is in the repo itself.
        var checkout: String
        var cwd: String
        var status: String
        var blocked: String?          // "permission" | "question" | nil
        var permissionTool: String?

        var isWorktree: Bool { !checkout.isEmpty }

        var isBusy: Bool { status == "running" }
        /// Only a permission prompt or an unanswered question actually
        /// wants you. "waiting" is just what a tab looks like after it
        /// finishes a turn — treating that as needing attention put every
        /// tab in the urgent pile, which is the same as having no pile.
        var needsYou: Bool { blocked != nil }
    }

    struct Msg: Identifiable, Equatable {
        /// The message's index in the tab's own transcript. Identity has to
        /// come from the Mac: a locally-generated UUID differs on every
        /// decode, which made every re-sent tail look like new messages.
        let seq: Int
        let role: String
        let text: String
        var blocks: [Block] = []

        var id: Int { seq }
        /// Negative sequences are local echoes not yet confirmed by the Mac.
        var isPending: Bool { seq < 0 }
    }

    /// Mirrors what the Mac sends: prose, a tool call reduced to one line,
    /// or a tool failure. Successful tool output never crosses — the agent
    /// already said what it found.
    enum Block: Equatable {
        case text(String)
        case tool(name: String, detail: String)
        case toolError(String)
        case image
    }

    enum Connection: Equatable {
        case idle, connecting, connected, macOffline
        case failed(String)
    }

    @Published private(set) var connection: Connection = .idle
    @Published private(set) var board: [Tab] = []
    @Published private(set) var messages: [String: [Msg]] = [:]   // tab id → transcript
    @Published private(set) var sending = false
    @Published var pairing: Pairing? {
        didSet {
            guard pairing != oldValue else { return }
            persistPairing()
            reconnect()
        }
    }

    private var task: URLSessionWebSocketTask?
    private let session = URLSession(configuration: .default)
    private var key: SymmetricKey?
    private var pending: [String: ([String: Any]) -> Void] = [:]
    private var reconnectAttempts = 0
    private var watchedTab: String?

    init() {
        if let raw = UserDefaults.standard.data(forKey: "pairing"),
           let p = try? JSONDecoder().decode(Pairing.self, from: raw) {
            pairing = p
            persistPairing()   // no-op, keeps didSet symmetry
            reconnect()
        }
    }

    private func persistPairing() {
        if let p = pairing, let data = try? JSONEncoder().encode(p) {
            UserDefaults.standard.set(data, forKey: "pairing")
        } else {
            UserDefaults.standard.removeObject(forKey: "pairing")
        }
    }

    func unpair() {
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        board = []
        messages = [:]
        connection = .idle
        pairing = nil
    }

    // MARK: - Socket

    func reconnect() {
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        guard let p = pairing, let keyData = Data(base64Encoded: p.key), keyData.count == 32 else {
            connection = .idle
            return
        }
        key = SymmetricKey(data: keyData)

        var comps = URLComponents(string: p.relay + "/ma/v1/socket")
        comps?.queryItems = [
            .init(name: "room", value: p.room),
            .init(name: "role", value: "phone"),
            .init(name: "key", value: p.access),
        ]
        guard let url = comps?.url else {
            connection = .failed("That pairing code has a bad relay address.")
            return
        }
        connection = .connecting
        let t = session.webSocketTask(with: url)
        task = t
        t.resume()
        receive()
    }

    private func receive() {
        task?.receive { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .failure:
                    self.connection = .connecting
                    self.scheduleReconnect()
                case .success(let msg):
                    self.reconnectAttempts = 0
                    if case .string(let text) = msg { self.handleFrame(text) }
                    self.receive()
                }
            }
        }
    }

    private func scheduleReconnect() {
        reconnectAttempts += 1
        let delay = min(pow(2.0, Double(min(reconnectAttempts, 5))), 30)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.reconnect()
        }
    }

    private func handleFrame(_ text: String) {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let t = obj["t"] as? String
        else { return }

        switch t {
        case "hello":
            connection = .connected
            identify()
            refreshBoard()
        case "peer":
            if obj["role"] as? String == "mac" {
                let up = obj["present"] as? Bool == true
                connection = up ? .connected : .macOffline
                if up { refreshBoard() }
            }
        case "env":
            guard let sealed = obj["data"] as? String, let payload = open(sealed) else { return }
            route(payload)
        default:
            break
        }
    }

    private func route(_ payload: [String: Any]) {
        // A reply to something we asked.
        if let rid = payload["rid"] as? String, let cb = pending.removeValue(forKey: rid) {
            cb(payload)
            return
        }
        // Or a push from the Mac.
        switch payload["ev"] as? String {
        case "board":
            board = Self.decodeBoard(payload["board"])
        case "messages":
            if let tab = payload["tab"] as? String {
                merge(Self.decodeMessages(payload["messages"]), into: tab)
            }
        default:
            break
        }
    }

    /// Fold a tail into what we already hold, keyed by sequence, so a
    /// push overwrites the messages it covers and leaves earlier
    /// scrollback alone. Local echoes drop out once the Mac confirms
    /// anything newer.
    private func merge(_ incoming: [Msg], into tab: String) {
        guard !incoming.isEmpty else { return }
        var bySeq: [Int: Msg] = [:]
        for m in messages[tab] ?? [] where !m.isPending { bySeq[m.seq] = m }
        for m in incoming { bySeq[m.seq] = m }
        var merged = bySeq.values.sorted { $0.seq < $1.seq }
        // Keep an unconfirmed echo only while nothing newer has arrived.
        if let pending = (messages[tab] ?? []).last(where: { $0.isPending }),
           let highest = incoming.last,
           highest.role != "user" || highest.text != pending.text {
            merged.append(pending)
        }
        messages[tab] = merged
    }

    // MARK: - Requests

    @discardableResult
    private func request(_ op: String, _ extra: [String: Any] = [:],
                         then: (([String: Any]) -> Void)? = nil) -> Bool {
        guard let key, task != nil else { return false }
        let rid = UUID().uuidString
        var body: [String: Any] = ["op": op, "rid": rid]
        body.merge(extra) { _, new in new }
        guard let plain = try? JSONSerialization.data(withJSONObject: body),
              let box = try? AES.GCM.seal(plain, using: key),
              let combined = box.combined
        else { return false }
        if let then { pending[rid] = then }
        let frame: [String: Any] = ["t": "env", "data": combined.base64EncodedString()]
        guard let data = try? JSONSerialization.data(withJSONObject: frame),
              let text = String(data: data, encoding: .utf8)
        else { return false }
        task?.send(.string(text)) { _ in }
        return true
    }

    private func open(_ b64: String) -> [String: Any]? {
        guard let key, let raw = Data(base64Encoded: b64),
              let box = try? AES.GCM.SealedBox(combined: raw),
              let plain = try? AES.GCM.open(box, using: key)
        else { return nil }
        return (try? JSONSerialization.jsonObject(with: plain)) as? [String: Any]
    }

    /// Tell the Mac what it's talking to, so its Settings can say
    /// "Connected: StooPhone" instead of the ambiguous "Phone connected"
    /// — which is equally true of a simulator running on that same Mac.
    private func identify() {
        #if targetEnvironment(simulator)
        let name = UIDevice.current.name + " (Simulator)"
        #else
        let name = UIDevice.current.name
        #endif
        request("identify", ["device": name])
    }

    /// Called when the app comes to the foreground. iOS suspends the
    /// socket while backgrounded, so what's on screen is whatever was true
    /// when you last looked. Reconnect if the socket died, and resync if it
    /// didn't — either way the first thing you see is current.
    func appDidBecomeActive() {
        reconnectAttempts = 0
        let socketAlive = task != nil && connection == .connected
        if socketAlive {
            refreshBoard()
            if let tab = watchedTab { openTab(tab) }
        } else {
            reconnect()
        }
    }

    func refreshBoard() {
        request("board") { [weak self] reply in
            guard let self, reply["ok"] as? Bool == true else { return }
            self.board = Self.decodeBoard(reply["board"])
        }
    }

    func openTab(_ id: String) {
        watchedTab = id
        request("transcript", ["tab": id, "limit": 80]) { [weak self] reply in
            guard let self, reply["ok"] as? Bool == true else { return }
            self.messages[id] = Self.decodeMessages(reply["messages"])
        }
    }

    /// Next sequence for a local echo: below everything real, so it sorts
    /// to the end and is obviously not a confirmed message.
    private func pendingSeq(for tab: String) -> Int {
        ((messages[tab] ?? []).map(\.seq).max() ?? 0) + 1_000_000
    }

    func closeTab(_ id: String) {
        if watchedTab == id { watchedTab = nil }
        request("unwatch", ["tab": id])
    }

    func send(_ text: String, to tab: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Show it immediately; the Mac's next push replaces the list.
        messages[tab, default: []].append(
            Msg(seq: -pendingSeq(for: tab), role: "user", text: trimmed, blocks: [.text(trimmed)]))
        sending = true
        request("send", ["tab": tab, "text": trimmed]) { [weak self] _ in
            self?.sending = false
        }
    }

    func respondPermission(tab: String, allow: Bool) {
        request("respond_permission", ["tab": tab, "allow": allow])
    }

    func answerQuestion(tab: String, answer: String) {
        request("answer_question", ["tab": tab, "answer": answer])
    }

    // MARK: - Decoding

    private static func decodeBoard(_ raw: Any?) -> [Tab] {
        (raw as? [[String: Any]] ?? []).map { r in
            Tab(id: r["id"] as? String ?? "",
                title: r["title"] as? String ?? "Untitled",
                project: r["project"] as? String ?? "",
                repo: r["repo"] as? String ?? "",
                workspace: r["workspace"] as? String ?? "",
                workspaceName: r["workspaceName"] as? String ?? "",
                checkout: r["checkout"] as? String ?? "",
                cwd: r["cwd"] as? String ?? "",
                status: r["status"] as? String ?? "idle",
                blocked: r["blocked"] as? String,
                permissionTool: (r["permission"] as? [String: Any])?["tool"] as? String)
        }
    }

    private static func decodeMessages(_ raw: Any?) -> [Msg] {
        (raw as? [[String: Any]] ?? []).map { row in
            let blocks: [Block] = (row["blocks"] as? [[String: Any]] ?? []).compactMap { b in
                switch b["k"] as? String {
                case "text":      return .text(b["t"] as? String ?? "")
                case "tool":      return .tool(name: b["name"] as? String ?? "tool",
                                               detail: b["detail"] as? String ?? "")
                case "toolError": return .toolError(b["t"] as? String ?? "")
                case "image":     return .image
                default:          return nil
                }
            }
            return Msg(seq: row["seq"] as? Int ?? 0,
                       role: row["role"] as? String ?? "assistant",
                       text: row["text"] as? String ?? "",
                       blocks: blocks)
        }
    }
}
