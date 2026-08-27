import Foundation
import AVFoundation
import os

/// Reads text aloud with an ElevenLabs voice.
///
/// The thing that makes or breaks this in a car is time-to-first-word, so
/// a reply is not sent as one request. It's split at sentence boundaries,
/// the first piece is kept deliberately short, and each piece is fetched
/// while the previous one is still playing. You hear the first sentence in
/// about the time it takes to synthesise one sentence, no matter how long
/// the agent's answer is.
///
/// Every failure is recoverable: whatever hasn't been spoken yet is handed
/// back so the caller can finish it with the phone's own voice. Losing
/// signal mid-reply should cost you a change of accent, not the answer.
@MainActor
final class ElevenLabsSpeaker: NSObject {

    struct Config: Equatable, Sendable {
        var apiKey: String
        var voiceID: String
        var model: String
    }

    enum Failure: LocalizedError {
        case http(Int, String)
        case badAudio

        var errorDescription: String? {
            switch self {
            case .http(401, _):    return "ElevenLabs rejected that API key."
            case .http(429, _):    return "ElevenLabs rate-limited this request."
            case .http(let c, let body):
                let detail = body.prefix(140)
                return detail.isEmpty ? "ElevenLabs returned \(c)." : "ElevenLabs \(c): \(detail)"
            case .badAudio:        return "ElevenLabs sent audio this phone couldn't play."
            }
        }
    }

    /// Voice problems are invisible by nature — you get silence either
    /// way. Every step says what it did, so `log stream --predicate
    /// 'subsystem == "co.ailogy.manyagents.phone"'` answers "which half
    /// broke" without a rebuild.
    static let log = Logger(subsystem: "co.ailogy.manyagents.phone", category: "voice")

    private var player: AVAudioPlayer?
    private var playback: CheckedContinuation<Void, Never>?
    private var job: Task<Void, Never>?
    /// Bumped by every stop/new utterance; in-flight work checks it and
    /// bows out rather than talking over what came after it.
    private var generation = 0

    var isSpeaking: Bool { job != nil }

    /// - Parameters:
    ///   - onAudioStart: the first audio is actually playing. Everything
    ///     before this is network, and silence during it looks identical
    ///     to a hang unless the caller says otherwise.
    ///   - onFinish: the whole thing was spoken.
    ///   - onFailure: could not continue. Carries the text that never got
    ///     said, for the caller to fall back with.
    func speak(_ text: String,
               config: Config,
               onAudioStart: @escaping () -> Void = {},
               onFinish: @escaping () -> Void,
               onFailure: @escaping (String, Error) -> Void) {
        stop()
        generation += 1
        let mine = generation
        let chunks = Self.chunk(text)
        Self.log.info("speak: \(text.count) chars, \(chunks.count) chunks, voice \(config.voiceID, privacy: .public)")
        guard !chunks.isEmpty else {
            Self.log.error("speak: nothing to say after chunking")
            onFinish(); return
        }

        job = Task { [weak self] in
            guard let self else { return }
            // Chunk i+1 is requested before chunk i is played, so the
            // network wait for it happens during audio we already have.
            var inFlight: Task<Data, Error>? = self.fetchTask(chunks[0], config)
            for i in chunks.indices {
                guard mine == self.generation, let current = inFlight else { return }
                inFlight = i + 1 < chunks.count ? self.fetchTask(chunks[i + 1], config) : nil
                do {
                    let data = try await current.value
                    guard mine == self.generation else { return }
                    Self.log.info("chunk \(i): \(data.count) bytes")
                    if i == 0 { onAudioStart() }
                    try await self.play(data)
                } catch is CancellationError {
                    return
                } catch {
                    guard mine == self.generation else { return }
                    inFlight?.cancel()
                    self.job = nil
                    Self.log.error("chunk \(i) failed: \(error.localizedDescription, privacy: .public)")
                    onFailure(chunks[i...].joined(separator: " "), error)
                    return
                }
            }
            guard mine == self.generation else { return }
            self.job = nil
            onFinish()
        }
    }

    func stop() {
        generation += 1
        job?.cancel()
        job = nil
        player?.stop()
        player = nil
        playback?.resume()
        playback = nil
    }

    // MARK: - Network

    private func fetchTask(_ text: String, _ config: Config) -> Task<Data, Error> {
        Task.detached(priority: .userInitiated) {
            try await Self.synthesise(text, config)
        }
    }

