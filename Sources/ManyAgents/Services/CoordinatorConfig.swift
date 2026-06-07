import Foundation

/// Generates the per-session `mcp.json` config that `claude` consumes
/// via `--mcp-config <path>`. Tells claude how to spawn the MCP
/// subprocess — namely, "re-invoke the ManyAgents binary with
/// --mcp-stdio + auth token + relay socket path + this session's id."
///
/// Configs are written to /tmp/manyagents/configs/ and named by the
/// session id. They're harmless if they linger (claude regenerates
/// them per turn), but `cleanup(for:)` removes them on session close.
enum CoordinatorConfig {
    /// Returns the path to a freshly-written mcp.json for `session`.
    /// Throws if MCPRelay isn't started or we can't write the file.
    @MainActor
    static func write(for session: AgentSession) throws -> String {
        guard let socketPath = MCPRelay.shared.socketPath,
              let token = MCPRelay.shared.authToken
        else {
            throw NSError(
                domain: "CoordinatorConfig",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "MCP relay not started"]
            )
        }
        let binary = currentExecutablePath()
        let dir = configsDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("\(session.id.uuidString).json").path

        let payload: [String: Any] = [
            "mcpServers": [
                "manyagents": [
                    "command": binary,
                    "args": [
                        "--mcp-stdio",
                        "--socket", socketPath,
                        "--token", token,
                        "--source", session.id.uuidString
                    ],
                    "env": [String: String]()
                ]
            ]
        ]
        let data = try JSONSerialization.data(
            withJSONObject: payload,
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        return path
    }

    /// Drop the config file for a session on close / coordinator-mode
    /// toggle-off so the configs dir doesn't accumulate stale entries.
    @MainActor
    static func cleanup(for session: AgentSession) {
        let path = configsDir().appendingPathComponent("\(session.id.uuidString).json").path
        try? FileManager.default.removeItem(atPath: path)
    }

    /// Absolute path to the running ManyAgents binary. `Bundle.main
    /// .executablePath` resolves to the .app/Contents/MacOS/<exe>
    /// inside the bundle even when launched via Spotlight, so claude
    /// can re-spawn the same binary regardless of how the app started.
    private static func currentExecutablePath() -> String {
        Bundle.main.executablePath ?? CommandLine.arguments.first ?? "ManyAgents"
    }

    private static func configsDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("manyagents", isDirectory: true)
            .appendingPathComponent("configs", isDirectory: true)
    }
}
