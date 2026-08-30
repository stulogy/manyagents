import Foundation
import AVFoundation
import Speech
import os

/// Speech in and speech out.
///
/// The two halves are split on purpose, because they have opposite
/// tradeoffs. Listening stays on-device: Apple's recogniser starts
/// instantly, costs nothing per word, works with no signal, and degrades
/// to "didn't catch that" rather than a spinner. Speaking goes to
/// ElevenLabs when a key is configured, because this is the half you
/// actually sit and listen to and the difference is not subtle.
///
/// The on-device synthesiser stays as the floor underneath: no key, no
/// signal, or an API that errors, and the reply is still read out — in a
/// worse voice, which is a far better outcome than silence.
@MainActor
final class Voice: NSObject, ObservableObject {

    /// One instance for the app, not one per screen.
    ///
    /// Owned by a view, speech died the moment you left the screen that
    /// started it — you'd tap back to the board to see what it was talking
    /// about and it went quiet mid-sentence. Audio outlives views: it
    /// stops when you stop it, when it finishes, or when something else
    /// starts talking.
    static let shared = Voice()

    @Published private(set) var isListening = false
    @Published private(set) var isSpeaking = false
    @Published private(set) var heard = ""
    @Published private(set) var permissionDenied = false
    /// Set when the recogniser decides you've stopped talking.
    @Published private(set) var finishedUtterance: String?
    /// Last reason the cloud voice bailed, if it did. Shown quietly rather
    /// than thrown as an alert — the reply still gets read out.
    @Published private(set) var voiceNotice: String?
    /// Fetching the first audio. A cloud voice has a gap between "asked"
    /// and "talking", and without saying so, that gap is indistinguishable
    /// from the app being broken.
    @Published private(set) var isBuffering = false

    private let engine = AVAudioEngine()
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-GB"))
        ?? SFSpeechRecognizer()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let synth = AVSpeechSynthesizer()
    private let eleven = ElevenLabsSpeaker()
    private let settings = VoiceSettings.shared
    private var silenceTimer: Timer?
    /// How long a pause means "I'm done talking". Long enough to think
    /// mid-sentence, short enough not to feel broken.
    private let silenceGap: TimeInterval = 1.4
    private static let log = Logger(subsystem: "co.ailogy.manyagents.phone", category: "voice")

    override init() {
        super.init()
        synth.delegate = self
    }

    // MARK: - Session

    enum Use { case idle, speaking, listening }

    /// The audio session, reconfigured for each of the three things this
    /// app does with sound. Two decisions are load-bearing in a car:
    ///
    /// **The Bluetooth profile.** `.allowBluetooth` means HFP, the
    /// hands-free call channel — 8 kHz, mono, half-duplex. A car kit put
    /// on it for the microphone stays there, and every reply afterwards
    /// plays down a phone-call link however good the source audio is;
    /// that's what made speech choppy while driving. A2DP carries no
    /// microphone, so HFP is asked for while listening and nowhere else.
    ///
    /// **Ducking.** Ducking the radio is right while the voice is talking
    /// and wrong the rest of the time — the keep-alive below plays silence
    /// continuously, and ducking on that would leave your music quiet for
    /// the whole drive. So idle mixes, speech ducks.
    private func configureSession(_ use: Use) throws {
        let session = AVAudioSession.sharedInstance()
        switch use {
        case .listening:
            try session.setCategory(.playAndRecord, mode: .measurement,
                                    options: [.duckOthers, .defaultToSpeaker,
                                              .allowBluetooth, .allowBluetoothA2DP])
        case .speaking:
            try session.setCategory(.playback, mode: .spokenAudio,
                                    options: [.duckOthers, .allowBluetoothA2DP])
        case .idle:
            try session.setCategory(.playback, mode: .spokenAudio,
                                    options: [.mixWithOthers, .allowBluetoothA2DP])
        }
        try session.setActive(true, options: .notifyOthersOnDeactivation)
    }

    // MARK: - Staying alive with the screen off