    /// One session for every request, configured for a moving car rather
    /// than a desk: wait for connectivity instead of failing the instant
    /// the radio is between cells, and don't let a stalled connection sit
    /// there past the point the answer is still wanted.
    private nonisolated static let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.waitsForConnectivity = true
        c.timeoutIntervalForRequest = 20
        c.timeoutIntervalForResource = 45
        c.allowsConstrainedNetworkAccess = true
        c.allowsExpensiveNetworkAccess = true
        return URLSession(configuration: c)
    }()

    /// Errors worth one more go. A dropped connection mid-request is the
    /// normal state of a phone in a moving car, and giving up on the first
    /// one drops you to the built-in voice for no good reason.
    private nonisolated static func isTransient(_ error: Error) -> Bool {
        if case Failure.http(let code, _) = error { return code == 429 || code >= 500 }
        let ns = error as NSError
        guard ns.domain == NSURLErrorDomain else { return false }
        return [NSURLErrorNetworkConnectionLost, NSURLErrorTimedOut,
                NSURLErrorCannotConnectToHost, NSURLErrorNotConnectedToInternet,
                NSURLErrorSecureConnectionFailed].contains(ns.code)
    }

    private nonisolated static func synthesise(_ text: String, _ config: Config) async throws -> Data {
        do {
            return try await request(text, config)
        } catch {
            guard isTransient(error) else { throw error }
            log.info("retrying after: \(error.localizedDescription, privacy: .public)")
            try await Task.sleep(nanoseconds: 400_000_000)
            return try await request(text, config)
        }
    }

    private nonisolated static func request(_ text: String, _ config: Config) async throws -> Data {
        // 22 kHz / 32 kbps mp3: available on every ElevenLabs plan
        // (the higher bitrates are not), and indistinguishable from the
        // default over a car speaker while being a third of the bytes to
        // pull down on a patchy cellular link.
        //
        // Not the /stream variant. Streaming saves a little time to first
        // byte, but it answers with a chunked response held open until the
        // whole clip is generated, and that connection being dropped
        // underneath us — "the network connection was lost" — was exactly
        // what stopped anything playing. A plain response with a
        // Content-Length is the thing URLSession is reliable at.
        var comps = URLComponents(string:
            "https://api.elevenlabs.io/v1/text-to-speech/\(config.voiceID)")!
        comps.queryItems = [.init(name: "output_format", value: "mp3_22050_32")]

        var req = URLRequest(url: comps.url!)
        req.httpMethod = "POST"
        req.timeoutInterval = 20
        req.setValue(config.apiKey, forHTTPHeaderField: "xi-api-key")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "text": text,
            "model_id": config.model,
            // ElevenLabs' own recommended defaults for assistant voices.
            // Lowering similarity_boost makes delivery less stable, not
            // more natural, which is the trap here.
            "voice_settings": [
                "stability": 0.5,
                "similarity_boost": 0.75,
                "style": 0,
                "use_speaker_boost": true,
            ],
            "text_normalization": "auto",
        ])

        let (data, response) = try await session.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            throw Failure.http(code, String(data: data, encoding: .utf8) ?? "")
        }
        guard !data.isEmpty else { throw Failure.badAudio }
        return data
    }

    // MARK: - Playback

    private func play(_ data: Data) async throws {
        guard let p = try? AVAudioPlayer(data: data) else {
            Self.log.error("play: AVAudioPlayer rejected \(data.count) bytes")
            throw Failure.badAudio
        }
        p.delegate = self
        player = p
        p.volume = 1
        p.prepareToPlay()
        guard p.play() else {
            Self.log.error("play: refused to start (session inactive?)")
            throw Failure.badAudio
        }
        let route = AVAudioSession.sharedInstance().currentRoute.outputs
            .map(\.portType.rawValue).joined(separator: ",")
        Self.log.info("play: \(p.duration, format: .fixed(precision: 1))s out of \(route, privacy: .public)")
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            playback = c
        }
    }

    private func playbackEnded() {
        playback?.resume()
        playback = nil
    }

    // MARK: - Chunking

    /// Split for latency first, prosody second.
    ///
    /// The opening chunk is short so the first word arrives fast; later
    /// chunks are longer because by then there's audio playing to hide the
    /// request behind, and fewer, longer requests read more naturally
    /// (ElevenLabs has no sentence before or after a chunk to take its
    /// intonation from).
    nonisolated static func chunk(_ text: String, first: Int = 160, rest: Int = 420) -> [String] {
        let sentences = split(text)
        var out: [String] = []
        var buffer = ""
        for sentence in sentences {
            let limit = out.isEmpty ? first : rest
            if buffer.isEmpty {
                buffer = sentence
            } else if buffer.count + 1 + sentence.count <= limit {
                buffer += " " + sentence
            } else {
                out.append(buffer)
                buffer = sentence
            }
            // A single sentence longer than the limit still goes on its own.
            if buffer.count >= limit {
                out.append(buffer)
                buffer = ""
            }
        }
        if !buffer.isEmpty { out.append(buffer) }
        return out.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    /// Sentence-ish. Deliberately dumb, and careful about the one case that
    /// actually shows up in agent replies: a version or file name like
    /// "0.13.7" or "MacLink.swift", where the dot is not an ending.
    private nonisolated static func split(_ text: String) -> [String] {
        var out: [String] = []
        var current = ""
        let chars = Array(text)
        for (i, c) in chars.enumerated() {
            current.append(c)
            guard c == "." || c == "!" || c == "?" || c == "\n" else { continue }
            let next = i + 1 < chars.count ? chars[i + 1] : " "
            let previous = i > 0 ? chars[i - 1] : " "
            if c == ".", previous.isNumber || previous.isLetter, !next.isWhitespace { continue }
            if !next.isWhitespace && next != "\n" { continue }
            out.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
            current = ""
        }
        let tail = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { out.append(tail) }
        return out.filter { !$0.isEmpty }
    }
}

extension ElevenLabsSpeaker: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.playbackEnded() }
    }
    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor in self.playbackEnded() }
    }
}
