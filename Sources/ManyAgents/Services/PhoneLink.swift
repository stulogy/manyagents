import Foundation
import Combine
import CryptoKit

/// The Mac half of the ManyAgents phone client.
///
/// Design decisions worth stating, because the thing this replaces failed
/// on all three:
///
///  * It lives INSIDE the app. No separate bridge process to be "not
///    running" — if ManyAgents is up, the phone can reach it.
///  * It dials OUT to the relay. No port to open, no NAT to traverse, no
///    router config, works from cellular.
///  * It carries no intelligence. The relay forwards opaque frames and
///    this side answers them from live app state. Nothing summarises or
///    rewrites what a tab actually said.
///
/// Everything on the wire is AES-GCM sealed with the pairing key, which
/// only this Mac and the paired phone hold. The relay sees ciphertext.
@MainActor
final class PhoneLink: NSObject, ObservableObject {

    enum Keys {
        static let enabled  = "manyagents.phonelink.enabled"
        static let room     = "manyagents.phonelink.room"
        static let secret   = "manyagents.phonelink.secret"
        static let relayURL = "manyagents.phonelink.relayURL"
        /// Voice credentials for the phone app to read replies aloud with.
        /// Kept here rather than on the phone so it's typed once, on a
        /// keyboard, and travels inside the sealed envelope.
        static let voiceKey       = "manyagents.voice.elevenKey"
        static let voiceID        = "manyagents.voice.elevenVoiceID"
        static let voiceName      = "manyagents.voice.elevenVoiceName"
        /// The model the phone's own companion layer thinks with. Not used
        /// by the Mac at all — it's handed over and spent there.
        static let chatKey        = "manyagents.phone.chatKey"
    }

    /// No default, deliberately. This is an open-source app and a relay is
    /// someone's own infrastructure — baking one person's host in would
    /// silently route other people's transcripts through it. `relay/` in
    /// this repo is a ~150-line service you can deploy anywhere; point
    /// this at your own.
    static let defaultRelay = ""

    enum State: Equatable {
        case off
        case connecting
        case waitingForPhone      // relay reached, no phone on the other end
        case paired               // a phone is listening
        case failed(String)
    }

