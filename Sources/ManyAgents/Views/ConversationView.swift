import SwiftUI

/// The main right-pane view — header + scrolling conversation + composer.
struct ConversationView: View {
    @ObservedObject var session: AgentSession
    @EnvironmentObject var manager: AgentManager
    @State private var showingChainSettings = false

    var body: some View {
        VStack(spacing: 0) {
            header
            conversationScroll
            // Pending hand-off banner — fires when another agent's
            // "Send to → Stage on target" lands a prompt here. Sits
            // above the AskUserQuestion picker so a chained question
            // is still resolvable in the normal flow.
            if session.pendingHandOff != nil {
                HStack {
                    Spacer(minLength: 0)
                    PendingHandOffBanner(session: session)
                        .frame(maxWidth: 760)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 8)
            }
            // Mid-turn AskUserQuestion picker — appears between the
            // conversation and the composer when claude is waiting on a
            // user-side option pick. Disappears the instant we send the
            // answer back as a tool_result.
            if session.pendingAskUserQuestion != nil {
                HStack {
                    Spacer(minLength: 0)
                    AskUserQuestionPicker(session: session)
                        .frame(maxWidth: 760)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 8)
            }

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
            chainHeaderChip
            if session.lastTurnContextTokens > 0 {
                contextGauge
            }
            chainGearButton
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

    /// Header indicator showing this session's chain wiring at a
    /// glance — outgoing (chain target set), incoming (chainSourceId set
    /// because another session fed this one), or hidden otherwise.
    /// Click opens the chain settings popover.
    @ViewBuilder
    private var chainHeaderChip: some View {
        if session.chainTargetId != nil || session.chainSourceId != nil {
            Button {
                showingChainSettings = true
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: session.chainTargetId != nil
                          ? "arrow.turn.up.right"
                          : "arrow.turn.down.right")
                        .font(.system(size: 9.5, weight: .semibold))
                    Text(chainChipLabel)
                        .font(.system(size: 10, weight: .semibold))
                }
                .foregroundStyle(Color.brandOrange)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(
                    Capsule().fill(Color.brandOrange.opacity(0.12))
                )
            }
            .buttonStyle(.plain)
            .help("Chain settings")
        }
    }

    private var chainChipLabel: String {
        if let targetId = session.chainTargetId,
           let target = manager.sessions.first(where: { $0.id == targetId }) {
            let title = target.aiTitle ?? target.displayName
            return "→ \(title)"
        }
        if let sourceId = session.chainSourceId,
           let source = manager.sessions.first(where: { $0.id == sourceId }) {
            let title = source.aiTitle ?? source.displayName
            return "from \(title)"
        }
        return "chained"
    }

    /// Always-visible gear that opens the chain settings popover.
    /// Quiet when no chain is wired, brand-tinted when it is.
    private var chainGearButton: some View {
        Button {
            showingChainSettings = true
        } label: {
            Image(systemName: "link")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(
                    session.chainTargetId != nil
                        ? Color.brandOrange
                        : Color.secondary
                )
                .padding(4)
        }
        .buttonStyle(.plain)
        .help("Pipeline & coordination")
        .popover(isPresented: $showingChainSettings, arrowEdge: .top) {
            ChainSettingsPopover(session: session,
                                 onClose: { showingChainSettings = false })
        }
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

    /// Bucket subagent activity (messages with a parent_tool_use_id) by
    /// the parent Task tool_use's id, and return the list of messages
    /// that should appear at top level (everything that ISN'T wholly
    /// inside a subagent). MessageView renders the parent Task's card
    /// with its children folded inside.
    private var grouped: (top: [Message], children: [String: [Message]]) {
        var top: [Message] = []
        var children: [String: [Message]] = [:]
        for msg in session.messages {
            // A message belongs "under" a subagent if EVERY block in it
            // carries the same parent_tool_use_id. Mixed messages
            // (rare — e.g. an intermediate user prompt) stay top-level.
            let parents = Set(msg.blocks.compactMap(\.parentToolUseId))
            if parents.count == 1, let parent = parents.first,
               msg.blocks.allSatisfy({ $0.parentToolUseId == parent }) {
                children[parent, default: []].append(msg)
            } else {
                top.append(msg)
            }
        }
        return (top, children)
    }

    private var conversationScroll: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 28) {
                    if session.messages.isEmpty {
                        emptyState
                    }
                    let g = grouped
                    ForEach(g.top) { msg in
                        MessageView(message: msg,
                                    subagentChildren: g.children,
                                    sessionCwd: session.cwd,
                                    sessionId: session.id)
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
            // Restore-from-snapshot bug: ConversationView is keyed on
            // session.id and mounts with `messages` already fully
            // populated, so .defaultScrollAnchor(.bottom) computes its
            // initial offset before the LazyVStack has materialized the
            // trailing rows — viewport lands near the top until the user
            // nudges. Fire scrollTo at expanding intervals so we still
            // land at the bottom even for thousand-message transcripts
            // that take ~500ms to lay out.
            .onAppear { kickToBottom(proxy) }
        }
    }

