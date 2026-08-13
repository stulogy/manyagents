import Foundation
import AVFoundation
import Speech
import Combine

/// A selectable audio input device for voice capture.
struct AudioInputDevice: Identifiable, Hashable {
    let id: String    // AVCaptureDevice.uniqueID
    let name: String
}

/// Record-then-transcribe voice capture (ChatGPT-style). Clicking the mic
/// records the whole utterance to a temp audio file — pauses, silences and
/// all — and nothing is recognized until the user clicks stop. The complete
/// file is then transcribed in one pass and the result lands in
/// `finalTranscript`.
///
/// Built on AVCaptureSession rather than AVAudioRecorder because the
/// recorder can only use the *system default* input — on a Mac whose
/// default input is an audio interface with nothing plugged in (mixers,
/// USB interfaces), that records perfect silence. The capture session lets
/// the user pick an actual microphone; the choice persists in
/// UserDefaults under `Keys.inputDeviceUID`.
@MainActor
final class VoiceCapture: NSObject, ObservableObject {
    enum Keys {
        static let inputDeviceUID = "voiceInputDeviceUID"
    }

    enum Authorization {
        case undetermined
        case granted
        case denied
        case restricted
    }

    @Published private(set) var isRecording = false
    @Published private(set) var isTranscribing = false
    @Published private(set) var finalTranscript: String = ""
    /// 0…1 input level while recording, for the composer's meter.
    @Published private(set) var audioLevel: Float = 0
    /// Seconds since recording started.
    @Published private(set) var elapsed: TimeInterval = 0
    /// Name of the device actually capturing the current recording.
    @Published private(set) var activeDeviceName: String = ""
    /// Non-error outcome worth telling the user about ("No speech detected").
    @Published private(set) var statusMessage: String?
    @Published private(set) var errorMessage: String?
    /// Deep link into System Settings for the pane that fixes the current
    /// error — nil when the error isn't a settings problem.
    @Published private(set) var settingsURL: URL?
    @Published private(set) var speechAuthorization: Authorization = .undetermined
    @Published private(set) var micAuthorization: Authorization = .undetermined

    private var recognizer: SFSpeechRecognizer?
    private var task: SFSpeechRecognitionTask?
    private var captureSession: AVCaptureSession?
    private var fileOutput: AVCaptureAudioFileOutput?
    private var meterTimer: Timer?
    private var startedAt: Date?
    private var audioFileURL: URL?

    override init() {
        super.init()
        let r = SFSpeechRecognizer(locale: Locale.current) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        self.recognizer = r
        // Reflect the current state without prompting.
        speechAuthorization = mapSpeech(SFSpeechRecognizer.authorizationStatus())
        micAuthorization = mapAV(AVCaptureDevice.authorizationStatus(for: .audio))
    }

    // MARK: - Input device selection

    /// Every microphone/audio input on the machine, for pickers.
    static func availableInputs() -> [AudioInputDevice] {
        discovery().devices.map { AudioInputDevice(id: $0.uniqueID, name: $0.localizedName) }
    }

    /// The device a new recording will use: the user's saved pick when it's
    /// still connected, else the system default input.
    static func resolvedDevice() -> AVCaptureDevice? {
        let all = discovery().devices
        if let uid = UserDefaults.standard.string(forKey: Keys.inputDeviceUID),
           !uid.isEmpty,
           let picked = all.first(where: { $0.uniqueID == uid }) {
            return picked
        }
        return AVCaptureDevice.default(for: .audio) ?? all.first
    }

