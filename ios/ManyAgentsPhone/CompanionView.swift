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

    @State private var handsFree = true

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
        .onAppear {
            voice.beginHandsFree()
            Task { await companion.openingBrief() }
        }
        .onDisappear { voice.leaveHandsFree() }
        .onChange(of: voice.finishedUtterance) { _, new in
            guard let text = new, !text.isEmpty else { return }
            _ = voice.consumeUtterance()
            Task { await companion.say(text) }
        }
        .onChange(of: voice.isSpeaking) { was, now in
            // Finished reading a reply: take the next turn.
            if was && !now && handsFree && !companion.busy {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    if handsFree && !companion.busy { voice.startListening() }
                }
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
