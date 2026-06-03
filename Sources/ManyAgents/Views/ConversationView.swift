import SwiftUI

/// The main right-pane view — header + scrolling conversation + composer.
struct ConversationView: View {
    @ObservedObject var session: AgentSession

    var body: some View {
        VStack(spacing: 0) {
            header
            conversationScroll
            // Floating composer — capped width, centered with comfortable
            // margins. Mirrors the way the Claude chat panel sits in VS
            // Code: the input doesn't stretch across the whole pane.
            HStack {
                Spacer(minLength: 0)
                ComposerView(session: session)
                    .frame(maxWidth: 760)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 18)
            .padding(.top, 6)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(session.aiTitle ?? session.displayName)
                    .font(AppFont.heading(14.5))
                    .tracking(-0.2)
                Text(ProjectNaming.prettyCwd(session.cwd))
                    .font(AppFont.mono(11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if session.lastTurnContextTokens > 0 {
                contextGauge
            }
            if let sid = session.claudeSessionId {
                Text(String(sid.prefix(8)))
                    .font(AppFont.mono(10))
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(
            Color(nsColor: .windowBackgroundColor).opacity(0.6)
        )
        .overlay(
            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(height: 1)
                .frame(maxHeight: .infinity, alignment: .bottom)
        )
    }

    /// Compact "N% context" pill showing how full claude's context window
    /// is. Tints warm at 60%, red past 85% so the user has a visual cue
    /// to /compact before the model starts thrashing.
    private var contextGauge: some View {
        let used = session.lastTurnContextTokens
        let cap  = session.contextWindowTokens
        let pct  = min(max(Double(used) / Double(cap), 0), 1)
        let tint: Color = {
            if pct > 0.85 { return .red }
            if pct > 0.60 { return .orange }
            return Color.activeHighlight
        }()
        return HStack(spacing: 6) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(Color.primary.opacity(0.12))
                    .frame(width: 56, height: 4)
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(tint)
                    .frame(width: 56 * pct, height: 4)
            }
            Text(percentLabel(pct: pct, used: used))
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(tint)
                .monospacedDigit()
        }
        .help("Context: \(used.formatted()) / \(cap.formatted()) tokens · \(Int(pct * 100))%")
    }

    private func percentLabel(pct: Double, used: Int) -> String {
        if pct >= 0.01 { return "\(Int(pct * 100))%" }
        // Under 1%, show absolute tokens so it doesn't perpetually read "0%".
        if used < 1000 { return "\(used)t" }
        return String(format: "%.1fk", Double(used) / 1000)
    }

    private var conversationScroll: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 28) {
                    if session.messages.isEmpty {
                        emptyState
                    }
                    ForEach(session.messages) { msg in
                        MessageView(message: msg)
                            .id(msg.id)
                    }
                    if session.status == .running {
                        ThinkingIndicator(session: session)
                            .id("thinking")
                    }
                    // Bottom anchor — empty spacer at the very end so we
                    // have a stable id to scroll to even when there are
                    // zero messages or the thinking indicator isn't showing.
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
                .frame(maxWidth: 1180, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            // macOS 14+: tell SwiftUI this is a chat-style scroll view.
            // The scroll position naturally tracks the bottom as content
            // grows, and the initial position lands at the bottom — no
            // more "scroll up a little to see anything" on restore.
            .defaultScrollAnchor(.bottom)
            // Belt-and-braces: also call scrollTo on content changes so
            // active streams stay pinned to the latest token even if the
            // anchor logic decides we're "scrolled away" from the bottom.
            .onChange(of: session.messages.count) { _, _ in scrollToLatest(proxy) }
            .onChange(of: totalBlocks) { _, _ in scrollToLatest(proxy) }
            .onChange(of: session.status) { _, _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                    scrollToLatest(proxy)
                }
            }
        }
    }