    /// Hands-free is worth nothing if it stops the moment the phone locks,
    /// which is where a phone lives in a car. An app with the audio
    /// background mode keeps running only while it is actually playing
    /// something, so between turns — while an agent is thinking — this
    /// plays silence to hold the process, the socket and the microphone
    /// open. It mixes rather than ducks, so nothing else goes quiet.
    ///
    /// Started when drive mode opens and stopped when it closes: the cost
    /// is real, and it has no business running while the app sits in a
    /// pocket doing nothing.
    private var keepAlive: AVAudioPlayer?

    func beginHandsFree() {
        guard keepAlive == nil else { return }
        do {
            try configureSession(.idle)
            let player = try AVAudioPlayer(data: Self.silence())
            player.numberOfLoops = -1
            player.volume = 0
            player.play()
            keepAlive = player
            Self.log.info("hands-free session held open")
        } catch {
            Self.log.error("keep-alive failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func endHandsFree() {
        keepAlive?.stop()
        keepAlive = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// Leaving the hands-free screen: stop listening — a hot microphone
    /// you can't see is not something to leave running — but let the
    /// current reply finish. The session is released once it does, so the
    /// app isn't holding audio open for nothing.
    func leaveHandsFree() {
        cancelListening()
        guard isSpeaking || isBuffering else {
            endHandsFree()
            return
        }
        releaseWhenQuiet = true
    }

    private var releaseWhenQuiet = false

    /// Called wherever speech ends, from either voice.
    fileprivate func settled() {
        guard releaseWhenQuiet, !isSpeaking, !isBuffering else { return }
        releaseWhenQuiet = false
        endHandsFree()
    }

    /// Done talking, whichever voice did it: drop the duck so the car's
    /// own audio comes back while the agent thinks.
    fileprivate func finishedSpeaking() {
        isSpeaking = false
        if !queue.isEmpty {
            startSpeaking(queue.removeFirst())
            return
        }
        if keepAlive != nil { try? configureSession(.idle) }
        settled()
    }

    /// Half a second of 44.1 kHz mono silence, built rather than bundled so
    /// there's no asset to lose.
    private static func silence(seconds: Double = 0.5) -> Data {
        let rate = 44_100, channels = 1, bits = 16
        let frames = Int(Double(rate) * seconds)
        let dataBytes = frames * channels * bits / 8
        var out = Data()
        func u32(_ v: Int) { var l = UInt32(v).littleEndian; out.append(Data(bytes: &l, count: 4)) }
        func u16(_ v: Int) { var l = UInt16(v).littleEndian; out.append(Data(bytes: &l, count: 2)) }
        out.append(contentsOf: Array("RIFF".utf8)); u32(36 + dataBytes)
        out.append(contentsOf: Array("WAVE".utf8))
        out.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(channels)
        u32(rate); u32(rate * channels * bits / 8); u16(channels * bits / 8); u16(bits)
        out.append(contentsOf: Array("data".utf8)); u32(dataBytes)
        out.append(Data(count: dataBytes))
        return out
    }

    func requestPermissions() async -> Bool {
        let speech = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) }
        }
        let mic = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            AVAudioApplication.requestRecordPermission { c.resume(returning: $0) }
        }
        permissionDenied = !(speech && mic)
        return speech && mic
    }

    // MARK: - Listening

    func startListening() {
        guard !isListening else { return }
        stopSpeaking()          // never listen to ourselves
        heard = ""
        finishedUtterance = nil

        Task {
            guard await requestPermissions() else { return }
            do {
                try configureSession(.listening)
                let req = SFSpeechAudioBufferRecognitionRequest()
                req.shouldReportPartialResults = true
                request = req

                let input = engine.inputNode
                // inputFormat, not outputFormat: after a route change —
                // and switching from the keep-alive's playback session to
                // playAndRecord is a route change — the output format can
                // still describe the old route, and a tap installed with
                // it delivers no buffers. No buffers means no partial
                // results, no silence timer, and a microphone that sits
                // there looking like it's listening to you and isn't.
                input.removeTap(onBus: 0)
                let format = input.inputFormat(forBus: 0)
                guard format.sampleRate > 0, format.channelCount > 0 else {
                    Self.log.error("listen: input format is \(format.sampleRate)Hz — no usable mic route")
                    isListening = false
                    return
                }
                input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
                    self?.request?.append(buffer)
                }
                engine.prepare()
                try engine.start()
                isListening = true
                Self.log.info("listen: started at \(format.sampleRate, format: .fixed(precision: 0))Hz")
                startHearingWatchdog()

                recognitionTask = recognizer?.recognitionTask(with: req) { [weak self] result, error in
                    Task { @MainActor in
                        guard let self else { return }
                        if let result {
                            self.heard = result.bestTranscription.formattedString
                            self.hearingWatchdog?.invalidate()
                            self.hearingWatchdog = nil
                            self.resetSilenceTimer()
                        }
                        if error != nil || result?.isFinal == true {
                            self.finishListening()
                        }
                    }
                }
            } catch {
                Self.log.error("listen: \(error.localizedDescription, privacy: .public)")
                isListening = false
            }
        }
    }

    /// A microphone that hears literally nothing is a broken microphone,
    /// not a quiet room: the recogniser emits a partial result for any
    /// speech at all. If nothing arrives for this long, stop pretending
    /// and hand back so the caller can try again rather than leaving you
    /// talking to a dead screen.
    private var hearingWatchdog: Timer?

    private func startHearingWatchdog() {
        hearingWatchdog?.invalidate()
        hearingWatchdog = Timer.scheduledTimer(withTimeInterval: 8, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isListening, self.heard.isEmpty else { return }
                Self.log.error("listen: 8s with no audio — restarting the mic")
                self.cancelListening()
                self.deafened = true
            }
        }
    }

    /// Set when the watchdog fired: the last attempt heard nothing at all.
    @Published private(set) var deafened = false

    func clearDeafened() { deafened = false }

    /// Restarted on every partial result: when it fires, you've gone quiet
    /// long enough that we should send what we have. This is what makes
    /// it usable while driving — no second tap to submit.
    private func resetSilenceTimer() {
        silenceTimer?.invalidate()
        silenceTimer = Timer.scheduledTimer(withTimeInterval: silenceGap, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.finishListening() }
        }
    }

    func finishListening() {
        silenceTimer?.invalidate()
        silenceTimer = nil
        hearingWatchdog?.invalidate()
        hearingWatchdog = nil
        guard isListening else { return }
        isListening = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        request?.endAudio()
        recognitionTask?.cancel()
        request = nil
        recognitionTask = nil
        let text = heard.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { finishedUtterance = text }
    }

    func cancelListening() {
        heard = ""
        finishedUtterance = nil
        finishListening()
    }

    func consumeUtterance() -> String? {
        defer { finishedUtterance = nil }
        return finishedUtterance
    }

    // MARK: - Speaking

    /// Things said while something else is still being said. The
    /// companion often speaks twice in a turn — "I'll go and ask" and then
    /// the answer — and having the second cut the first off mid-word made
    /// it sound like it had crashed.
    private var queue: [String] = []

    func speak(_ raw: String) {
        let text = Self.speakable(raw)
        guard !text.isEmpty else { return }
        guard !isSpeaking && !isBuffering else {
            queue.append(text)
            return
        }
        startSpeaking(text)
    }

    private func startSpeaking(_ text: String) {
        voiceNotice = nil
        do { try configureSession(.speaking) } catch { }

        guard let config = settings.elevenConfig else {
            speakOnDevice(text)
            return
        }
        isSpeaking = true
        isBuffering = true
        eleven.speak(text, config: config,
                     onAudioStart: { [weak self] in self?.isBuffering = false },
                     onFinish: { [weak self] in
                         self?.isBuffering = false
                         self?.finishedSpeaking()
                     },
                     onFailure: { [weak self] remaining, error in
                         guard let self else { return }
                         // Say the rest in this phone's own voice. Told
                         // about it afterwards, not interrupted by it.
                         self.isBuffering = false
                         self.voiceNotice = error.localizedDescription
                         self.speakOnDevice(remaining)
                     })
    }

    /// The floor: Apple's synthesiser. Takes text that has already been
    /// through `speakable`.
    private func speakOnDevice(_ text: String) {
        guard !text.isEmpty else { isSpeaking = false; return }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = Self.bestVoice()
        utterance.rate = 0.52          // slightly quicker than default; still clear in a car
        utterance.prefersAssistiveTechnologySettings = false
        isSpeaking = true
        synth.speak(utterance)
    }

    /// Say something right now with the current settings, ignoring the
    /// fallback chain — used by the settings screen's test button, where
    /// silently succeeding in the wrong voice would be the one useless
    /// outcome.
    func preview(_ text: String) async -> String? {
        do { try configureSession(.speaking) } catch { }
        guard let config = settings.elevenConfig else {
            speakOnDevice(text)
            return nil
        }
        stopSpeaking()
        isSpeaking = true
        isBuffering = true
        return await withCheckedContinuation { (c: CheckedContinuation<String?, Never>) in
            var resumed = false
            eleven.speak(text, config: config,
                         onAudioStart: { [weak self] in self?.isBuffering = false },
                         onFinish: { [weak self] in
                             self?.isBuffering = false
                             self?.isSpeaking = false
                             if !resumed { resumed = true; c.resume(returning: nil) }
                         },
                         onFailure: { [weak self] _, error in
                             self?.isBuffering = false
                             self?.isSpeaking = false
                             if !resumed { resumed = true; c.resume(returning: error.localizedDescription) }
                         })
        }
    }

    func stopSpeaking() {
        queue.removeAll()
        isBuffering = false
        eleven.stop()
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
        isSpeaking = false
        settled()
        // Un-duck: whatever the car was playing comes back between turns
        // rather than staying quiet for the whole drive.
        if keepAlive != nil { try? configureSession(.idle) }
    }

    /// Prefer a downloaded premium/enhanced voice when the user has one;
    /// the default compact voice is the robotic one people complain about.
    private static func bestVoice() -> AVSpeechSynthesisVoice? {
        let voices = AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("en") }
        return voices.first { $0.quality == .premium }
            ?? voices.first { $0.quality == .enhanced }
            ?? AVSpeechSynthesisVoice(language: "en-GB")
    }

    /// Agent replies are full of code, paths and markdown punctuation.
    /// Read verbatim they're unlistenable, so say what a code block IS
    /// rather than reading its contents, and drop the syntax noise.
    static func speakable(_ raw: String) -> String {
        var out: [String] = []
        var inFence = false
        var fencedLines = 0

        for line in raw.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if inFence {
                    out.append(fencedLines == 1 ? "then one line of code."
                                                : "then \(fencedLines) lines of code.")
                    fencedLines = 0
                }
                inFence.toggle()
                continue
            }
            if inFence { fencedLines += 1; continue }
            if trimmed.isEmpty { continue }

            var s = trimmed
            // Headings and list bullets read as sentences, not symbols.
            s = s.replacingOccurrences(of: "^#{1,6}\\s*", with: "", options: .regularExpression)
            s = s.replacingOccurrences(of: "^[-*]\\s+", with: "", options: .regularExpression)
            s = s.replacingOccurrences(of: "`([^`]*)`", with: "$1", options: .regularExpression)
            s = s.replacingOccurrences(of: "\\*\\*([^*]*)\\*\\*", with: "$1", options: .regularExpression)
            s = s.replacingOccurrences(of: "\\[([^\\]]*)\\]\\([^)]*\\)", with: "$1", options: .regularExpression)
            // A bare URL read aloud is thirty seconds of nothing.
            s = s.replacingOccurrences(of: "https?://\\S+", with: "a link", options: .regularExpression)
            out.append(s)
        }
        return out.joined(separator: " ")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }
}

extension Voice: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.finishedSpeaking() }
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.finishedSpeaking() }
    }
}
