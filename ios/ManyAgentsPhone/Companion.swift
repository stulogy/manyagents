import Foundation
import Combine
import os

/// The thing you actually talk to.
///
/// It runs here, on the phone, and it is not one of the agents. It holds
/// the conversation, decides when a question needs the Mac, asks an
/// orchestrator, waits, and then tells you what came back in a sentence or
/// two. The agents keep writing five-paragraph reports with code blocks —
/// that's correct for a screen and useless at 70mph, so this layer reads
/// them and you get the point instead of the prose.
///
/// Small model on purpose. This layer paraphrases and routes; it does no
/// engineering. What it must be is fast, because it sits between you
/// speaking and anything happening.
@MainActor
final class Companion: ObservableObject {

    struct Turn: Identifiable, Equatable {
        enum Who: Equatable { case you, companion, note }
        let id = UUID()
        let who: Who
        var text: String
    }

    @Published private(set) var turns: [Turn] = []
    /// What it's doing right now, for the one line on screen: thinking,
    /// or waiting on a named project.
    @Published private(set) var activity: String?
    @Published private(set) var busy = false
    @Published private(set) var lastError: String?

    private let link: MacLink
    private let voice: Voice
    private let settings = VoiceSettings.shared
    private static let log = Logger(subsystem: "co.ailogy.manyagents.phone", category: "companion")

    /// The API conversation, which is not the same as what's on screen:
    /// it carries tool calls and raw agent output the user never sees.
    private var history: [Anthropic.Message] = []

    init(link: MacLink, voice: Voice) {
        self.link = link
        self.voice = voice
    }

    // MARK: - The loop

    /// One thing you said, start to finish: think, use the Mac if needed,
    /// speak the answer.
    func say(_ spoken: String) async {
        let text = spoken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        turns.append(Turn(who: .you, text: text))
        history.append(.text("user", text))
        await run()
    }

    /// The opening line, composed here rather than by the model.
    ///
    /// Asking Haiku to greet you cost a round trip before you could speak,
    /// and it answered every time with a variation on "nothing needs you"
    /// — true, since a blocked tab is rare, and useless, since it said the
    /// same thing whether one tab was running or fifteen. This is exact,
    /// instant, and different when the board is different.
    ///
    /// It's seeded into the model's history so the conversation carries on
    /// from something the model knows it said.
    func openingBrief() {
        guard turns.isEmpty else { return }
        let line = Self.brief(link.board)
        turns.append(Turn(who: .companion, text: line))
        history = [.text("user", "[Voice mode opened. You greeted the user with the line below; carry on from it.]"),
                   .text("assistant", line)]
        voice.speak(line)
    }

    static func brief(_ board: [MacLink.Tab]) -> String {
        guard !board.isEmpty else { return "No tabs open on your Mac. What do you want to start?" }

        let blocked = board.filter { $0.blocked != nil }
        if !blocked.isEmpty {
            let names = blocked.prefix(2).map(\.title).joined(separator: " and ")
            let rest = blocked.count - min(2, blocked.count)
            let tail = rest > 0 ? ", and \(rest) more" : ""
            return blocked.count == 1
                ? "\(names) is waiting on you."
                : "\(names)\(tail) are waiting on you."
        }

        let working = board.filter(\.isBusy)
        switch working.count {
        case 0:
            return "All quiet. \(board.count) tabs, nothing running. What do you need?"
        case 1:
            return "\(working[0].title) is working. Everything else is quiet."
        default:
            return "\(working.count) tabs working, \(board.count - working.count) quiet. Nothing's blocked."
        }
    }

