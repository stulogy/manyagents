import Foundation
import AVFoundation
import Speech

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

    @Published private(set) var isListening = false
    @Published private(set) var isSpeaking = false
    @Published private(set) var heard = ""
    @Published private(set) var permissionDenied = false
    /// Set when the recogniser decides you've stopped talking.
    @Published private(set) var finishedUtterance: String?
    /// Last reason the cloud voice bailed, if it did. Shown quietly rather
    /// than thrown as an alert — the reply still gets read out.
    @Published private(set) var voiceNotice: String?

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

    override init() {
        super.init()
        synth.delegate = self
    }

    // MARK: - Session

    /// One session config for the whole app: duck the radio rather than
    /// stopping it, and pick the right Bluetooth profile for what we're
    /// about to do.
    ///
    /// The profile is the whole game in a car. `.allowBluetooth` means
    /// HFP — the hands-free phone-call channel, 8 kHz mono — and once a
    /// car kit is on it, speech comes out stuttering and thin. That's what
    /// made the built-in voice unusable while driving, and it would have
    /// done the same to ElevenLabs audio. Recording needs HFP because A2DP
    /// carries no microphone, so it's requested there and *only* there;
    /// playback asks for A2DP alone, which is the stereo music route the
    /// car already plays well.
    private func configureSession(forRecording: Bool) throws {
        let session = AVAudioSession.sharedInstance()
        if forRecording {
            try session.setCategory(.playAndRecord, mode: .measurement,
                                    options: [.duckOthers, .defaultToSpeaker,
                                              .allowBluetooth, .allowBluetoothA2DP])
        } else {
            try session.setCategory(.playback, mode: .spokenAudio,
                                    options: [.duckOthers, .allowBluetoothA2DP])
        }
        try session.setActive(true, options: .notifyOthersOnDeactivation)
    }

    /// Hand the route back before playing. Without this the session can
    /// still be sitting on the HFP link it took to record, and the first
    /// reply plays down the call channel however good the audio is.
    private func releaseRecordingRoute() {
        guard !engine.isRunning else { return }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
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
                try configureSession(forRecording: true)
                let req = SFSpeechAudioBufferRecognitionRequest()
                req.shouldReportPartialResults = true
                request = req

                let input = engine.inputNode
                let format = input.outputFormat(forBus: 0)
                input.removeTap(onBus: 0)
                input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
                    self?.request?.append(buffer)
                }
                engine.prepare()
                try engine.start()
                isListening = true

                recognitionTask = recognizer?.recognitionTask(with: req) { [weak self] result, error in
                    Task { @MainActor in
                        guard let self else { return }
                        if let result {
                            self.heard = result.bestTranscription.formattedString
                            self.resetSilenceTimer()
                        }
                        if error != nil || result?.isFinal == true {
                            self.finishListening()
                        }
                    }
                }
            } catch {
                isListening = false
            }
        }
    }

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

    func speak(_ raw: String) {
        let text = Self.speakable(raw)
        guard !text.isEmpty else { return }
        stopSpeaking()
        voiceNotice = nil
        releaseRecordingRoute()
        do { try configureSession(forRecording: false) } catch { }

        guard let config = settings.elevenConfig else {
            speakOnDevice(text)
            return
        }
        isSpeaking = true
        eleven.speak(text, config: config,
                     onFinish: { [weak self] in self?.isSpeaking = false },
                     onFailure: { [weak self] remaining, error in
                         guard let self else { return }
                         // Say the rest in this phone's own voice. Told
                         // about it afterwards, not interrupted by it.
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
        releaseRecordingRoute()
        do { try configureSession(forRecording: false) } catch { }
        guard let config = settings.elevenConfig else {
            speakOnDevice(text)
            return nil
        }
        stopSpeaking()
        isSpeaking = true
        return await withCheckedContinuation { (c: CheckedContinuation<String?, Never>) in
            var resumed = false
            eleven.speak(text, config: config,
                         onFinish: { [weak self] in
                             self?.isSpeaking = false
                             if !resumed { resumed = true; c.resume(returning: nil) }
                         },
                         onFailure: { [weak self] _, error in
                             self?.isSpeaking = false
                             if !resumed { resumed = true; c.resume(returning: error.localizedDescription) }
                         })
        }
    }

    func stopSpeaking() {
        eleven.stop()
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
        isSpeaking = false
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
        Task { @MainActor in self.isSpeaking = false }
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.isSpeaking = false }
    }
}
