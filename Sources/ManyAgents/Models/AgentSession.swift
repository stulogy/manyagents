import Foundation
import Combine

enum AgentStatus {
    case idle       // ready for input, no work in flight
    case running    // assistant is generating or a tool call is in progress
    case waiting    // assistant turn ended with end_turn — user's move
    case error      // bridge failed or claude exited unexpectedly
}

/// One conversation with a claude agent. Owns the `ClaudeBridge` subprocess
/// and the message history. Mirrors `HostedSession` in ClaudeDeck but talks
/// to claude over JSON-stream stdio instead of a PTY.
@MainActor
final class AgentSession: ObservableObject, Identifiable {
    let id = UUID()
    let cwd: String
    let createdAt: Date

    @Published var displayName: String
    @Published var aiTitle: String?
    @Published var messages: [Message] = []
    @Published var status: AgentStatus = .idle
    @Published var claudeSessionId: String?
    @Published var lastError: String?
    @Published var totalInputTokens: Int = 0
    @Published var totalOutputTokens: Int = 0
    @Published var totalCostUsd: Double = 0
    /// When the user pressed send for the current in-flight turn. `nil` once
    /// the turn lands. Drives the "Warping… 2m 19s" elapsed timer.
    @Published var currentTurnStartedAt: Date?
    /// Running output-token count for the in-flight turn. Reset on send,
    /// accumulated from each assistant event's `usage.output_tokens`.
    @Published var currentTurnOutputTokens: Int = 0
    /// What claude is doing right now — "thinking", "writing", "running Bash",
    /// etc. Derived from the most recent stream event.
    @Published var currentPhase: String = "thinking"

    /// Set externally before connect() if we should resume a prior session id.
    var resumeSessionId: String?

    let bridge: ClaudeBridge
    private var bridgeCancellable: AnyCancellable?

    init(cwd: String, resumeSessionId: String? = nil) {
        self.cwd = cwd
        self.createdAt = Date()
        self.resumeSessionId = resumeSessionId
        self.displayName = ProjectNaming.name(forCwd: cwd)
        self.bridge = ClaudeBridge(cwd: cwd, resumeSessionId: resumeSessionId)
    }

    /// Subscribe to bridge events. Idempotent and lightweight — no claude
    /// process is spawned until the user actually sends a prompt.
    func connect() {
        guard bridgeCancellable == nil else { return }
        bridgeCancellable = bridge.events
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                self?.handle(event)
            }
    }

    /// Cancel any in-flight turn and stop forwarding events.
    func disconnect() {
        bridgeCancellable?.cancel()
        bridgeCancellable = nil
        bridge.cancel()
    }

    /// Send a user prompt. Spawns a fresh `claude -p` process per turn,
    /// resuming the existing session if we already have one.
    func send(_ text: String, images: [Data] = []) {
        var blocks: [ContentBlock] = []
        if !text.isEmpty {
            blocks.append(.text(id: UUID(), text: text))
        }
        for img in images {
            blocks.append(.image(id: UUID(), data: img, mediaType: "image/png"))
        }
        let userMessage = Message(role: .user, blocks: blocks)
        messages.append(userMessage)
        status = .running
        currentTurnStartedAt = Date()
        currentTurnOutputTokens = 0
        currentPhase = "thinking"
        bridge.send(text: text, imagesPng: images)
    }

    // MARK: - Stream event handling

    private func handle(_ event: BridgeEvent) {
        switch event {
        case .initialized(let sid):
            // claude assigns a new session_id on the first turn; subsequent
            // turns reuse it via the bridge's currentSessionId.
            claudeSessionId = sid
            bridge.currentSessionId = sid
        case .assistantBlocks(let blocks):
            // Either append to an in-progress assistant message or start a
            // new one. The CLI emits each assistant *message* as a single
            // event (not per-delta) when streaming is off.
            if let lastIdx = messages.indices.last,
               messages[lastIdx].role == .assistant {
                messages[lastIdx].blocks.append(contentsOf: blocks)
            } else {
                messages.append(Message(role: .assistant, blocks: blocks))
            }
            status = .running
            // Derive a current-phase label from what just arrived so the
            // status line can read "writing" / "running Bash" / etc.
            for block in blocks.reversed() {
                switch block {
                case .toolUse(_, _, let name, _):
                    currentPhase = name == "Bash" ? "running Bash"
                                 : (name == "Edit" || name == "MultiEdit" || name == "Write") ? "editing"
                                 : (name == "Read") ? "reading"
                                 : (name == "Grep" || name == "Glob") ? "searching"
                                 : "running \(name)"
                case .text:
                    currentPhase = "writing"
                case .thinking:
                    currentPhase = "thinking"
                case .toolResult, .image:
                    continue
                }
                break
            }
        case .toolResult(let toolUseId, let content, let isError):
            // Claude itself runs tools and reports the result. Render as a
            // dedicated message so the conversation stays linear.
            let block = ContentBlock.toolResult(id: UUID(),
                                                toolUseId: toolUseId,
                                                content: content,
                                                isError: isError)
            messages.append(Message(role: .system, blocks: [block]))
        case .result(let usage, let cost, let isError, let resultText):
            if let u = usage {
                totalInputTokens += u.inputTokens
                totalOutputTokens += u.outputTokens
                currentTurnOutputTokens = u.outputTokens
            }
            if let c = cost { totalCostUsd += c }
            if isError {
                status = .error
                lastError = resultText
            } else {
                status = .waiting
            }
            currentTurnStartedAt = nil
        case .tokenCount(let outputTokens):
            currentTurnOutputTokens = max(currentTurnOutputTokens, outputTokens)
        case .processExited(let exitCode):
            // Each turn is its own process. A non-zero exit during a turn
            // (status == .running) is an error; an exit after a successful
            // result has already landed the .waiting status, so just keep it.
            if exitCode != 0 && status == .running {
                status = .error
                lastError = "claude exited (\(exitCode))"
            }
        case .systemError(let message):
            status = .error
            lastError = message
        }
    }
}