    private func run() async {
        guard !busy else { return }
        busy = true
        lastError = nil
        defer { busy = false; activity = nil }

        let key = settings.chatKey
        guard !key.isEmpty else {
            let message = "There's no Anthropic key on this phone yet. Add one on your Mac under Settings, Phone."
            turns.append(Turn(who: .note, text: message))
            voice.speak(message)
            return
        }

        // Bounded: a companion that can call tools forever is a companion
        // that can burn your battery in a tunnel.
        for _ in 0..<4 {
            activity = activity ?? "thinking"
            do {
                let reply = try await Anthropic.send(system: Self.systemPrompt,
                                                     messages: history,
                                                     tools: Self.tools,
                                                     apiKey: key)
                history.append(Anthropic.Message(role: "assistant", content: reply.raw))

                if !reply.text.isEmpty {
                    turns.append(Turn(who: .companion, text: reply.text))
                    voice.speak(reply.text)
                }
                guard reply.wantsTools else { return }

                var results: [[String: Any]] = []
                for call in reply.toolCalls {
                    let output = await perform(call)
                    results.append([
                        "type": "tool_result",
                        "tool_use_id": call.id,
                        "content": output,
                    ])
                }
                history.append(Anthropic.Message(role: "user", content: results))
            } catch {
                Self.log.error("companion failed: \(error.localizedDescription, privacy: .public)")
                lastError = error.localizedDescription
                let spoken = "I couldn't reach my own brain there. \(error.localizedDescription)"
                turns.append(Turn(who: .note, text: spoken))
                voice.speak(spoken)
                return
            }
        }
    }

    // MARK: - Tools

    private func perform(_ call: Anthropic.ToolCall) async -> String {
        switch call.name {
        case "list_agents":
            return boardSummary(project: call.input["project"] as? String)
        case "ask_agents":
            return await ask(project: call.input["project"] as? String,
                             question: call.input["question"] as? String ?? "",
                             wait: call.input["wait_seconds"] as? Int ?? 25)
        case "check_agents":
            return checkBack(project: call.input["project"] as? String)
        default:
            return "No such tool."
        }
    }

