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

    /// Things it has been told that are in no codebase and on no board —
    /// who Danny is, which project the staging box belongs to. Without
    /// these it asks the same disambiguating question every drive, which
    /// is the quickest way to make a companion not worth talking to.
    @Published private(set) var facts: [String] = []

    private enum Store {
        static let facts = "companion.facts"
        static let turns = "companion.turns"
        static let stamp = "companion.turnsAt"
    }
    /// Long enough to cover a drive and a stop. A week later it isn't the
    /// same conversation, and picking it up mid-thread would confuse.
    private static let historyLifetime: TimeInterval = 12 * 3600

    /// A project to prefer when the user doesn't name one — set when you
    /// open this from a project's own talk button. Not a boundary: the
    /// companion can see and reach every project either way, which is the
    /// whole point of it sitting above them.
    var focus: String?

    /// One conversation, not one per time you open the screen. You stop at
    /// lights, glance at something, come back — and carrying on where you
    /// were is most of the difference between a companion and a search box.
    static let shared = Companion(link: .shared, voice: .shared)

    init(link: MacLink, voice: Voice, focus: String? = nil) {
        self.link = link
        self.voice = voice
        self.focus = focus
        restore()
    }

    // MARK: - Memory

    private func restore() {
        let d = UserDefaults.standard
        facts = d.stringArray(forKey: Store.facts) ?? []
        let stamp = d.object(forKey: Store.stamp) as? Date ?? .distantPast
        guard Date().timeIntervalSince(stamp) < Self.historyLifetime,
              let rows = d.array(forKey: Store.turns) as? [[String: String]]
        else { return }
        // Rebuilt from what was said rather than from the raw API history:
        // tool calls needn't survive a restart, and half-restored tool
        // state is a reliable way to make the next request fail.
        for row in rows {
            guard let who = row["who"], let text = row["text"], !text.isEmpty else { continue }
            let mine = who != "you"
            turns.append(Turn(who: mine ? .companion : .you, text: text))
            history.append(.text(mine ? "assistant" : "user", text))
        }
    }

    private func persist() {
        let d = UserDefaults.standard
        d.set(turns.suffix(20).map { ["who": $0.who == .you ? "you" : "companion",
                                      "text": $0.text] }, forKey: Store.turns)
        d.set(Date(), forKey: Store.stamp)
        d.set(facts, forKey: Store.facts)
    }

    /// Start the conversation again. Deliberately does not touch what it
    /// has learned — forgetting who Danny is because you changed the
    /// subject would be its own bug.
    func clearConversation() {
        turns = []
        history = []
        persist()
    }

    func forget(_ fact: String) {
        facts.removeAll { $0 == fact }
        persist()
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
        persist()
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
                let reply = try await Anthropic.send(system: systemPrompt,
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
                compact()
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

    // MARK: - Keeping the prompt small

    /// Roughly 4 characters to a token, so this is about 3k tokens of
    /// conversation. Enough to hold a real thread; small enough that the
    /// hundredth turn of a drive costs what the second one did.
    private static let historyBudget = 12_000
    /// A raw agent report is worth its full length exactly once — on the
    /// turn the model reads it and says what it means. After that the
    /// summary is in the conversation and the report is dead weight.
    private static let staleToolResult = 400

    /// Trim the conversation before it becomes the cost.
    ///
    /// Two things grow without this. Every raw orchestrator reply — five
    /// paragraphs of prose and code — enters history as a tool result and
    /// gets resent on every turn afterwards. And the thread itself just
    /// gets longer. Left alone, an hour's driving turns a cheap fast layer
    /// into a slow expensive one, which is the opposite of why it's Haiku.
    private func compact() {
        // Shrink tool results that aren't the current one. What the model
        // concluded from them is already in its own reply.
        if history.count > 2 {
            for i in 0..<(history.count - 2) where isToolResult(history[i]) {
                history[i] = Anthropic.Message(role: "user", content: history[i].content.map { block in
                    guard var text = block["content"] as? String,
                          text.count > Self.staleToolResult else { return block }
                    text = String(text.prefix(Self.staleToolResult)) + "… [older reply, trimmed]"
                    var out = block
                    out["content"] = text
                    return out
                })
            }
        }

        // Then drop whole rounds off the front until we're inside budget.
        while size() > Self.historyBudget, history.count > 4 {
            history.removeFirst()
            // The first message must be a user message, and must not be
            // a tool result whose tool_use we just dropped. The API
            // rejects both, and a rejected request is a companion that
            // stops talking to you.
            while let first = history.first, first.role != "user" || isToolResult(first) {
                history.removeFirst()
            }
        }
    }

    private func isToolResult(_ m: Anthropic.Message) -> Bool {
        m.role == "user" && m.content.first?["type"] as? String == "tool_result"
    }

    private func size() -> Int {
        history.reduce(0) { total, m in
            total + m.content.reduce(0) { inner, block in
                inner + ((block["text"] as? String)?.count ?? 0)
                      + ((block["content"] as? String)?.count ?? 0)
                      + 40
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
        case "remember":
            guard let fact = (call.input["fact"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !fact.isEmpty
            else { return "Nothing to remember." }
            // One line each, thirty at most, oldest dropped. This rides
            // in the system prompt on every single turn, so it has to stay
            // a page of notes and never become a diary.
            guard fact.count <= 160 else {
                return "Too long to keep. Say it in one short sentence."
            }
            facts.removeAll { $0.caseInsensitiveCompare(fact) == .orderedSame }
            facts.append(fact)
            if facts.count > 30 { facts.removeFirst(facts.count - 30) }
            persist()
            return "Noted."
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
        let named = project ?? focus
        let match = named.flatMap { name in
            link.orchestrators.first {
                link.scopeName(of: $0).localizedCaseInsensitiveContains(name)
            }
        }

        // Don't guess whose codebase to send an instruction into. If it
        // isn't clear, hand the options back and let the model ask.
        if match == nil {
            let options = link.orchestrators.map { link.scopeName(of: $0) }
            if let named, !options.isEmpty {
                return "No project called \"\(named)\". Ask the user which of these: \(options.joined(separator: ", "))."
            }
            if options.count > 1 {
                return "Which project? Ask the user, then call this again with one of: \(options.joined(separator: ", "))."
            }
        }
        let scope = match.map { link.scope(of: $0) }

        activity = "asking \(named ?? "the agents")"
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

    /// The prompt plus whatever it has been told, so something explained
    /// once doesn't have to be explained again next week.
    private var systemPrompt: String {
        guard !facts.isEmpty else { return Self.basePrompt }
        return Self.basePrompt + "\n\nThings the user has told you before:\n"
            + facts.map { "- " + $0 }.joined(separator: "\n")
    }

    private static let basePrompt = """
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
    real knowledge of the code, or any instruction to be carried out. You \
    can reach every project, not just one — name the project you mean. If \
    it's genuinely ambiguous which one the user means, ask them; never \
    guess whose codebase to send an instruction into.
    - check_agents: see whether an earlier question has been answered yet.
    - remember: store a fact you will want on another day. Use it whenever \
    the user tells you something you could not have known and will need \
    again — who a person is and which project they belong to, what they \
    call a thing, how they like something done. If you had to ask which \
    project someone meant and they told you, remember it so you never have \
    to ask again.

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
              description: "Ask any project's orchestrator a question, or tell it to do something. It can see and drive every tab in its project. Waits for the reply and returns it verbatim. Use for anything needing real knowledge of the code or any instruction to carry out.",
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
        .init(name: "remember",
              description: "Store one short fact for future conversations — a person and their project, a nickname, a preference. Use it whenever the user tells you something you will need on another day, especially the answer to a question you had to ask them. Only durable facts: never what is happening right now, never anything you could get from list_agents, and never more than one sentence. There is room for about thirty, and the oldest fall off.",
              schema: [
                "type": "object",
                "properties": [
                    "fact": ["type": "string",
                             "description": "One self-contained sentence, e.g. 'Danny is the tech lead on adapther.'"],
                ],
                "required": ["fact"],
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