    private static func discovery() -> AVCaptureDevice.DiscoverySession {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        )
    }

    // MARK: - Toggle / permissions

    /// Toggle path used by the UI's mic button. Handles all permission
    /// prompts inline so the user never lands in a "nothing happens" state.
    func toggle() {
        if isTranscribing { return }
        if isRecording {
            stop()
            return
        }
        ensureAuthorizationAndStart()
    }

    private func ensureAuthorizationAndStart() {
        errorMessage = nil
        settingsURL = nil
        statusMessage = nil
        // 1. Speech recognition.
        if speechAuthorization == .undetermined {
            SFSpeechRecognizer.requestAuthorization { [weak self] status in
                Task { @MainActor in
                    self?.speechAuthorization = self?.mapSpeech(status) ?? .undetermined
                    self?.ensureAuthorizationAndStart()
                }
            }
            return
        }
        guard speechAuthorization == .granted else {
            errorMessage = "Speech recognition not authorized. Enable in System Settings → Privacy & Security → Speech Recognition."
            settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition")
            return
        }
        // 2. Microphone.
        if micAuthorization == .undetermined {
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                Task { @MainActor in
                    self?.micAuthorization = granted ? .granted : .denied
                    self?.ensureAuthorizationAndStart()
                }
            }
            return
        }
        guard micAuthorization == .granted else {
            errorMessage = "Microphone access denied. Enable in System Settings → Privacy & Security → Microphone."
            settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
            return
        }
        // 3. Both granted — actually start recording.
        start()
    }

    // MARK: - Recording

    private func start() {
        guard !isRecording else { return }
        finalTranscript = ""
        audioLevel = 0
        elapsed = 0

        guard let device = Self.resolvedDevice() else {
            errorMessage = "No audio input device found."
            return
        }

        let session = AVCaptureSession()
        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else {
                errorMessage = "Can't record from \(device.localizedName)."
                return
            }
            session.addInput(input)
        } catch {
            errorMessage = "Can't open \(device.localizedName): \(error.localizedDescription)"
            return
        }

        let output = AVCaptureAudioFileOutput()
        guard session.canAddOutput(output) else {
            errorMessage = "Can't record from \(device.localizedName)."
            return
        }
        session.addOutput(output)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-capture-\(UUID().uuidString).m4a")

        captureSession = session
        fileOutput = output
        audioFileURL = url
        activeDeviceName = device.localizedName
        startedAt = Date()

        session.startRunning()
        output.startRecording(to: url, outputFileType: .m4a, recordingDelegate: self)
        isRecording = true

        // Drive the level meter + elapsed clock.
        meterTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isRecording, let output = self.fileOutput else { return }
                // Loudest channel wins — interfaces report many channels and
                // the spoken one is whichever carries signal.
                let db = output.connections
                    .flatMap { $0.audioChannels }
                    .map { $0.averagePowerLevel }
                    .max() ?? -160
                // dBFS (−160…0) mapped −50dB…0dB → 0…1.
                self.audioLevel = max(0, min(1, (db + 50) / 50))
                if let t = self.startedAt {
                    self.elapsed = Date().timeIntervalSince(t)
                }
            }
        }
    }

    func stop() {
        guard isRecording else { return }
        meterTimer?.invalidate()
        meterTimer = nil
        isRecording = false
        audioLevel = 0
        isTranscribing = true
        // Finalizing the file is asynchronous — transcription starts in the
        // didFinishRecordingTo delegate callback.
        fileOutput?.stopRecording()
    }

    private func recordingDidFinish(fileURL: URL, error: Error?) {
        captureSession?.stopRunning()
        captureSession = nil
        fileOutput = nil

        if let error {
            let ns = error as NSError
            let finishedOK = (ns.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool) ?? false
            if !finishedOK {
                errorMessage = "Recording failed: \(error.localizedDescription)"
                finishTranscription()
                return
            }
        }
        transcribeCaptured(url: fileURL)
    }

    // MARK: - Transcription

    private func transcribeCaptured(url: URL) {
        if #available(macOS 26.0, *) {
            // The modern SpeechAnalyzer path handles long-form files properly
            // (the legacy recognizer drops everything before the last pause).
            Task { @MainActor in
                do {
                    let text = try await Self.transcribeWithSpeechAnalyzer(url: url)
                    if text.isEmpty {
                        self.statusMessage = "No speech detected — check the selected microphone (right-click the mic button)."
                    }
                    self.finalTranscript = text
                    self.finishTranscription()
                } catch {
                    // Model missing / locale unsupported / API failure — the
                    // legacy recognizer is better than nothing.
                    self.transcribe(url: url, allowOnDevice: true)
                }
            }
        } else {
            transcribe(url: url, allowOnDevice: true)
        }
    }

    /// Whole-file transcription via the macOS 26 SpeechAnalyzer stack —
    /// built for long-form audio, punctuates automatically, and runs
    /// on-device. Downloads the language model on first use.
    @available(macOS 26.0, *)
    private static func transcribeWithSpeechAnalyzer(url: URL) async throws -> String {
        let supported = await SpeechTranscriber.supportedLocales
        let locale = supported.first {
            $0.identifier(.bcp47) == Locale.current.identifier(.bcp47)
        } ?? supported.first { $0.language.languageCode == Locale.current.language.languageCode }
          ?? Locale(identifier: "en-US")

        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [],       // finals only
            attributeOptions: []
        )
        if let install = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await install.downloadAndInstall()
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])

        async let collected: AttributedString = transcriber.results
            .reduce(into: AttributedString()) { acc, result in
                acc += result.text
            }

        let file = try AVAudioFile(forReading: url)
        if let lastSample = try await analyzer.analyzeSequence(from: file) {
            try await analyzer.finalizeAndFinish(through: lastSample)
        } else {
            await analyzer.cancelAndFinishNow()
        }
        let attributed = try await collected
        return String(attributed.characters).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Segments accumulated by the legacy recognizer — long files emit one
    /// "final" result per utterance, so the transcript is their union, not
    /// any single result.
    private var legacySegments: [String] = []
    private var legacyTimeout: Task<Void, Never>?

    /// Legacy (pre-macOS 26) recognition of the whole file. Tries on-device
    /// first (no duration limit); if that model errors, falls back once to
    /// Apple's servers before giving up.
    private func transcribe(url: URL, allowOnDevice: Bool) {
        guard let recognizer, recognizer.isAvailable else {
            errorMessage = "Speech recognizer unavailable. Enable Dictation in System Settings → Keyboard → Dictation, then try again."
            settingsURL = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension?Dictation")
            finishTranscription()
            return
        }

        legacySegments = []
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = false
        request.taskHint = .dictation
        // Off by default — without it the transcript is one long unpunctuated run.
        request.addsPunctuation = true
        if allowOnDevice && recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self else { return }
                if let result, result.isFinal {
                    let text = result.bestTranscription.formattedString
                    if !text.isEmpty {
                        self.legacySegments.append(text)
                    }
                    // Don't deliver yet — the recognizer keeps going and
                    // emits another final for the next utterance. The take
                    // is done when an end-of-audio error arrives (or the
                    // stream goes quiet — see the timeout).
                    self.armLegacyTimeout()
                    return
                }
                guard let error else { return }
                let ns = error as NSError
                switch ns.code {
                case 203, 1110, 216, 301:
                    // End of audio / "no more speech" / canceled — normal
                    // completion signals for file recognition.
                    self.deliverLegacyTranscript()
                default:
                    if allowOnDevice && self.legacySegments.isEmpty {
                        // The local model can be missing or broken even when
                        // supportsOnDeviceRecognition says yes — retry once
                        // through Apple's servers before surfacing an error.
                        self.task?.cancel()
                        self.task = nil
                        self.transcribe(url: url, allowOnDevice: false)
                    } else if self.legacySegments.isEmpty {
                        self.errorMessage = "Transcription failed: \(error.localizedDescription)"
                        self.finishTranscription()
                    } else {
                        // Something broke mid-file — keep what we got.
                        self.deliverLegacyTranscript()
                    }
                }
            }
        }
    }

    /// Fallback delivery: if no further result or error arrives shortly
    /// after a final segment, assume the file is done.
    private func armLegacyTimeout() {
        legacyTimeout?.cancel()
        legacyTimeout = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled, self.isTranscribing else { return }
            self.deliverLegacyTranscript()
        }
    }

    private func deliverLegacyTranscript() {
        legacyTimeout?.cancel()
        legacyTimeout = nil
        let joined = legacySegments.joined(separator: " ")
        legacySegments = []
        if joined.isEmpty {
            statusMessage = "No speech detected — check the selected microphone (right-click the mic button)."
        }
        finalTranscript = joined
        finishTranscription()
    }

    private func finishTranscription() {
        legacyTimeout?.cancel()
        legacyTimeout = nil
        task?.cancel()
        task = nil
        isTranscribing = false
        discardAudioFile()
        autoClearStatus()
    }

    /// "No speech detected" style notices fade on their own — they're
    /// transient feedback, not persistent errors.
    private func autoClearStatus() {
        guard statusMessage != nil else { return }
        let snapshot = statusMessage
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            if self.statusMessage == snapshot {
                self.statusMessage = nil
            }
        }
    }

    private func discardAudioFile() {
        if let url = audioFileURL {
            try? FileManager.default.removeItem(at: url)
        }
        audioFileURL = nil
    }

    // MARK: - Mapping

    private func mapSpeech(_ s: SFSpeechRecognizerAuthorizationStatus) -> Authorization {
        switch s {
        case .authorized: return .granted
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .undetermined
        @unknown default: return .undetermined
        }
    }

    private func mapAV(_ s: AVAuthorizationStatus) -> Authorization {
        switch s {
        case .authorized: return .granted
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .undetermined
        @unknown default: return .undetermined
        }
    }
}

// MARK: - AVCaptureFileOutputRecordingDelegate

extension VoiceCapture: AVCaptureFileOutputRecordingDelegate {
    nonisolated func fileOutput(
        _ output: AVCaptureFileOutput,
        didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection],
        error: Error?
    ) {
        Task { @MainActor in
            self.recordingDidFinish(fileURL: outputFileURL, error: error)
        }
    }
}
