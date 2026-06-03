import SwiftUI
import AppKit

/// Input area below the conversation. Single-line height to start, grows
/// with content. Return sends; Shift+Return inserts a newline. Mic button
/// for push-to-talk. Pasted images stack above the editor as thumbnails
/// and get sent along with the text on submit.
struct ComposerView: View {
    @ObservedObject var session: AgentSession
    @StateObject private var voice = VoiceCapture()
    @State private var draft: String = ""
    @State private var preVoiceDraft: String = ""
    @State private var pendingImages: [Data] = []
    @State private var pendingImageFingerprints: Set<String> = []
    @State private var editorHeight: CGFloat = 36
    /// Anthropic recommends ≤5 images per request; more than that and the
    /// API starts rejecting or truncating. We cap at this in the composer.
    private static let maxPendingImages = 8
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 8) {
            voiceErrorBanner
            if !session.pendingPrompts.isEmpty {
                queuedStrip
            }
            if !pendingImages.isEmpty {
                imageStrip
            }
            HStack(alignment: .bottom, spacing: 8) {
                editor
                micButton
                sendButton
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.55))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(borderColor, lineWidth: 1)
        )
        .onAppear { focused = true }
        .onChange(of: voice.liveTranscript) { _, partial in
            guard voice.isRecording else { return }
            draft = preVoiceDraft.isEmpty
                ? partial
                : preVoiceDraft + " " + partial
        }
    }

    @ViewBuilder
    private var voiceErrorBanner: some View {
        if let err = voice.errorMessage, !err.isEmpty {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.orange)
                Text(err)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.primary.opacity(0.85))
                    .lineLimit(2)
                Spacer(minLength: 0)
                Button("Open Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension?Dictation") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.borderless)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Color.brandOrange)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.orange.opacity(0.10))
            )
        }
    }

    private var borderColor: Color {
        if voice.isRecording { return Color.red.opacity(0.7) }
        if focused { return Color.activeHighlight.opacity(0.45) }
        return Color.primary.opacity(0.08)
    }

    private var editor: some View {
        PasteAwareTextEditor(
            text: $draft,
            height: $editorHeight,
            placeholder: "Message…",
            font: NSFont.systemFont(ofSize: 13.5, weight: .regular),
            minHeight: 36,
            maxHeight: 240,
            onSubmit: submit,
            onImagePaste: { datas in
                ingest(images: datas)
            }
        )
        .frame(height: editorHeight)
    }

    /// Normalize, dedupe, and cap pasted images before they land in the
    /// composer's pending list. Without this a few screenshot pastes can
    /// blow past the Anthropic request size cap and the next send fails
    /// silently.
    private func ingest(images datas: [Data]) {
        for raw in datas {
            guard pendingImages.count < Self.maxPendingImages else { break }
            guard let normalized = ImageProcessing.normalize(raw) else { continue }
            let fp = ImageProcessing.fingerprint(normalized)
            if pendingImageFingerprints.contains(fp) { continue }
            pendingImageFingerprints.insert(fp)
            pendingImages.append(normalized)
        }
    }

    private var imageStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Array(pendingImages.enumerated()), id: \.offset) { idx, data in
                    if let nsImg = NSImage(data: data) {
                        ZStack(alignment: .topTrailing) {
                            Image(nsImage: nsImg)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: 56, height: 56)
                                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .stroke(Color.primary.opacity(0.18), lineWidth: 1)
                                )
                            Button {
                                pendingImageFingerprints.remove(ImageProcessing.fingerprint(data))
                                pendingImages.remove(at: idx)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 14))
                                    .foregroundStyle(.white, Color.black.opacity(0.7))
                            }
                            .buttonStyle(.plain)
                            .offset(x: 4, y: -4)
                        }
                    }
                }
            }
            .padding(.horizontal, 4)
        }
        .frame(height: 66)
    }

    private var micButton: some View {
        Button(action: toggleRecording) {
            Image(systemName: voice.isRecording ? "stop.circle.fill" : "mic.circle.fill")
                .font(.system(size: 28))
                .foregroundStyle(voice.isRecording ? .red : .secondary.opacity(0.75))
        }
        .buttonStyle(.plain)
        .help(voice.isRecording ? "Stop recording" : "Dictate")
    }

    private var sendButton: some View {
        Button(action: submit) {
            Image(systemName: "arrow.up.circle.fill")
                .font(.system(size: 28))
                .foregroundStyle(canSubmit ? Color.brandOrange : Color.secondary.opacity(0.5))
        }
        .buttonStyle(.plain)
        .disabled(!canSubmit)
        .help("Send (↩)")
    }

    private var canSubmit: Bool {
        let hasText = !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        // Allow submission while running — the prompt gets queued and
        // dispatched FIFO when the current turn lands.
        return (hasText || !pendingImages.isEmpty) && !voice.isRecording
    }

    /// Strip above the composer listing pending queued prompts. Click X
    /// on any to remove it before it fires.
    private var queuedStrip: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(session.pendingPrompts) { p in
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "clock.fill")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Color.brandOrange.opacity(0.8))
                        .padding(.top, 3)
                    Text(p.text.isEmpty ? "(image only)" : p.text)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    // Force-send: bumps this prompt to the front and
                    // cancels the in-flight turn so it fires now.
                    Button {
                        session.forceSend(id: p.id)
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.brandOrange.opacity(0.85))
                    }
                    .buttonStyle(.plain)
                    .help("Send now (interrupts current turn)")
                    Button {
                        session.removeQueued(id: p.id)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help("Remove queued prompt")
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(0.04))
                )
            }
        }
    }

    private func submit() {
        guard canSubmit else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let images = pendingImages
        session.send(text, images: images)
        draft = ""
        pendingImages = []
        pendingImageFingerprints = []
    }

    private func toggleRecording() {
        if voice.isRecording {
            voice.toggle()
            if !voice.finalTranscript.isEmpty {
                draft = preVoiceDraft.isEmpty
                    ? voice.finalTranscript
                    : preVoiceDraft + " " + voice.finalTranscript
            }
            focused = true
        } else {
            preVoiceDraft = draft.trimmingCharacters(in: .whitespacesAndNewlines)
            voice.toggle()
        }
    }
}
