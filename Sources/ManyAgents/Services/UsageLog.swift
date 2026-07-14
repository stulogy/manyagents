import Foundation

/// Persists one JSONL record per completed turn so token/cost history
/// survives across launches — the in-memory per-session counters reset
/// every time the app quits, which is why there was no usage view.
///
/// Storage: ~/Library/Application Support/ManyAgents/usage.jsonl.
/// Appends are tiny (one line per turn) and the file is only read when
/// the Usage window opens, so no in-memory index is kept.
@MainActor
enum UsageLog {
    struct Record: Codable {
        let ts: Date
        let cwd: String
        let inputTokens: Int
        let outputTokens: Int
        /// API-equivalent pricing from the CLI — NOT subscription quota.
        let costUsd: Double
        /// Model id, e.g. claude-fable-5. Optional: absent on records
        /// written before this field existed.
        let model: String?
    }

    static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first!
            .appendingPathComponent("ManyAgents", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("usage.jsonl")
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    /// Append one turn's usage. Called from AgentSession on `.result`.
    /// Zero-usage turns (errors without usage payloads) are skipped.
    static func append(cwd: String, inputTokens: Int, outputTokens: Int,
                       costUsd: Double, model: String? = nil) {
        guard inputTokens > 0 || outputTokens > 0 || costUsd > 0 else { return }
        let record = Record(ts: Date(), cwd: cwd,
                            inputTokens: inputTokens,
                            outputTokens: outputTokens,
                            costUsd: costUsd,
                            model: model)
        guard var data = try? encoder.encode(record) else { return }
        data.append(0x0A)
        let url = fileURL
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }

    /// Read the whole log. Lines that fail to decode (partial writes,
    /// future schema changes) are skipped rather than failing the load.
    static func loadAll() -> [Record] {
        guard let raw = try? String(contentsOf: fileURL, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var out: [Record] = []
        raw.enumerateLines { line, _ in
            guard let data = line.data(using: .utf8),
                  let r = try? decoder.decode(Record.self, from: data) else { return }
            out.append(r)
        }
        return out
    }
}
