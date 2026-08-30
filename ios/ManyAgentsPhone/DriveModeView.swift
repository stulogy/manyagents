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
    @EnvironmentObject private var voice: Voice
    @Environment(\.dismiss) private var dismiss

    @State private var lastSpokenSeq: Int?
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

                HStack(spacing: 8) {
                    Text(bigStatus)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.orange)
                        .textCase(.uppercase)
                        .tracking(1.2)
                    if voice.isBuffering {
                        ProgressView().controlSize(.small).tint(Theme.orange)
                    }
                }

                // Why it suddenly sounds like the phone rather than the
                // voice you chose. Said once, quietly, never in the way.
                if let notice = voice.voiceNotice {
                    Text(notice)
                        .font(.footnote)
                        .foregroundStyle(Theme.dim)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }

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

                if connected {
                    micButton.padding(.bottom, 28)
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "iphone.slash")
                            .font(.system(size: 30, weight: .light))
                        Text("Not connected to your Mac.")
                            .font(.system(size: 15))
                    }
                    .foregroundStyle(Theme.dim)
                    .padding(.bottom, 28)
                }
            }
            .padding(.top, 12)
        }
        .navigationBarBackButtonHidden(true)
        .onAppear {
            link.openTab(tabId)
            // Holds the audio session open so this keeps working with the
            // screen off, which is where a phone is in a car.
            voice.beginHandsFree()
        }
        // Deliberately NOT stopSpeaking(): closing this screen to look at
        // the board shouldn't cut the answer off mid-sentence.
        .onDisappear { voice.leaveHandsFree() }
        // Utterance finished → send it.
        .onChange(of: voice.finishedUtterance) { _, new in
            guard let text = new, !text.isEmpty else { return }
            _ = voice.consumeUtterance()
            link.send(text, to: tabId)
            awaitingReply = true
        }
        // A new assistant message arrived → read it, then listen again.
        .onChange(of: lastAssistant?.seq) { _, _ in
            guard let msg = lastAssistant, msg.seq != lastSpokenSeq else { return }
            lastSpokenSeq = msg.seq
            guard awaitingReply else { return }
            awaitingReply = false
            voice.speak(msg.text)
        }
        // Finished speaking: take the next turn. Always — this screen is
        // for when you can't touch the phone, so "keep listening" was
        // never a real choice.
        .onChange(of: voice.isSpeaking) { was, now in
            guard was, !now, connected, !awaitingReply else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                if connected { voice.startListening() }
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

    private var connected: Bool { link.connection == .connected }

    private var bigStatus: String {
        if !connected { return "not connected" }
        if voice.permissionDenied { return "microphone blocked" }
        if voice.isListening { return "listening" }
        // Fetching audio is not speaking. Saying "speaking" through the
        // silence before the first word makes a working app look hung.
        if voice.isBuffering { return "getting the voice" }
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
