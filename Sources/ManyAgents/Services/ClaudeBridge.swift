import Foundation
import Combine

/// Events the bridge surfaces upward.
enum BridgeEvent {
    case initialized(sessionId: String)
    case assistantBlocks([ContentBlock])
    case toolResult(toolUseId: String, content: String, isError: Bool)
    case result(usage: TokenUsage?, costUsd: Double?, isError: Bool, text: String?)
    case processExited(exitCode: Int32)
    case systemError(String)
    /// Per-chunk token-count update — fires whenever an assistant message
    /// lands with usage info, so the UI can show a live "↓ N tokens" counter
    /// during long turns without waiting for the final result event.
    case tokenCount(outputTokens: Int)

    struct TokenUsage {
        let inputTokens: Int
        let outputTokens: Int
    }
}

/// Drives `claude` in headless stream-json mode, one process per user
/// prompt. This matches Claude Code's intended SDK pattern: each turn is a
/// fresh `claude -p ... --resume <session_id>` invocation that streams its
/// events then exits. Cleaner than holding a long-running pty: less memory,
/// no zombie processes, and `--resume` actually picks up the prior
/// conversation because we hand claude a prompt to run against immediately.
///
/// State that needs to survive between turns (the claude session_id) lives
/// on the owning `AgentSession`, not here.
final class ClaudeBridge {
    let cwd: String
    /// Updated by the owner after the first `initialized` event so subsequent
    /// `sendUserText` calls can resume the same conversation.
    var currentSessionId: String?

    private let subject = PassthroughSubject<BridgeEvent, Never>()
    private var activeProcess: Process?
    private var stdoutBuffer = Data()

    var events: AnyPublisher<BridgeEvent, Never> { subject.eraseToAnyPublisher() }
    var isBusy: Bool { activeProcess?.isRunning ?? false }

    init(cwd: String, resumeSessionId: String? = nil) {
        self.cwd = cwd
        self.currentSessionId = resumeSessionId
    }

    /// Back-compat shim — most callers send plain text.
    func sendUserText(_ text: String) { send(text: text, imagesPng: []) }

    /// Spawn claude, pipe one user message in (text + optional images),
    /// stream events out, let the process exit.
    func send(text: String, imagesPng: [Data]) {
        guard !isBusy else {
            emit(.systemError("Previous turn still in flight."))
            return
        }
        guard let claudePath = Self.resolveClaudePath() else {
            emit(.systemError("claude binary not found on PATH"))
            return
        }

        var args = [
            "--print",
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            "--verbose",
            "--permission-mode", "acceptEdits"
        ]
        if let rid = currentSessionId, !rid.isEmpty {
            args.append(contentsOf: ["--resume", rid])
        }

        let process = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: claudePath)
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "dumb"
        env["NO_COLOR"] = "1"
        env["MANYAGENTS"] = "1"
        process.environment = env

        stdoutBuffer.removeAll()
        activeProcess = process