    private func kickToBottom(_ proxy: ScrollViewProxy) {
        Task { @MainActor in
            for nanos in [50_000_000, 200_000_000, 500_000_000, 1_000_000_000] {
                try? await Task.sleep(nanoseconds: UInt64(nanos))
                if let lastId = session.messages.last?.id {
                    proxy.scrollTo(lastId, anchor: .bottom)
                } else {
                    proxy.scrollTo("bottom", anchor: .bottom)
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

        /// Curated list matching Claude Code's whimsy. Index = floor(elapsed / 25).
        private static let verbs = [
            "Thinking", "Pondering", "Considering", "Mulling", "Spelunking",
            "Warping", "Jitterbugging", "Hyperspacing", "Crunching", "Brewing",
            "Stewing", "Percolating", "Marinating", "Quantumizing", "Synthesizing",
            "Cogitating", "Ruminating", "Reasoning", "Reckoning", "Untangling"
        ]

        /// `now` is supplied by a TimelineView so the elapsed display
        /// updates exactly once per second regardless of how much
        /// @Published state thrash the partial-message stream is
        /// causing elsewhere. The previous Timer.publish + @State pair
        /// lost its subscription mid-turn during high-token sequences,
        /// freezing the displayed time while tokens kept climbing.
        private func elapsed(now: Date) -> TimeInterval {
            guard let start = session.currentTurnStartedAt else { return 0 }
            return now.timeIntervalSince(start)
        }

        /// Headline word for the status line. When claude is genuinely
        /// thinking we rotate through the creative verbs (Spelunking,
        /// Warping…). When something concrete is happening — a tool call,
        /// streaming text — show THAT instead, so we don't say
        /// "Ruminating… running Bash" with the verb and the phase
        /// contradicting each other.
        private func verb(elapsed: TimeInterval) -> String {
            let phase = session.currentPhase.lowercased()
            if phase.isEmpty || phase == "thinking" {
                let idx = Int(elapsed / 25) % Self.verbs.count
                return Self.verbs[idx]
            }
            return capitalizedPhase(session.currentPhase)
        }

        /// Capitalize only the leading word; tool names like "Bash" or
        /// file extensions inside the phase should keep their casing.
        private func capitalizedPhase(_ s: String) -> String {
            guard let first = s.first else { return s }
            return String(first).uppercased() + s.dropFirst()
        }

        private func elapsedLabel(_ elapsed: TimeInterval) -> String {
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
                // 1-second cadence TimelineView for the status text —
                // SwiftUI clock-driven, can't be starved by state churn.
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(statusLine(now: context.date))
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        }

        private func statusLine(now: Date) -> String {
            let e = elapsed(now: now)
            var parts: [String] = []
            parts.append("\(verb(elapsed: e))…")
            if e >= 1 {
                var meta: [String] = [elapsedLabel(e)]
                if let t = tokenLabel { meta.append(t) }
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
