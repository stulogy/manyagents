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
    private static var voice: Voice?

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
                default: break
                }
            }
        }
        log.info("""
            diagnostics: engine=\(s.engine.rawValue, privacy: .public) \
            hasKey=\(s.hasKey) source=\(s.keySource.rawValue, privacy: .public) \
            keyChars=\(s.apiKey.count) voice=\(s.voiceID, privacy: .public)
            """)
        let v = Voice()
        voice = v          // held, or it deallocates mid-sentence
        Task {
            if let failure = await v.preview(say) {
                log.error("diagnostics: FAILED — \(failure, privacy: .public)")
            } else {
                log.info("diagnostics: spoke it")
            }
        }
    }
}
#endif