    /// Target the last message's id (not the sentinel) so SwiftUI's
    /// LazyVStack actually has to construct that row to compute the
    /// scroll offset. While a turn is running we scroll to the
    /// `"thinking"` indicator instead so the user sees the dots the
    /// instant they appear, not just the trailing edge of their own
    /// prompt with the indicator clipped below the fold.
    private func scrollToLatest(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.25)) {
            if session.status == .running {
                proxy.scrollTo("thinking", anchor: .bottom)
            } else if let lastId = session.messages.last?.id {
                proxy.scrollTo(lastId, anchor: .bottom)
            } else {
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
    }

    private var totalBlocks: Int {
        session.messages.reduce(0) { $0 + $1.blocks.count }
    }

    /// Inline status line that mirrors Claude Code's progress UX —
    /// `verb… (elapsed · ↓ tokens · phase)`. Verb rotates every ~25 s so a
    /// long stream stays visually alive instead of frozen on one word.
    private struct ThinkingIndicator: View {
        @ObservedObject var session: AgentSession
        @State private var now: Date = Date()
        private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

        /// Curated list matching Claude Code's whimsy. Index = floor(elapsed / 25).
        private static let verbs = [
            "Thinking", "Pondering", "Considering", "Mulling", "Spelunking",
            "Warping", "Jitterbugging", "Hyperspacing", "Crunching", "Brewing",
            "Stewing", "Percolating", "Marinating", "Quantumizing", "Synthesizing",
            "Cogitating", "Ruminating", "Reasoning", "Reckoning", "Untangling"
        ]

        private var elapsed: TimeInterval {
            guard let start = session.currentTurnStartedAt else { return 0 }
            return now.timeIntervalSince(start)
        }

        private var verb: String {
            let idx = Int(elapsed / 25) % Self.verbs.count
            return Self.verbs[idx]
        }

        private var elapsedLabel: String {
            let s = Int(elapsed)
            if s < 60 { return "\(s)s" }
            return "\(s / 60)m \(s % 60)s"
        }

        private var tokenLabel: String? {
            let n = session.currentTurnOutputTokens
            guard n > 0 else { return nil }
            if n < 1000 { return "↓ \(n) tokens" }
            let k = Double(n) / 1000.0
            return String(format: "↓ %.1fk tokens", k)
        }

        var body: some View {
            HStack(alignment: .center, spacing: 8) {
                // TimelineView drives a continuous time-based animation
                // independent of SwiftUI's state ticks, so the dots
                // ripple smoothly without any state churn or animation
                // restarts when other things in the view update.
                TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { context in
                    let t = context.date.timeIntervalSinceReferenceDate
                    HStack(spacing: 5) {
                        ForEach(0..<3) { i in
                            let phase = t * 2.8 - Double(i) * 0.45
                            let s = 0.55 + 0.55 * pow(sin(phase) * 0.5 + 0.5, 2)
                            let o = 0.35 + 0.65 * (sin(phase) * 0.5 + 0.5)
                            Circle()
                                .fill(Color.brandOrange)
                                .frame(width: 6, height: 6)
                                .scaleEffect(s)
                                .opacity(o)
                        }
                    }
                    .frame(width: 32, height: 12, alignment: .leading)
                }
                Text(statusLine)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .contentTransition(.opacity)
                    .animation(.easeInOut(duration: 0.25), value: statusLine)
            }
            .padding(.vertical, 4)
            .onReceive(tick) { now = $0 }
        }

        private var statusLine: String {
            var parts: [String] = []
            parts.append("\(verb)…")
            if elapsed >= 1 {
                var meta: [String] = [elapsedLabel]
                if let t = tokenLabel { meta.append(t) }
                meta.append(session.currentPhase)
                parts.append("(\(meta.joined(separator: " · ")))")
            }
            return parts.joined(separator: " ")
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.tertiary)
                .padding(.top, 60)
            Text("Send a prompt to start the conversation")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            if let err = session.lastError {
                Text(err)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }
        }
        .frame(maxWidth: .infinity)
    }
}