    /// The board as a few lines of text. No round trip: the Mac already
    /// pushes this, so "what's everyone doing" is answered from memory.
    private func boardSummary(project: String?) -> String {
        let tabs = link.board.filter { tab in
            guard let project, !project.isEmpty else { return true }
            return link.scopeName(of: tab).localizedCaseInsensitiveContains(project)
                || tab.project.localizedCaseInsensitiveContains(project)
        }
        guard !tabs.isEmpty else {
            return project.map { "No tabs in a project matching \"\($0)\"." }
                ?? "No tabs open on the Mac."
        }
        var lines: [String] = []
        for tab in tabs {
            // "idle" reads as "unavailable" to a model, and it isn't —
            // an idle tab is a finished tab, sitting there ready to be
            // asked. Saying "ready" stops it concluding there's nobody
            // home and refusing to ask.
            let state: String
            switch tab.status {
            case "running": state = "working right now"
            case "error":   state = "errored"
            default:        state = "ready (finished its last turn, can be asked anything)"
            }
            var line = "\(link.scopeName(of: tab)) / \(tab.title): \(state)"
            if !tab.checkout.isEmpty { line += " (worktree \(tab.checkout))" }
            if let blocked = tab.blocked {
                line += blocked == "permission"
                    ? " — BLOCKED, wants permission for \(tab.permissionTool ?? "a tool")"
                    : " — BLOCKED, asked the user a question"
            }
            if tab.isOrchestrator { line += " [orchestrator — ask this one]" }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    /// Put a question to a project's orchestrator and wait for its answer.
    ///
    /// Returns the agent's reply verbatim — long, marked up, whatever it
    /// wrote. Condensing it is the model's job, not this function's;
    /// truncating here would hide the part worth saying.
    private func ask(project: String?, question: String, wait: Int) async -> String {
        guard !question.isEmpty else { return "No question given." }
        let scope = project.flatMap { name in
            link.orchestrators.first {
                link.scopeName(of: $0).localizedCaseInsensitiveContains(name)
            }.map { link.scope(of: $0) }
        }

        activity = "asking \(project ?? "the orchestrator")"
        let tab: String? = await withCheckedContinuation { c in
            link.askForCompanion(scope: scope, create: true) { c.resume(returning: $0) }
        }
        guard let tab else {
            return "Couldn't reach an orchestrator on the Mac. \(link.companionError ?? "")"
        }

        link.openTab(tab)                       // start watching before asking
        let baseline = link.highestSeq(in: tab)
        link.send(question, to: tab)
        lastAskedTab = tab
        lastAskedSeq = baseline

        if let answer = await link.awaitReply(tab: tab, afterSeq: baseline,
                                              timeout: TimeInterval(max(5, min(wait, 60)))) {
            return answer
        }
        return "Still working — no answer yet. Tell the user it's thinking, and offer to check back."
    }

    private var lastAskedTab: String?
    private var lastAskedSeq: Int = 0

    /// Has the thing we asked about finished since?
    private func checkBack(project: String?) -> String {
        guard let tab = lastAskedTab else { return "Nothing has been asked yet." }
        let busy = link.board.first { $0.id == tab }?.isBusy ?? false
        if let latest = link.messages[tab]?.last(where: {
            $0.role == "assistant" && $0.seq > lastAskedSeq
        }) {
            return latest.text
        }
        return busy ? "Still working." : "Nothing new back yet."
    }

    // MARK: - Prompt

    private static let systemPrompt = """
    You are the ManyAgents companion. You run on the user's iPhone and you \
    talk to them out loud, usually while they are driving. Everything you \
    say is read aloud by a speech synthesiser.

    Because of that:
    - Never use markdown, bullet points, headings, code blocks, or URLs. \
    They are read out character by character and are unlistenable.
    - Forty words is a long answer. Thirty is normal. Someone driving \
    cannot re-read you, and a list of twenty things spoken aloud is noise.
    - Never enumerate. If there are eleven things, name the one or two that \
    matter and say how many others there are. "Twenty tabs, nothing \
    blocked, the Atlas one finished" beats naming all twenty.
    - Lead with what needs the user. If nothing does, say so in one \
    sentence and stop.
    - End with a question only when you actually need an answer.
    - Say numbers and names the way a person would say them.
    - Never read code aloud. Say what it does.

    You are NOT one of the coding agents. You are a layer above them. The \
    user's Mac runs ManyAgents: many Claude Code sessions ("tabs"), grouped \
    by project. Some tabs wear an "orchestrator" hat and can see and drive \
    every other tab in their project.

    Your tools:
    - list_agents: what's open and what state it's in. Free and instant. \
    Use it before answering anything about status. A "ready" tab is idle \
    and waiting, not missing — ask it anyway. Never refuse to ask because \
    tabs look quiet; quiet is their normal state.
    - ask_agents: put a question or instruction to a project's \
    orchestrator, and wait for its reply. Use this for anything that needs \
    real knowledge of the code, or any instruction to be carried out.
    - check_agents: see whether an earlier question has been answered yet.

    If the user asks you to find something out, go and find it out. Asking \
    the user "shall I ask?" when they have just told you to ask wastes the \
    only thing they're short of, which is attention on a road.

    When an orchestrator replies, it will often be long, structured, and \
    full of file paths and code. Do not read it out. Read it, and tell the \
    user what actually matters: what changed, what it found, what it needs \
    from them, and what happens next. If it asked a question, put that \
    question to the user in your own words and send their answer back.

    Agents can take minutes. If something is still working, say so plainly \
    and carry on the conversation; don't sit silent.

    Be direct and warm, like a colleague in the passenger seat. No filler, \
    no "certainly", no restating the question before answering it. If you \
    are about to say something the user could not act on while driving, \
    it's the wrong thing to say.
    """

    private static let tools: [Anthropic.Tool] = [
        .init(name: "list_agents",
              description: "List the tabs open in ManyAgents on the Mac, with their status and whether any is blocked waiting on the user. Instant and free — use it before answering any question about what's happening. A tab being 'ready' means it is idle and available, not absent: you can always ask.",
              schema: [
                "type": "object",
                "properties": [
                    "project": ["type": "string",
                                "description": "Optional project name to filter by, e.g. 'uhp'."],
                ],
              ]),
        .init(name: "ask_agents",
              description: "Ask a project's orchestrator a question, or tell it to do something. It can see and drive every tab in its project. Waits for the reply and returns it verbatim. Use for anything needing real knowledge of the code or any instruction to carry out.",
              schema: [
                "type": "object",
                "properties": [
                    "question": ["type": "string",
                                 "description": "What to ask or instruct, in full. The orchestrator has no memory of this phone conversation, so include the context it needs."],
                    "project": ["type": "string",
                                "description": "Which project's orchestrator, e.g. 'uhp'. Omit to use the one the user last talked to."],
                    "wait_seconds": ["type": "integer",
                                     "description": "How long to wait for a reply before returning. Default 25, max 60."],
                ],
                "required": ["question"],
              ]),
        .init(name: "check_agents",
              description: "Check whether the last thing you asked has been answered yet. Use when a previous ask_agents came back as still working.",
              schema: [
                "type": "object",
                "properties": [
                    "project": ["type": "string", "description": "Optional project name."],
                ],
              ]),
    ]
}