    @Published private(set) var state: State = .off
    /// Deliberately NOT @Published: this ticks on every frame the phone
    /// sends, and publishing it redrew the Settings pane — and with it the
    /// QR code — many times a second.
    private(set) var lastActivity: Date?
    /// What the connected client calls itself. Without this, "Phone
    /// connected" is true of a simulator on this very Mac, which reads as
    /// though a phone you're holding is on the board when it isn't.
    @Published private(set) var connectedDevice: String?
    @Published var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            UserDefaults.standard.set(isEnabled, forKey: Keys.enabled)
            isEnabled ? connect() : disconnect()
        }
    }

    /// Stable per-Mac room id. The phone joins the same room; nothing else
    /// can, because joining also needs the relay's own access token.
    let room: String
    /// 32 bytes, base64url. The phone gets this once, by QR, and it is the
    /// only thing that can read the traffic.
    private let secretRaw: Data
    private var key: SymmetricKey { SymmetricKey(data: secretRaw) }

    private var task: URLSessionWebSocketTask?
    private var session: URLSession!
    private weak var manager: AgentManager?
    private var cancellables: Set<AnyCancellable> = []
    private var reconnectAttempts = 0
    private var pingTimer: Timer?
    /// Tabs whose transcript the phone is watching, so we only push
    /// message events it cares about.
    private var watching: Set<UUID> = []

    override init() {
        let d = UserDefaults.standard
        self.isEnabled = d.bool(forKey: Keys.enabled)

        if let existing = d.string(forKey: Keys.room) {
            self.room = existing
        } else {
            let generated = "mac-" + UUID().uuidString.prefix(12).lowercased()
            d.set(generated, forKey: Keys.room)
            self.room = generated
        }

        if let stored = d.string(forKey: Keys.secret),
           let raw = Data(base64Encoded: stored), raw.count == 32 {
            self.secretRaw = raw
        } else {
            var bytes = [UInt8](repeating: 0, count: 32)
            _ = SecRandomCopyBytes(kSecRandomDefault, 32, &bytes)
            let raw = Data(bytes)
            d.set(raw.base64EncodedString(), forKey: Keys.secret)
            self.secretRaw = raw
        }
        super.init()
        self.session = URLSession(configuration: .default, delegate: nil, delegateQueue: nil)
    }

    /// Everything the phone needs, small enough for one QR code.
    var pairingPayload: String {
        let relay = UserDefaults.standard.string(forKey: Keys.relayURL) ?? Self.defaultRelay
        let obj: [String: Any] = [
            "v": 1,
            "relay": relay,
            "room": room,
            "key": secretRaw.base64EncodedString(),
            "mac": Host.current().localizedName ?? "Mac",
            // The relay's own access token rides along so pairing is one
            // scan, not a scan plus a typed secret on a phone keyboard.
            "access": relayAccessToken() ?? "",
        ]
        let data = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data()
        return "manyagents://pair?d=" + data.base64EncodedString()
    }

    /// Rotate the secret. Any paired phone stops working and must re-scan —
    /// which is the point, it's how you revoke a lost phone.
    func regenerateSecret() {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, 32, &bytes)
        UserDefaults.standard.set(Data(bytes).base64EncodedString(), forKey: Keys.secret)
        // A restart picks up the new key; reconnecting with the old one in
        // memory would keep the revoked phone alive until quit.
        disconnect()
        state = .failed("New pairing code generated — restart ManyAgents to apply it.")
    }

    func attach(manager: AgentManager) {
        self.manager = manager
        // Board changes are pushed, not polled: the phone shows live status
        // without asking. Debounced because this fires per streamed token.
        manager.objectWillChange
            .debounce(for: .milliseconds(600), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.pushBoardIfPaired() }
            .store(in: &cancellables)
        if isEnabled { connect() }
    }

    // MARK: - Connection

    private func connect() {
        guard isEnabled else { return }
        disconnect(resetState: false)
        let base = (UserDefaults.standard.string(forKey: Keys.relayURL) ?? Self.defaultRelay)
            .trimmingCharacters(in: .whitespaces)
        guard !base.isEmpty else {
            state = .failed("Set a relay URL in Settings — see relay/README.md to run one.")
            return
        }
        guard let accessToken = relayAccessToken() else {
            state = .failed("No relay token — set MANYAGENTS_RELAY_TOKEN or pair again.")
            return
        }
        var comps = URLComponents(string: base + "/ma/v1/socket")
        comps?.queryItems = [
            .init(name: "room", value: room),
            .init(name: "role", value: "mac"),
            .init(name: "key", value: accessToken),
        ]
        guard let url = comps?.url else {
            state = .failed("Bad relay URL")
            return
        }
        state = .connecting
        let t = session.webSocketTask(with: url)
        task = t
        t.resume()
        receive()
        schedulePing()
    }

    private func disconnect(resetState: Bool = true) {
        pingTimer?.invalidate()
        pingTimer = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        if resetState { state = .off }
    }

    /// The relay's own access token — the outer door. Distinct from the
    /// pairing key, which is the inner envelope the relay can't open.
    private func relayAccessToken() -> String? {
        if let t = ProcessInfo.processInfo.environment["MANYAGENTS_RELAY_TOKEN"], !t.isEmpty { return t }
        if let t = UserDefaults.standard.string(forKey: "manyagents.phonelink.relayToken"), !t.isEmpty { return t }
        return nil
    }

    private func scheduleReconnect() {
        guard isEnabled else { return }
        reconnectAttempts += 1
        let delay = min(pow(2.0, Double(min(reconnectAttempts, 6))), 60)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.isEnabled else { return }
            self.connect()
        }
    }

    private func schedulePing() {
        pingTimer?.invalidate()
        pingTimer = Timer.scheduledTimer(withTimeInterval: 25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.task?.sendPing { _ in } }
        }
    }

    private func receive() {
        task?.receive { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .failure:
                    if case .failed = self.state {} else { self.state = .connecting }
                    self.scheduleReconnect()
                case .success(let message):
                    self.reconnectAttempts = 0
                    if case .string(let text) = message { self.handleFrame(text) }
                    self.receive()
                }
            }
        }
    }

    private func handleFrame(_ text: String) {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["t"] as? String
        else { return }

        switch type {
        case "hello":
            state = .waitingForPhone
        case "peer":
            if obj["role"] as? String == "phone" {
                let present = obj["present"] as? Bool == true
                state = present ? .paired : .waitingForPhone
                if present { pushBoardIfPaired() } else { connectedDevice = nil }
            }
        case "env":
            guard let sealed = obj["data"] as? String,
                  let payload = open(sealed) else { return }
            lastActivity = Date()
            handleRequest(payload, seq: obj["seq"])
        default:
            break
        }
    }

    // MARK: - Crypto

    private func seal(_ obj: [String: Any]) -> String? {
        guard let plain = try? JSONSerialization.data(withJSONObject: obj),
              let box = try? AES.GCM.seal(plain, using: key),
              let combined = box.combined
        else { return nil }
        return combined.base64EncodedString()
    }

    private func open(_ b64: String) -> [String: Any]? {
        guard let raw = Data(base64Encoded: b64),
              let box = try? AES.GCM.SealedBox(combined: raw),
              let plain = try? AES.GCM.open(box, using: key)
        else { return nil }
        return (try? JSONSerialization.jsonObject(with: plain)) as? [String: Any]
    }

    private func send(_ payload: [String: Any]) {
        guard let sealed = seal(payload) else { return }
        let frame: [String: Any] = ["t": "env", "data": sealed]
        guard let data = try? JSONSerialization.data(withJSONObject: frame),
              let text = String(data: data, encoding: .utf8)
        else { return }
        task?.send(.string(text)) { _ in }
    }

    // MARK: - Requests from the phone

    private func handleRequest(_ req: [String: Any], seq: Any?) {
        guard let mgr = manager, let op = req["op"] as? String else { return }
        let rid = req["rid"] as? String

        func reply(_ body: [String: Any]) {
            var out = body
            out["rid"] = rid as Any
            send(out)
        }

        switch op {
        case "identify":
            connectedDevice = (req["device"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            reply(["ok": true])

        case "board":
            reply(["ok": true, "board": boardPayload()])

        case "transcript":
            guard let s = tab(for: req["tab"], in: mgr) else {
                return reply(["ok": false, "error": "unknown tab"])
            }
            watching.insert(s.id)
            let limit = (req["limit"] as? Int) ?? 60
            reply(["ok": true, "tab": s.id.uuidString, "messages": messagePayload(s, limit: limit)])

        case "unwatch":
            if let s = tab(for: req["tab"], in: mgr) { watching.remove(s.id) }
            reply(["ok": true])

        case "send":
            guard let s = tab(for: req["tab"], in: mgr),
                  let text = (req["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty
            else { return reply(["ok": false, "error": "need tab and text"]) }
            s.send(text)
            reply(["ok": true])

        case "respond_permission":
            guard let s = tab(for: req["tab"], in: mgr) else {
                return reply(["ok": false, "error": "unknown tab"])
            }
            s.respondToPermission(allow: (req["allow"] as? Bool) ?? false,
                                  message: req["message"] as? String)
            reply(["ok": true])

        case "companion":
            // The tab you talk to hands-free.
            //
            // Not a new kind of session: it's the orchestrator that already
            // exists on the Mac, which holds the board tools (list_agents,
            // read_agent, send_to_agent, new_agent). Talking to it is what
            // makes the phone a companion rather than a microphone wired to
            // one tab — "what's everyone doing" and "tell the ops one to
            // stop and run the tests" are things only that tab can answer.
            //
            // Prefer the orchestrator for whatever is active on the Mac, so
            // asking from the car matches what you'd see on the screen.
            // A scope makes this unambiguous: "the orchestrator for
            // ~/Sites/uhp", not "whichever one the Mac happens to be
            // looking at". The phone sends one whenever the user picked a
            // project; without one we fall back to the active tab's.
            let scope = (req["scope"] as? String)?.trimmingCharacters(in: .whitespaces)
            let existing: AgentSession?
            if let scope, !scope.isEmpty {
                existing = mgr.orchestrator(for: scope)
            } else {
                existing = mgr.activeSession.flatMap { mgr.orchestrator(for: $0.cwd) }
                    ?? mgr.sessions.first { $0.isCoordinator && $0.boardScope == $0.projectRoot }
                    ?? mgr.sessions.first { $0.isCoordinator }
            }
            if let existing {
                reply(["ok": true, "tab": existing.id.uuidString, "created": false])
            } else if (req["create"] as? Bool) == true, let scope, !scope.isEmpty,
                      // Appointing one for a named project: a tab in that
                      // project, wearing the hat.
                      FileManager.default.fileExists(atPath: scope) {
                let session = mgr.spawn(cwd: scope)
                mgr.designateOrchestrator(session)
                reply(["ok": true, "tab": session.id.uuidString, "created": true])
            } else if (req["create"] as? Bool) == true,
                      // Last resort is the un-restored snapshot: after a
                      // Mac restart the board is empty until someone
                      // accepts the restore sheet, and "no project to
                      // start one in" is a useless answer from a car when
                      // we plainly know where you were working.
                      let cwd = mgr.activeSession?.cwd ?? mgr.sessions.first?.cwd
                        ?? mgr.pendingRestore?.agents.first?.cwd {
                // Nothing is wearing the hat. Rather than fail at a red
                // light, put one on: a fresh tab in whatever project is
                // active, designated, which delivers its own catch-up brief.
                let session = mgr.spawn(cwd: cwd)
                mgr.designateOrchestrator(session)
                reply(["ok": true, "tab": session.id.uuidString, "created": true])
            } else {
                reply(["ok": false, "error": "no orchestrator, and no project to start one in"])
            }

        case "voice_config":
            // Only ever answered over the sealed channel, to a phone that
            // holds the pairing key. Empty when nothing is configured, and
            // the phone falls back to its own built-in voice.
            let d = UserDefaults.standard
            reply(["ok": true,
                   "provider": "elevenlabs",
                   "key": d.string(forKey: Keys.voiceKey) ?? "",
                   "voiceId": d.string(forKey: Keys.voiceID) ?? "",
                   "voiceName": d.string(forKey: Keys.voiceName) ?? "",
                   "chatKey": d.string(forKey: Keys.chatKey) ?? ""])

        case "answer_question":
            guard let s = tab(for: req["tab"], in: mgr),
                  let answer = req["answer"] as? String
            else { return reply(["ok": false, "error": "need tab and answer"]) }
            s.answerQuestion(answer)
            reply(["ok": true])

        default:
            reply(["ok": false, "error": "unknown op: \(op)"])
        }
    }

    private func tab(for raw: Any?, in mgr: AgentManager) -> AgentSession? {
        guard let str = raw as? String, let uuid = UUID(uuidString: str) else { return nil }
        return mgr.sessions.first { $0.id == uuid }
    }

    // MARK: - Payloads

    private func boardPayload() -> [[String: Any]] {
        guard let mgr = manager else { return [] }
        return mgr.sessions.map { s in
            // The board groups by REPO, not by raw cwd: a repo and six
            // worktrees cut from it are one project with six checkouts, not
            // seven projects. `checkout` is what distinguishes them, empty
            // when the tab sits in the repo itself.
            // Two levels, exactly as the Mac's sidebar builds them: a
            // workspace (~/Sites/uhp) carries the repos cloned inside it
            // (dev/UHP-OPS-Agent, uhp-student-app), and each repo carries
            // its worktrees. Sending only the repo made ~/Sites/uhp read as
            // four unrelated projects on the phone.
            let repo = ProjectNaming.repoRoot(forCwd: s.cwd)
            let workspace = ProjectNaming.projectRoot(forCwd: repo)
            var row: [String: Any] = [
                "id": s.id.uuidString,
                "title": s.aiTitle ?? s.displayName,
                "project": ProjectNaming.name(forCwd: repo),
                "repo": repo,
                "workspace": workspace,
                "workspaceName": ProjectNaming.name(forCwd: workspace),
                "checkout": ProjectNaming.checkoutLabel(forCwd: s.cwd),
                "cwd": ProjectNaming.prettyCwd(s.cwd),
                "status": statusString(s.status),
                // The hat. The phone surfaces this tab as the companion you
                // talk to, rather than one more row in the list.
                "orchestrator": s.isCoordinator,
            ]
            // What the phone actually needs to know: is this tab stuck
            // waiting on a human?
            if let p = s.pendingPermission {
                row["blocked"] = "permission"
                row["permission"] = ["id": p.id, "tool": p.toolName]
            } else if s.pendingAskUserQuestion != nil {
                row["blocked"] = "question"
            }
            return row
        }
    }

    /// Typed blocks rather than one flattened string. A transcript is
    /// mostly prose with tool activity threaded through it; flattening
    /// turns a Bash call into a paragraph of shell output the phone then
    /// has to render as if the agent had said it.
    private func messagePayload(_ s: AgentSession, limit: Int) -> [[String: Any]] {
        // Absolute index travels with each message. Without a stable id the
        // phone can't tell a re-sent tail from new messages, and merging a
        // 12-message push into an 80-message transcript duplicates the tail
        // on every push.
        let start = max(0, s.messages.count - limit)
        return s.messages.enumerated().dropFirst(start).compactMap { pair -> [String: Any]? in
            let (index, m) = pair
            let role: String
            switch m.role {
            case .assistant: role = "assistant"
            case .user:      role = "user"
            case .system:    role = "system"
            }

            var blocks: [[String: Any]] = []
            for block in m.blocks {
                switch block {
                case .text(_, let t):
                    let trimmed = t.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { blocks.append(["k": "text", "t": trimmed]) }
                case .toolUse(_, _, let name, let input, _):
                    blocks.append(["k": "tool", "name": name, "detail": Self.toolDetail(name: name, input: input)])
                case .toolResult(_, _, let content, let isError, _):
                    // Only failures are worth a phone's screen; a successful
                    // tool result is noise the agent already summarised.
                    if isError {
                        blocks.append(["k": "toolError", "t": String(content.prefix(400))])
                    }
                case .image:
                    blocks.append(["k": "image"])
                case .thinking:
                    break   // never leaves the Mac
                }
            }
            if blocks.isEmpty { return nil }
            return ["seq": index, "role": role, "blocks": blocks, "text": m.flatText]
        }
    }

    /// One line describing what a tool call is doing — the command, the
    /// path, the pattern. Enough to follow along without the payload.
    private static func toolDetail(name: String, input: [String: AnyCodable]) -> String {
        func str(_ key: String) -> String? {
            guard let v = input[key]?.value as? String else { return nil }
            return v.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let raw: String?
        switch name {
        case "Bash":                 raw = str("command")
        case "Read", "Write":        raw = str("file_path")
        case "Edit":                 raw = str("file_path")
        case "Grep":                 raw = str("pattern")
        case "Glob":                 raw = str("pattern")
        case "WebFetch":             raw = str("url")
        case "Task", "Agent":        raw = str("description")
        default:                     raw = str("description") ?? str("path") ?? str("file_path")
        }
        guard let raw, !raw.isEmpty else { return "" }
        let oneLine = raw.replacingOccurrences(of: "\n", with: " ")
        return oneLine.count > 90 ? String(oneLine.prefix(90)) + "…" : oneLine
    }

    private func statusString(_ s: AgentStatus) -> String {
        switch s {
        case .idle:    return "idle"
        case .running: return "running"
        case .waiting: return "waiting"
        case .error:   return "error"
        }
    }

    // MARK: - Pushes

    private func pushBoardIfPaired() {
        guard state == .paired else { return }
        send(["ev": "board", "board": boardPayload()])
        // A watched tab's transcript tail rides along so an open thread on
        // the phone updates without polling for it.
        guard let mgr = manager else { return }
        for id in watching {
            guard let s = mgr.sessions.first(where: { $0.id == id }) else { continue }
            send(["ev": "messages", "tab": id.uuidString,
                  "messages": messagePayload(s, limit: 12)])
        }
    }
}
