import Foundation

/// Just enough of the Messages API to hold a spoken conversation with
/// tools. No SDK: the surface used here is one POST, and a dependency
/// would be larger than the thing it replaces.
enum Anthropic {

    /// Haiku, deliberately. This layer paraphrases and routes — it does no
    /// engineering, that's what the agents on the Mac are for. The job it
    /// does have is bounded by how fast a reply can start being spoken,
    /// and the cheapest fast model is the right tool for a layer you hit
    /// on every single utterance.
    static let model = "claude-haiku-4-5-20251001"

    struct Tool {
        let name: String
        let description: String
        /// JSON Schema for the input.
        let schema: [String: Any]
    }

    /// One message in the conversation. Content is kept as raw JSON blocks
    /// so tool_use and tool_result round-trip unchanged.
    struct Message {
        let role: String            // "user" | "assistant"
        let content: [[String: Any]]

        static func text(_ role: String, _ text: String) -> Message {
            Message(role: role, content: [["type": "text", "text": text]])
        }
    }

    struct ToolCall {
        let id: String
        let name: String
        let input: [String: Any]
    }

    struct Reply {
        /// Everything the model said in prose. Empty when it only called
        /// tools.
        let text: String
        let toolCalls: [ToolCall]
        /// The assistant turn exactly as returned, to append to history.
        let raw: [[String: Any]]
        var wantsTools: Bool { !toolCalls.isEmpty }
    }

    enum Failure: LocalizedError {
        case noKey
        case http(Int, String)

        var errorDescription: String? {
            switch self {
            case .noKey: return "No Anthropic API key on this phone yet."
            case .http(401, _): return "Anthropic rejected that API key."
            case .http(429, _): return "Anthropic is rate-limiting; try again in a moment."
            case .http(let c, let body): return "Anthropic \(c): \(body.prefix(160))"
            }
        }
    }

    private static let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.waitsForConnectivity = true
        c.timeoutIntervalForRequest = 30
        c.timeoutIntervalForResource = 60
        return URLSession(configuration: c)
    }()

    static func send(system: String,
                     messages: [Message],
                     tools: [Tool],
                     maxTokens: Int = 400,
                     apiKey: String) async throws -> Reply {
        guard !apiKey.isEmpty else { throw Failure.noKey }

        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "system": system,
            "messages": messages.map { ["role": $0.role, "content": $0.content] },
        ]
        if !tools.isEmpty {
            body["tools"] = tools.map {
                ["name": $0.name, "description": $0.description, "input_schema": $0.schema]
            }
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            throw Failure.http(code, String(data: data, encoding: .utf8) ?? "")
        }

        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        let blocks = obj["content"] as? [[String: Any]] ?? []
        var prose: [String] = []
        var calls: [ToolCall] = []
        for block in blocks {
            switch block["type"] as? String {
            case "text":
                if let t = block["text"] as? String { prose.append(t) }
            case "tool_use":
                if let id = block["id"] as? String, let name = block["name"] as? String {
                    calls.append(ToolCall(id: id, name: name,
                                          input: block["input"] as? [String: Any] ?? [:]))
                }
            default:
                break
            }
        }
        return Reply(text: prose.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines),
                     toolCalls: calls,
                     raw: blocks)
    }
}
