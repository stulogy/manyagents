import SwiftUI
import AppKit

/// Input area below the conversation. Single-line height to start, grows
/// with content. Return sends; Shift+Return inserts a newline. Mic button
/// for push-to-talk. Pasted images stack above the editor as thumbnails
/// and get sent along with the text on submit.
struct ComposerView: View {
    @ObservedObject var session: AgentSession
    @StateObject private var voice = VoiceCapture()
    /// Composer text. Persisted on `AgentSession.draftText` so a half-
    /// typed prompt survives tab switches — previously this was a
    /// `@State` local, which got reset every time ConversationView re-
    /// mounted (keyed on session.id) and lost in-flight typing.
    private var draft: Binding<String> {
        Binding(get: { self.session.draftText },
                set: { self.session.draftText = $0 })
    }
    @State private var preVoiceDraft: String = ""
    @State private var pendingImages: [Data] = []
    @State private var pendingImageFingerprints: Set<String> = []
    @State private var editorHeight: CGFloat = 44
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
        .padding(.vertical, 12)
        // Solid surface + visible border + elevation shadow so the
        // composer reads as a distinct input affordance instead of
        // dissolving into the dark conversation panel. Focus state
        // adds a faint orange halo so you can see when keyboard
        // input is captured.
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.98))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(borderColor, lineWidth: focused || voice.isRecording ? 1.5 : 1)
        )
        .shadow(
            color: Color.black.opacity(0.35),
            radius: 14,
            x: 0,
            y: 4
        )
        .shadow(
            color: focused ? Color.brandOrange.opacity(0.18) : .clear,
            radius: 10,
            x: 0,
            y: 0
        )
        .onAppear { focused = true }
        .onChange(of: voice.liveTranscript) { _, partial in
            guard voice.isRecording else { return }
            session.draftText = preVoiceDraft.isEmpty
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
        if focused { return Color.brandOrange.opacity(0.55) }
        return Color.primary.opacity(0.20)
    }

    private var editor: some View {
        PasteAwareTextEditor(
            text: draft,
            height: $editorHeight,
            placeholder: "Message…",
            // Bumped from 13.5 — the composer needs to read at LEAST
            // as confidently as the assistant prose above it, otherwise
            // typing feels like a relegated afterthought.
            font: NSFont.systemFont(ofSize: 15, weight: .regular),
            minHeight: 44,
            maxHeight: 280,
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
        let hasText = !session.draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        // Allow submission while running — the prompt gets queued and
        // dispatched FIFO when the current turn lands.
        return (hasText || !pendingImages.isEmpty) && !voice.isRecording
    }

    /// Row currently hovered by a queued-prompt drag — draws the
    /// insertion line.
    @State private var dropTargetId: UUID?

    /// Every queued prompt names itself — never a bare "Automatic
    /// message" and never raw bracket meta-text.
    private func queuedDisplay(_ p: AgentSession.PendingPrompt) -> (label: String, isAuto: Bool) {
        if p.isBoardWake ?? false { return ("Board update", true) }
        if p.isCatchUp ?? false || p.text.hasPrefix("[Orchestrator catch-up") {
            return ("Orchestrator catch-up", true)
        }
        if p.text.hasPrefix("[Compacted from prior conversation") {
            return ("Compaction brief", true)
        }
        if p.text.hasPrefix("[Message from orchestrator") {
            return ("Message from Orchestrator", true)
        }
        if !p.visible { return ("Background instruction", true) }
        return (p.text.isEmpty ? "(image only)" : p.text, false)
    }

    /// Strip above the composer listing pending queued prompts. Click X
    /// on any to remove it before it fires.
    private var queuedStrip: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(session.pendingPrompts) { p in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "clock.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.brandOrange.opacity(0.85))
                        .padding(.top, 4)
                    // Plumbing prompts (catch-up, board wakes, compaction
                    // seeds, orchestrator traffic) queue like anything
                    // else, but their raw meta-text isn't something the
                    // user wrote — show a named label instead of the guts.
                    let d = queuedDisplay(p)
                    Text(d.label)
                        .font(.system(size: 14))
                        .italic(d.isAuto)
                        .foregroundStyle(d.isAuto ? Color.secondary : Color.primary.opacity(0.85))
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        // Hover reveals what a labeled row actually carries.
                        .help(String(p.text.prefix(400)))
                    // Force-send: bumps this prompt to the front and
                    // cancels the in-flight turn so it fires now.
                    Button {
                        session.forceSend(id: p.id)
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 15))
                            .foregroundStyle(Color.brandOrange.opacity(0.9))
                    }
                    .buttonStyle(.plain)
                    .help("Send now (interrupts current turn)")
                    Button {
                        session.removeQueued(id: p.id)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help("Remove queued prompt")
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(0.04))
                )
                // Drag-to-reorder: same String-payload pattern as tab
                // reordering. Dropping on a row inserts before it.
                .overlay(alignment: .top) {
                    if dropTargetId == p.id {
                        Rectangle().fill(Color.brandOrange).frame(height: 2)
                    }
                }
                .contentShape(Rectangle())
                .draggable(p.id.uuidString)
                .dropDestination(for: String.self) { items, _ in
                    guard let raw = items.first,
                          let movedId = UUID(uuidString: raw),
                          movedId != p.id else { return false }
                    session.reorderQueued(movedId: movedId, before: p.id)
                    return true
                } isTargeted: { targeted in
                    dropTargetId = targeted ? p.id : (dropTargetId == p.id ? nil : dropTargetId)
                }
            }
        }
    }

    private func submit() {
        guard canSubmit else { return }
        let text = session.draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        let images = pendingImages
        session.send(text, images: images)
        session.draftText = ""
        pendingImages = []
        pendingImageFingerprints = []
    }

    private func toggleRecording() {
        if voice.isRecording {
            voice.toggle()
            if !voice.finalTranscript.isEmpty {
                session.draftText = preVoiceDraft.isEmpty
                    ? voice.finalTranscript
                    : preVoiceDraft + " " + voice.finalTranscript
            }
            focused = true
        } else {
            preVoiceDraft = session.draftText.trimmingCharacters(in: .whitespacesAndNewlines)
            voice.toggle()
        }
    }
}
