import SwiftUI

/// Hands-free conversation with one tab.
///
/// The rule this screen follows: after the first tap you should never need
/// to look at the phone again. It listens, sends when you stop talking,
/// reads the reply aloud, and starts listening again. Everything on screen
/// is big enough to read at a glance and nothing needs a precise tap.
struct DriveModeView: View {
    let tabId: String
    @EnvironmentObject var link: MacLink
    @StateObject private var voice = Voice()
    @Environment(\.dismiss) private var dismiss

    @State private var handsFree = true
    @State private var lastSpokenId: UUID?
    @State private var awaitingReply = false

    private var tab: MacLink.Tab? { link.board.first { $0.id == tabId } }
    private var lastAssistant: MacLink.Msg? {
        link.messages[tabId]?.last { $0.role == "assistant" }
    }

    var body: some View {
        ZStack {
            Theme.canvas.ignoresSafeArea()

            VStack(spacing: 22) {
                header

                Spacer(minLength: 0)

                Text(bigStatus)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.orange)
                    .textCase(.uppercase)
                    .tracking(1.2)

                // What it heard, or what the agent last said — whichever is
                // live right now. One thing on screen at a time.
                ScrollView {
                    Text(centrePiece)
                        .font(.system(size: voice.isListening ? 26 : 20, weight: .medium))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(Theme.text)
                        .padding(.horizontal, 24)
                        .animation(.easeOut(duration: 0.15), value: centrePiece)
                }
                .frame(maxHeight: 320)

                Spacer(minLength: 0)

                micButton

                Toggle(isOn: $handsFree) {
                    Text("Keep listening after each reply")
                        .font(.footnote)
                        .foregroundStyle(Theme.dim)
                }
                .toggleStyle(.switch)
                .tint(Theme.orange)
                .padding(.horizontal, 40)
                .padding(.bottom, 18)
            }
            .padding(.top, 12)
        }
        .navigationBarBackButtonHidden(true)
        .onAppear { link.openTab(tabId) }
        .onDisappear {
            voice.cancelListening()
            voice.stopSpeaking()
        }
        // Utterance finished → send it.
        .onChange(of: voice.finishedUtterance) { _, new in
            guard let text = new, !text.isEmpty else { return }
            _ = voice.consumeUtterance()
            link.send(text, to: tabId)
            awaitingReply = true
        }
        // A new assistant message arrived → read it, then listen again.
        .onChange(of: lastAssistant?.id) { _, _ in
            guard let msg = lastAssistant, msg.id != lastSpokenId else { return }
            lastSpokenId = msg.id
            guard awaitingReply else { return }
            awaitingReply = false
            voice.speak(msg.text)
        }
        .onChange(of: voice.isSpeaking) { was, now in
            // Finished speaking and hands-free is on: take the next turn.
            if was && !now && handsFree && !awaitingReply {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    if handsFree { voice.startListening() }
                }
            }
        }
    }

    private var header: some View {
        HStack {
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.dim)
                    .padding(10)
            }
            Spacer()
            VStack(spacing: 1) {
                Text(tab?.title ?? "Tab")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Text(tab?.project ?? "")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.dim)
            }
            Spacer()
            Color.clear.frame(width: 38, height: 1)
        }
        .padding(.horizontal, 8)
    }

    private var micButton: some View {
        Button {
            if voice.isListening {
                voice.finishListening()
            } else {
                voice.stopSpeaking()
                voice.startListening()
            }
        } label: {
            ZStack {
                Circle()
                    .fill(voice.isListening ? Theme.orange : Theme.raised)
                    .frame(width: 116, height: 116)
                    .overlay(
                        Circle().strokeBorder(Theme.orange.opacity(voice.isListening ? 0 : 0.5),
                                              lineWidth: 1.5)
                    )
                Image(systemName: voice.isListening ? "waveform" : "mic.fill")
                    .font(.system(size: 40, weight: .medium))
                    .foregroundStyle(voice.isListening ? Color.black : Theme.orange)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(voice.isListening ? "Stop listening" : "Start talking")
    }

    private var bigStatus: String {
        if voice.permissionDenied { return "microphone blocked" }
        if voice.isListening { return "listening" }
        if voice.isSpeaking { return "speaking" }
        if awaitingReply || tab?.isBusy == true { return "working" }
        return "tap to talk"
    }

    private var centrePiece: String {
        if voice.isListening {
            return voice.heard.isEmpty ? "…" : voice.heard
        }
        if awaitingReply || tab?.isBusy == true {
            return "Sent. Waiting for \(tab?.title ?? "the agent")…"
        }
        if let last = lastAssistant {
            return Voice.speakable(last.text)
        }
        return "Say what you want it to do."
    }
}
