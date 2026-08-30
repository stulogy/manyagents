#if DEBUG
import Foundation
import os

/// A headless run of the speech path, for `manyagents://voicetest`.
///
/// It reports what it found rather than what it assumed: whether a key is
/// present, where it came from, and what the API said. Debug builds only.
@MainActor
enum VoiceDiagnostics {
    private static let log = Logger(subsystem: "co.ailogy.manyagents.phone",
                                    category: "voice")

    /// `manyagents://voicetest?key=…&voice=…&text=…` — every part
    /// optional, so it can test what's already configured or a candidate
    /// key without pairing anything.
    static func run(url: URL? = nil,
                    text: String = "Pushed the fix and the tests are green. Want me to open the pull request?") {
        let s = VoiceSettings.shared
        var say = text
        if let items = url.flatMap({ URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems }) {
            for item in items {
                switch item.name {
                case "key":   if let v = item.value, !v.isEmpty { s.setKeyManually(v) }
                case "voice": if let v = item.value, !v.isEmpty { s.voiceID = v }
                case "text":  if let v = item.value, !v.isEmpty { say = v }
                case "chatkey": if let v = item.value, !v.isEmpty { s.setChatKey(v) }
                default: break
                }
            }
        }
        log.info("""
            diagnostics: engine=\(s.engine.rawValue, privacy: .public) \
            hasKey=\(s.hasKey) source=\(s.keySource.rawValue, privacy: .public) \
            keyChars=\(s.apiKey.count) voice=\(s.voiceID, privacy: .public)
            """)
        let v = Voice.shared
        Task {
            if let failure = await v.preview(say) {
                log.error("diagnostics: FAILED — \(failure, privacy: .public)")
            } else {
                log.info("diagnostics: spoke it")
            }
        }
    }

    /// `manyagents://companiontest?text=…` — one full turn through the
    /// on-phone companion: model, tools, the Mac, and speech. Reading the
    /// board is free and touches nothing; asking an orchestrator sends a
    /// real message, so keep test prompts read-only unless you mean it.
    private static var companion: Companion?

    static func runCompanion(url: URL?) {
        let items = url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems } ?? []
        for item in items where item.name == "chatkey" {
            if let v = item.value, !v.isEmpty { VoiceSettings.shared.setChatKey(v) }
        }
        let text = items.first { $0.name == "text" }?.value ?? "What is everyone working on?"
        let scope = items.first { $0.name == "scope" }?.value
        let c = Companion.shared
        companion = c
        if let scope, !scope.isEmpty {
            MacLink.shared.askForCompanion(scope: scope, create: true) { tab in
                log.info("test scope \(scope, privacy: .public) -> tab \(tab ?? "none", privacy: .public)")
            }
        }
        log.info("companion test: hasChatKey=\(VoiceSettings.shared.hasChatKey) board=\(MacLink.shared.board.count) tabs connectors=[\(MacLink.shared.connectors.joined(separator: ", "), privacy: .public)] facts=\(Companion.shared.facts.count)")
        Task {
            await c.say(text)
            for turn in c.turns {
                log.info("turn [\(String(describing: turn.who), privacy: .public)]: \(turn.text, privacy: .public)")
            }
            if let e = c.lastError { log.error("companion error: \(e, privacy: .public)") }
        }
    }
}
#endif
