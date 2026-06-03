import Foundation
import AVFoundation
import Speech
import Combine

/// On-device speech recognition wrapper. Push-to-talk: caller toggles
/// `start()` and `stop()`, partial transcripts stream via @Published
/// `liveTranscript`, final result lands in `finalTranscript` once stopped.
@MainActor
final class VoiceCapture: ObservableObject {
    enum Authorization {
        case undetermined
        case granted
        case denied
        case restricted
    }

    @Published private(set) var isRecording = false
    @Published private(set) var liveTranscript: String = ""
    @Published private(set) var finalTranscript: String = ""
    @Published private(set) var errorMessage: String?
    @Published private(set) var speechAuthorization: Authorization = .undetermined
    @Published private(set) var micAuthorization: Authorization = .undetermined

    private let engine = AVAudioEngine()
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

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
        if isRecording {
            stop()
            return
        }
        ensureAuthorizationAndStart()
    }

    private func ensureAuthorizationAndStart() {
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
            return
        }
        // 3. Both granted — actually start recording.
        start()
    }

    private func start() {
        guard !isRecording else { return }
        errorMessage = nil
        liveTranscript = ""
        finalTranscript = ""

        guard let recognizer, recognizer.isAvailable else {
            // The most common reason `isAvailable` returns false on a Mac
            // is that Siri AND Dictation are both off in System Settings —
            // SFSpeechRecognizer can't initialize without at least one of
            // them enabled, even with mic + speech permissions granted.
            errorMessage = "Enable Dictation in System Settings → Keyboard → Dictation, then tap the mic again."
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        self.request = request

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
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            errorMessage = "Audio engine failed to start: \(error.localizedDescription)"
            cleanup()
            return
        }

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self else { return }
                if let result {
                    self.liveTranscript = result.bestTranscription.formattedString
                    if result.isFinal {
                        self.finalTranscript = result.bestTranscription.formattedString
                        self.cleanup()
                    }
                }
                if let error {
                    let ns = error as NSError
                    let benign: Set<Int> = [203, 1110, 301, 216]
                    if !benign.contains(ns.code) {
                        self.errorMessage = error.localizedDescription
                    }
                    self.cleanup()
                }
            }
        }

        isRecording = true
    }

    func stop() {
        guard isRecording else { return }
        finalTranscript = liveTranscript
        cleanup()
    }

    private func cleanup() {
        if engine.isRunning {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        isRecording = false
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
