import Foundation
import AVFoundation
import Speech
import Combine

/// Record-then-transcribe voice capture (ChatGPT-style). Clicking the mic
/// records the whole utterance to a temp audio file — pauses, silences and
/// all — and nothing is recognized until the user clicks stop. The complete
/// file is then transcribed in one pass and the result lands in
/// `finalTranscript`.
///
/// This deliberately avoids live streaming recognition: Apple's live
/// recognizer finalizes the task after a short silence, which made capture
/// cut off whenever the user paused mid-thought.
@MainActor
final class VoiceCapture: ObservableObject {
    enum Authorization {
        case undetermined
        case granted
        case denied
        case restricted
    }

    @Published private(set) var isRecording = false
    @Published private(set) var isTranscribing = false
    @Published private(set) var finalTranscript: String = ""
    @Published private(set) var errorMessage: String?
    /// Deep link into System Settings for the pane that fixes the current
    /// error — nil when the error isn't a settings problem.
    @Published private(set) var settingsURL: URL?
    @Published private(set) var speechAuthorization: Authorization = .undetermined
    @Published private(set) var micAuthorization: Authorization = .undetermined

    private let engine = AVAudioEngine()
    private var recognizer: SFSpeechRecognizer?
    private var task: SFSpeechRecognitionTask?
    private var audioFile: AVAudioFile?
    private var audioFileURL: URL?

    init() {
        let r = SFSpeechRecognizer(locale: Locale.current) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        self.recognizer = r
        // Reflect the current state without prompting.
        speechAuthorization = mapSpeech(SFSpeechRecognizer.authorizationStatus())
        micAuthorization = mapAV(AVCaptureDevice.authorizationStatus(for: .audio))
    }

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

    private func start() {
        guard !isRecording else { return }
        errorMessage = nil
        settingsURL = nil
        finalTranscript = ""

        guard let recognizer, recognizer.isAvailable else {
            // The most common reason `isAvailable` returns false on a Mac
            // is that Siri AND Dictation are both off in System Settings —
            // SFSpeechRecognizer can't initialize without at least one of
            // them enabled, even with mic + speech permissions granted.
            errorMessage = "Enable Dictation in System Settings → Keyboard → Dictation, then tap the mic again."
            settingsURL = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension?Dictation")
            return
        }

        // Stop the engine first if it was running from a prior session that
        // exited uncleanly. installTap on a running engine throws.
        if engine.isRunning {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }

        let input = engine.inputNode
        // Use the input node's *native* format. Forcing a sample rate causes
        // AVAudioEngine to silently fail on macOS hardware that doesn't
        // support it (typical symptom: tap fires zero buffers).
        let format = input.outputFormat(forBus: 0)
        do {
            try input.setVoiceProcessingEnabled(false)
        } catch {
            // Ignored — voice processing tweaks are nice-to-have.
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-capture-\(UUID().uuidString).caf")
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forWriting: url, settings: format.settings)
        } catch {
            errorMessage = "Could not create recording file: \(error.localizedDescription)"
            return
        }
        audioFile = file
        audioFileURL = url

        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            // Write on the tap's audio thread; AVAudioFile serializes writes.
            try? file.write(from: buffer)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            errorMessage = "Audio engine failed to start: \(error.localizedDescription)"
            teardownRecording()
            return
        }

        isRecording = true
    }

    func stop() {
        guard isRecording else { return }
        teardownRecording()
        isRecording = false
        transcribeCapturedFile()
    }

    /// Stops the engine and closes the file without touching transcription
    /// state.
    private func teardownRecording() {
        if engine.isRunning {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        // Releasing the AVAudioFile closes it and flushes the header.
        audioFile = nil
    }

    private func transcribeCapturedFile() {
        guard let url = audioFileURL, let recognizer, recognizer.isAvailable else {
            discardAudioFile()
            return
        }

        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = false
        request.taskHint = .dictation
        // On-device recognition has no duration limit; the server path caps
        // out around a minute, so prefer local whenever the model exists.
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }

        isTranscribing = true
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self else { return }
                if let result, result.isFinal {
                    self.finalTranscript = result.bestTranscription.formattedString
                    self.finishTranscription()
                    return
                }
                if let error {
                    let ns = error as NSError
                    // 203/1110 = "no speech detected" variants — an empty
                    // recording, not a failure worth surfacing.
                    let benign: Set<Int> = [203, 1110, 301, 216]
                    if !benign.contains(ns.code) {
                        self.errorMessage = error.localizedDescription
                    }
                    self.finishTranscription()
                }
            }
        }
    }

    private func finishTranscription() {
        task?.cancel()
        task = nil
        isTranscribing = false
        discardAudioFile()
    }

    private func discardAudioFile() {
        if let url = audioFileURL {
            try? FileManager.default.removeItem(at: url)
        }
        audioFileURL = nil
        audioFile = nil
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