        process.terminationHandler = { [weak self] proc in
            let code = proc.terminationStatus
            DispatchQueue.main.async {
                self?.activeProcess = nil
                self?.subject.send(.processExited(exitCode: code))
            }
        }

        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.appendStdout(data)
        }

        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty,
                  let s = String(data: data, encoding: .utf8),
                  !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return }
            DispatchQueue.main.async {
                self?.subject.send(.systemError(s))
            }
        }

        do {
            try process.run()
        } catch {
            activeProcess = nil
            emit(.systemError("Failed to spawn claude: \(error.localizedDescription)"))
            return
        }

        // Write the user prompt as a stream-json line, then close stdin so
        // claude knows no further turns are coming. Without the close, claude
        // would wait indefinitely for the next message.
        var content: [[String: Any]] = []
        if !text.isEmpty {
            content.append(["type": "text", "text": text])
        }
        for png in imagesPng {
            content.append([
                "type": "image",
                "source": [
                    "type": "base64",
                    "media_type": "image/png",
                    "data": png.base64EncodedString()
                ]
            ])
        }
        let payload: [String: Any] = [
            "type": "user",
            "message": ["role": "user", "content": content]
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload),
           let line = String(data: data, encoding: .utf8) {
            let bytes = (line + "\n").data(using: .utf8) ?? Data()
            try? stdin.fileHandleForWriting.write(contentsOf: bytes)
        }
        try? stdin.fileHandleForWriting.close()
    }

    /// Cancel any in-flight turn. The corresponding `.processExited` event
    /// will fire on the termination handler.
    func cancel() {
        if let p = activeProcess, p.isRunning {
            p.terminate()
        }
    }

    // MARK: - Stream parsing

    private func appendStdout(_ data: Data) {
        stdoutBuffer.append(data)
        while let nl = stdoutBuffer.firstIndex(of: 0x0A) {
            let line = stdoutBuffer.prefix(upTo: nl)
            stdoutBuffer.removeSubrange(stdoutBuffer.startIndex...nl)
            if line.isEmpty { continue }
            handleLine(Data(line))
        }
    }

    private func handleLine(_ line: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let type = obj["type"] as? String
        else { return }
        switch type {
        case "system":
            if obj["subtype"] as? String == "init",
               let sid = obj["session_id"] as? String {
                currentSessionId = sid
                emit(.initialized(sessionId: sid))
            }
        case "assistant":
            handleAssistant(obj)
        case "user":
            handleUserMessage(obj)
        case "result":
            handleResult(obj)
        default:
            break
        }
    }

    private func handleAssistant(_ obj: [String: Any]) {
        guard let message = obj["message"] as? [String: Any],
              let content = message["content"] as? [[String: Any]]
        else { return }
        // Live token counter — each intermediate assistant event carries a
        // running total. Surface immediately so the status line ticks.
        if let usage = message["usage"] as? [String: Any],
           let outTokens = usage["output_tokens"] as? Int {
            emit(.tokenCount(outputTokens: outTokens))
        }
        var blocks: [ContentBlock] = []
        for raw in content {
            guard let blockType = raw["type"] as? String else { continue }
            switch blockType {
            case "text":
                if let t = raw["text"] as? String {
                    blocks.append(.text(id: UUID(), text: t))
                }
            case "thinking":
                if let t = raw["thinking"] as? String {
                    blocks.append(.thinking(id: UUID(), text: t))
                }
            case "tool_use":
                if let id = raw["id"] as? String,
                   let name = raw["name"] as? String {
                    let rawInput = raw["input"] as? [String: Any] ?? [:]
                    let input = rawInput.mapValues(AnyCodable.from)
                    blocks.append(.toolUse(id: UUID(), toolUseId: id, name: name, input: input))
                }
            default:
                break
            }
        }
        if !blocks.isEmpty {
            emit(.assistantBlocks(blocks))
        }
    }

    private func handleUserMessage(_ obj: [String: Any]) {
        guard let message = obj["message"] as? [String: Any],
              let content = message["content"] as? [[String: Any]]
        else { return }
        for raw in content where raw["type"] as? String == "tool_result" {
            let toolUseId = raw["tool_use_id"] as? String ?? ""
            let isError = raw["is_error"] as? Bool ?? false
            let text = Self.flattenToolResultContent(raw["content"])
            emit(.toolResult(toolUseId: toolUseId, content: text, isError: isError))
        }
    }

    private static func flattenToolResultContent(_ value: Any?) -> String {
        if let s = value as? String { return s }
        if let arr = value as? [[String: Any]] {
            return arr.compactMap { item in
                if item["type"] as? String == "text" { return item["text"] as? String }
                return nil
            }.joined(separator: "\n")
        }
        return ""
    }

    private func handleResult(_ obj: [String: Any]) {
        let isError = obj["is_error"] as? Bool ?? false
        let text = obj["result"] as? String
        let cost = obj["total_cost_usd"] as? Double
        let usage = (obj["usage"] as? [String: Any]).flatMap { u -> BridgeEvent.TokenUsage? in
            guard let inT = u["input_tokens"] as? Int,
                  let outT = u["output_tokens"] as? Int else { return nil }
            return .init(inputTokens: inT, outputTokens: outT)
        }
        emit(.result(usage: usage, costUsd: cost, isError: isError, text: text))
    }

    private func emit(_ event: BridgeEvent) {
        DispatchQueue.main.async { [weak self] in
            self?.subject.send(event)
        }
    }

    // MARK: - Binary resolution

    static func resolveClaudePath() -> String? {
        let home = NSHomeDirectory()
        let candidates = [
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "\(home)/.claude/local/claude",
            "\(home)/.bun/bin/claude",
            "\(home)/.npm-global/bin/claude"
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return nil
    }
}
