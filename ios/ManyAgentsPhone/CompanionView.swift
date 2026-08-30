import SwiftUI

/// Hands-free conversation with the companion.
///
/// Same rule as before: after the first tap you should never need to look
/// at the phone. It listens, sends when you stop talking, thinks, asks the
/// Mac if it needs to, and reads back what matters. What's on screen is a
/// courtesy for when you're stopped, not something you have to watch.
struct CompanionView: View {
    @EnvironmentObject var link: MacLink
    @EnvironmentObject var voice: Voice
    @StateObject private var companion: Companion
    @Environment(\.dismiss) private var dismiss

    init(link: MacLink, voice: Voice) {
        _companion = StateObject(wrappedValue: Companion(link: link, voice: voice))
    }

    var body: some View {
        ZStack {
            Theme.canvas.ignoresSafeArea()

            VStack(spacing: 18) {
                header

                HStack(spacing: 8) {
                    Text(status)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.orange)
                        .textCase(.uppercase)
                        .tracking(1.2)
                    if companion.busy || voice.isBuffering {
                        ProgressView().controlSize(.small).tint(Theme.orange)
                    }
                }

                transcript

                Spacer(minLength: 0)

                // Only shown once the Mac is actually reachable. A mic
                // that takes your words and has nowhere to send them is
                // worse than no mic: you talk, and nothing happens.
                if connected {
                    micButton.padding(.bottom, 28)
                } else {
                    disconnected.padding(.bottom, 28)
                }
            }
            .padding(.top, 12)
        }
        .navigationBarBackButtonHidden(true)
        // Opens silent and listening. It has nothing to say until you've
        // said something, and being greeted by a status report you didn't
        // ask for is the thing you have to sit through before you can
        // start.
        .onAppear {
            voice.beginHandsFree()
            if connected { voice.startListening() }
        }
        .onChange(of: connected) { _, now in
            if now, !voice.isListening, !voice.isSpeaking, !companion.busy {
                voice.startListening()
            }
        }
        .onDisappear { voice.leaveHandsFree() }
        .onChange(of: voice.finishedUtterance) { _, new in
            guard let text = new, !text.isEmpty else { return }
            _ = voice.consumeUtterance()
            Task { await companion.say(text) }
        }
        // Finished reading a reply: take the next turn. Hands-free is the
        // whole point of this screen, so it isn't a setting — it's on.
        .onChange(of: voice.isSpeaking) { was, now in
            guard was, !now, connected, !companion.busy else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                if !companion.busy && connected { voice.startListening() }
            }
        }
    }

    private var header: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.dim)
                    .padding(10)
            }
            Spacer()
            VStack(spacing: 1) {
                Text("ManyAgents")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Text(scopeLine)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.dim)
            }
            Spacer()
            Color.clear.frame(width: 38, height: 1)
        }
        .padding(.horizontal, 8)
    }

    /// The live turn gets the big type; older ones fade back. One thing to
    /// read at a glance, with the thread still there if you're parked.
    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(companion.turns) { turn in
                        Text(turn.text)
                            .font(.system(size: turn.id == companion.turns.last?.id ? 22 : 16,
                                          weight: turn.who == .you ? .regular : .medium))
                            .foregroundStyle(colour(for: turn))
                            .frame(maxWidth: .infinity,
                                   alignment: turn.who == .you ? .trailing : .leading)
                            .id(turn.id)
                    }
                    if voice.isListening, !voice.heard.isEmpty {
                        Text(voice.heard)
                            .font(.system(size: 22))
                            .foregroundStyle(Theme.dim)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                            .id("live")
                    }
                }
                .padding(.horizontal, 22)
            }
            .onChange(of: companion.turns.count) { _, _ in
                withAnimation { proxy.scrollTo(companion.turns.last?.id, anchor: .bottom) }
            }
        }
        .frame(maxHeight: 340)
    }

    private func colour(for turn: Companion.Turn) -> Color {
        switch turn.who {
        case .you:       return Theme.dim
        case .companion: return Theme.text
        case .note:      return Theme.orange
        }
    }

    private var connected: Bool { link.reachable }

    /// What you get instead of a microphone when there's no Mac on the
    /// other end.
    private var disconnected: some View {
        VStack(spacing: 14) {
            Image(systemName: "iphone.slash")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Theme.dim)
            Text(disconnectedReason)
                .font(.system(size: 15))
                .foregroundStyle(Theme.dim)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Button("Try again") { link.reconnect() }
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.orange)
        }
    }

    private var disconnectedReason: String {
        switch link.connection {
        case .connected:  return "Waiting for the board from your Mac…"
        case .connecting: return "Connecting to your Mac…"
        case .macOffline: return "ManyAgents isn't running on your Mac."
        case .idle:       return "Not paired to a Mac."
        case .failed(let why): return why
        }
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

    private var status: String {
        if !connected { return "not connected" }
        if voice.permissionDenied { return "microphone blocked" }
        if voice.isListening { return "listening" }
        if let doing = companion.activity, companion.busy { return doing }
        if voice.isBuffering { return "getting the voice" }
        if voice.isSpeaking { return "speaking" }
        return "tap to talk"
    }

    private var scopeLine: String {
        guard let id = link.companionTab,
              let tab = link.board.first(where: { $0.id == id })
        else { return "\(link.board.count) tabs" }
        return link.scopeName(of: tab)
    }
}
