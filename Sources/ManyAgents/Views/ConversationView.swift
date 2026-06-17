import SwiftUI
import AppKit

/// The main right-pane view — header + scrolling conversation + composer.
struct ConversationView: View {
    @ObservedObject var session: AgentSession
    @EnvironmentObject var manager: AgentManager
    @State private var showingRename = false
    @State private var renameDraft = ""
    // In-conversation find (⌘F).
    @State private var findVisible = false
    @State private var findQuery = ""
    /// The query actually EXECUTED (on Return / search button), as opposed to
    /// what's being typed. Highlighting + matching key off this, never the
    /// live `findQuery` — typing `#` and highlighting every `#` across a long
    /// conversation on the main thread is what froze the app.
    @State private var activeSearch = ""
    @FocusState private var findFocused: Bool
    /// Minimum query length before a search runs — blocks 1–2 char common
    /// tokens (`#`, `(`) from matching everywhere.
    private static let minSearchLength = 3
    /// Cap on matching messages, so even a broad 3-char query can't run away.
    private static let maxMatches = 500
    /// Ids of messages whose text matches the query, in conversation order.
    @State private var matchIds: [UUID] = []
    /// Index into `matchIds` for the match currently framed + scrolled to.
    @State private var currentMatch = 0
    /// Bumped to ask the ScrollViewReader to scroll to the current match.
    @State private var findScrollTick = 0
    /// Bumped to jump back to the live turn when the sticky turn-bar is tapped.
    @State private var stickyScrollTick = 0
    /// Scroll-tracking metrics. Driven by GeometryReader-derived
    /// preferences on each scroll/layout pass. We compute "near the
    /// bottom" as (content - scrollY - viewport < tolerance) — a real
    /// pixel-distance check that survives LazyVStack rebuilds.
    /// Earlier we used a 1-pt sentinel + onAppear, which kept flipping
    /// off when the layout flashed and broke chat-style auto-scroll.
    @State private var contentHeight: CGFloat = 0
    @State private var viewportHeight: CGFloat = 0
    @State private var scrollY: CGFloat = 0
    /// Pixels from the bottom under which we still auto-scroll. ~300px
    /// is roughly "the last screen-ish worth of content is visible".
    private static let nearBottomTolerance: CGFloat = 300

    /// Whether the user is parked at (near) the bottom. STORED, and
    /// recomputed only when the user actually scrolls (ScrollYKey / viewport
    /// changes) — NOT when content grows. That distinction is the whole fix:
    /// when content is appended below a top-anchored scroll view the scroll
    /// offset doesn't move, so a freshly-computed distance would read as
    /// "scrolled away by the size of the new content" and auto-follow would
    /// break for anything bigger than the tolerance. Pinning the flag to the
    /// user's last real scroll position means we follow the bottom while
    /// they're there and hold still while they read up. Defaults true so the
    /// first content lands at the bottom.
    @State private var atBottom = true
    /// False until the initial mount/tab-switch bottom-landing finishes. The
    /// first layout pass reports a TOP scroll offset, which would otherwise
    /// flip `atBottom` false and make the kick bail — so on a switch to a
    /// running tab we'd never reach the bottom and the thinking indicator
    /// would sit off-screen. While false we stay pinned to the bottom.
    @State private var didInitialScroll = false

    /// Recompute `atBottom` from the current scroll metrics. Call ONLY from
    /// scroll/viewport preference changes, never from content-height changes.
    private func recomputeAtBottom() {
        // Don't let the initial top-offset layout pass be mistaken for the
        // user scrolling away — stay pinned until the first landing is done.
        guard didInitialScroll else { atBottom = true; return }
        guard contentHeight > 0, viewportHeight > 0 else { atBottom = true; return }
        atBottom = (contentHeight - scrollY - viewportHeight) <= Self.nearBottomTolerance
    }

    // MARK: - Find (⌘F)

    private var findBar: some View {
        HStack(spacing: 8) {
            Button { runSearch() } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Search (⏎)")
            TextField("Find — 3+ chars, press ⏎", text: $findQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .focused($findFocused)
                .onSubmit { runSearch() }
                .frame(maxWidth: .infinity)
            Text(matchLabel)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(!activeSearch.isEmpty && matchIds.isEmpty ? .red : .secondary)
                .frame(minWidth: 46, alignment: .trailing)
            Divider().frame(height: 14)
            Button { advanceMatch(forward: false) } label: {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(.plain).disabled(matchIds.isEmpty)
            .help("Previous match (⇧⏎)")
            Button { advanceMatch(forward: true) } label: {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(.plain).disabled(matchIds.isEmpty)
            .help("Next match (⏎)")
            Button { closeFind() } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .help("Close (Esc)")
        }
        .font(.system(size: 11, weight: .semibold))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(width: 360)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.primary.opacity(0.15), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.30), radius: 12, y: 4)
        .padding(.top, 12)
        .padding(.trailing, 16)
        .zIndex(1)
    }

    private var trimmedQuery: String {
        findQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var matchLabel: String {
        if trimmedQuery.isEmpty { return "" }
        if trimmedQuery.count < Self.minSearchLength { return "3+" }
        // Entered enough but not yet run (or query edited since the last run).
        if activeSearch != trimmedQuery { return "⏎" }
        if matchIds.isEmpty { return "0/0" }
        return "\(currentMatch + 1)/\(matchIds.count)"
    }

    private func openFind() {
        findVisible = true
        // Don't search on open — wait for the user to type ≥3 chars and hit ⏎.
        DispatchQueue.main.async { findFocused = true }
    }

    private func closeFind() {
        findVisible = false
        findFocused = false
        findQuery = ""
        activeSearch = ""
        matchIds = []
        currentMatch = 0
    }

    /// Run the search — only invoked on Return or the search button, never
    /// per-keystroke. Requires ≥ `minSearchLength` chars. If the query is
    /// unchanged from the active search, just advance to the next match.
    private func runSearch() {
        let q = trimmedQuery
        guard q.count >= Self.minSearchLength else {
            activeSearch = ""; matchIds = []; currentMatch = 0
            return
        }
        if q == activeSearch {
            advanceMatch(forward: true)
        } else {
            activeSearch = q
            recomputeMatches()
        }
    }

    private func recomputeMatches() {
        let q = activeSearch
        guard q.count >= Self.minSearchLength else { matchIds = []; currentMatch = 0; return }
        var ids: [UUID] = []
        for m in session.messages where m.flatText.range(of: q, options: .caseInsensitive) != nil {
            ids.append(m.id)
            if ids.count >= Self.maxMatches { break }   // safety cap
        }
        matchIds = ids
        if ids.isEmpty {
            currentMatch = 0
        } else {
            currentMatch = min(currentMatch, ids.count - 1)
            findScrollTick += 1
        }
    }

    private func advanceMatch(forward: Bool) {
        guard !matchIds.isEmpty else { return }
        currentMatch = (currentMatch + (forward ? 1 : -1) + matchIds.count) % matchIds.count
        findScrollTick += 1
    }

    /// Only the EXECUTED search gets highlighted — never the live query — so
    /// editing the field doesn't re-highlight the whole conversation.
    private var highlightQuery: String { findVisible ? activeSearch : "" }

    // MARK: - Sticky turn bar

    /// Pinned summary shown while a turn runs and the user has scrolled up:
    /// "↑ <your prompt>     <what it's doing> · <elapsed>". Tap to jump back.
    private var turnStickyBar: some View {
        Button {
            stickyScrollTick += 1
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color.brandOrange)
                Text(stickyPromptText.isEmpty ? "Working…" : stickyPromptText)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 12)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(stickyStatusText(now: context.date))
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .frame(maxWidth: 760)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(nsColor: .windowBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.brandOrange.opacity(0.30), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.25), radius: 10, y: 3)
        }
        .buttonStyle(.plain)
        .padding(.top, 10)
        .padding(.horizontal, 18)
        .help("Jump to the live turn")
    }

    private var stickyPromptText: String {
        if let t = session.lastSentPrompt?.text, !t.isEmpty { return t }
        return session.messages.last(where: { $0.role == .user })?.flatText ?? ""
    }

    private func stickyStatusText(now: Date) -> String {
        let phase = session.currentPhase.isEmpty ? "working" : session.currentPhase
        guard let start = session.currentTurnStartedAt else { return "\(phase)…" }
        let s = max(0, Int(now.timeIntervalSince(start)))
        let elapsed = s < 60 ? "\(s)s" : "\(s / 60)m \(s % 60)s"
        return "\(phase)… · \(elapsed)"
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            conversationScroll
                .overlay(alignment: .top) {
                    // Sticky turn bar — only while running AND scrolled up
                    // (when near the bottom the live indicator is visible, so
                    // it would just duplicate). Keeps "what did I ask / what's
                    // it doing" pinned when you've scrolled away to read.
                    if session.status == .running && !atBottom {
                        turnStickyBar
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if findVisible { findBar }
                }
                .onReceive(NotificationCenter.default.publisher(for: .maFind)) { _ in
                    if findVisible { findFocused = true } else { openFind() }
                }
                // Editing the field does NOT search (that per-keystroke search
                // is what froze on "#"). Just clear the previous result so
                // stale highlights/counts don't linger; the user re-runs with
                // ⏎ or the search button.
                .onChange(of: findQuery) { _, _ in
                    if !activeSearch.isEmpty {
                        activeSearch = ""; matchIds = []; currentMatch = 0
                    }
                }
                // Re-run the ACTIVE search when new messages arrive (keeps the
                // count fresh during streaming) — no-ops when nothing's active.
                .onChange(of: session.messages.count) { _, _ in
                    if findVisible && !activeSearch.isEmpty { recomputeMatches() }
                }
            // Compaction banner — shown while AgentSession is running
            // its two-phase compact (summarise then reseed). Blocks
            // submission via the disabled composer state in a real
            // implementation, but at minimum tells the user "this tab
            // is intentionally between contexts, not stuck."
            if session.isCompacting {
                HStack {
                    Spacer(minLength: 0)
                    compactingBanner
                        .frame(maxWidth: 760)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 6)
            }
            // Auto-resume notice — shown when the last turn errored
            // while the network was down. The manager re-fires the
            // prompt the instant NWPathMonitor reports the path is
            // satisfied again. Reads as "your work isn't lost".
            if session.awaitingNetworkResume {
                HStack {
                    Spacer(minLength: 0)
                    autoResumeBanner
                        .frame(maxWidth: 760)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 6)
            }
            // Permission prompt — claude wants to perform a sensitive
            // action (write to a sensitive path, edit settings, etc.)
            // and is blocked waiting on the user's Allow / Deny. Sits
            // above AskUserQuestion so security decisions stay above
            // editorial ones.
            if session.pendingPermission != nil {
                HStack {
                    Spacer(minLength: 0)
                    PermissionPromptPicker(session: session)
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
            if session.lastTurnContextTokens > 0 {
                contextGauge
            }
            if let sid = session.claudeSessionId {
                Text(String(sid.prefix(8)))
                    .font(AppFont.mono(10))
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
            }
            kebabMenu
        }
        .alert("Rename tab", isPresented: $showingRename) {
            TextField("Title", text: $renameDraft)
            Button("Save") {
                let trimmed = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                session.aiTitle = trimmed
            }
            .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Enter a short label for this agent. Persists across launches.")
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

    /// Banner above the composer during the two-phase compact.
    /// Wording explains what's happening so the empty transcript
    /// reads as intentional, not a crash.
    private var compactingBanner: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
                .frame(width: 16, height: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text("Compacting conversation…")
                    .font(.system(size: 12, weight: .semibold))
                Text("Summarising what we know, then spawning a fresh claude session seeded with the brief.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.brandOrange.opacity(0.07))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.brandOrange.opacity(0.30), lineWidth: 1)
        )
    }

    /// Slim banner shown above the composer when this session's last
    /// turn errored out while the network was down. The wording is
    /// reassuring on purpose — there's nothing the user has to do; the
    /// retry fires automatically the moment connectivity comes back.
    private var autoResumeBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.brandOrange)
            VStack(alignment: .leading, spacing: 1) {
                Text("Network's down — will auto-retry when it's back.")
                    .font(.system(size: 12, weight: .semibold))
                Text("Your prompt is saved. Nothing to do.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Cancel retry") {
                session.awaitingNetworkResume = false
            }
            .buttonStyle(.borderless)
            .font(.system(size: 10.5))
            .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.brandOrange.opacity(0.07))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.brandOrange.opacity(0.30), lineWidth: 1)
        )
    }

    /// Header indicator showing this session's chain wiring at a glance
    /// — either incoming (set when a chain just fed this agent) or
    /// outgoing (a target is configured). Click opens the chain
    /// settings popover. Hidden if neither side is wired.
    /// Kebab menu — overflow surface for everything that isn't a
    /// glance-able status chip. Houses session actions (compact, new,
    /// rename, reveal), pipeline / coordination (formerly its own
    /// link gear), and a jump to the keyboard-shortcuts sheet.
    private var kebabMenu: some View {
        Menu {
            Button {
                compactConversation()
            } label: {
                Label(
                    session.isCompacting ? "Compacting…" : "Compact conversation",
                    systemImage: "rectangle.compress.vertical"
                )
            }
            .disabled(session.isCompacting || session.status == .running)
            .help("Generate a summary of everything important so far, then spawn a fresh claude session seeded with that summary. The model's working memory is truly reset — context window drops back to near-zero.")

            Button {
                manager.spawn(cwd: session.cwd)
            } label: {
                Label("New session in this project", systemImage: "plus.bubble")
            }

            Button {
                renameDraft = session.aiTitle ?? session.displayName
                showingRename = true
            } label: {
                Label("Rename tab…", systemImage: "pencil")
            }

            Button {
                NSWorkspace.shared.activateFileViewerSelecting(
                    [URL(fileURLWithPath: session.cwd)]
                )
            } label: {
                Label("Reveal project in Finder", systemImage: "folder")
            }

            Divider()

            Button {
                NotificationCenter.default.post(name: .maShowShortcuts, object: nil)
            } label: {
                Label("Keyboard shortcuts…", systemImage: "command")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Session menu")
    }

    /// Real conversation compaction. Hands off to AgentSession.compact()
    /// which orchestrates the two phases (summarise → reset → reseed).
    /// The kebab + the in-progress banner both block re-entry while
    /// isCompacting is true.
    private func compactConversation() {
        session.compact()
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

    /// Tool-use ids of every Task/Agent (sub-agent) call in the conversation.
    /// A tool RESULT whose id is in here is a sub-agent report and renders as
    /// markdown; everything else (Bash/Grep/Read/…) stays monospace — so shell
    /// output with `===` banners isn't mangled into giant setext headings.
    private var subagentToolUseIds: Set<String> {
        var ids: Set<String> = []
        for msg in session.messages {
            for block in msg.blocks {
                if case .toolUse(_, let toolUseId, let name, let input, _) = block,
                   MessageView.isSubagentTool(name: name, input: input) {
                    ids.insert(toolUseId)
                }
            }
        }
        return ids
    }

    /// Outcome of each file-edit tool call (Edit/Write/…), keyed by its
    /// tool_use id: `true` = errored, `false` = succeeded. tool_use and its
    /// result live in separate messages, so we correlate them here in one
    /// pass. MessageView uses this to fold a *successful* edit's verbose
    /// "…updated successfully" result into a ✓ on the tool card, while real
    /// errors ("File has not been read yet") still render as their own row.
    private var fileEditOutcomes: [String: Bool] {
        var editIds: Set<String> = []
        var errorById: [String: Bool] = [:]
        for msg in session.messages {
            for block in msg.blocks {
                switch block {
                case .toolUse(_, let id, let name, _, _):
                    if MessageView.isFileEditTool(name) { editIds.insert(id) }
                case .toolResult(_, let id, _, let isError, _):
                    errorById[id] = isError
                default:
                    break
                }
            }
        }
        var outcomes: [String: Bool] = [:]
        for id in editIds {
            if let isError = errorById[id] { outcomes[id] = isError }
        }
        return outcomes
    }

    // Memoized derivations. Recomputed only when the message STRUCTURE changes
    // (a message or block added) — never on streaming text deltas — so long
    // threads stop re-scanning the whole conversation O(n) on every frame.
    @State private var cachedTop: [Message] = []
    @State private var cachedChildren: [String: [Message]] = [:]
    @State private var cachedSubagentIds: Set<String> = []
    @State private var cachedEditOutcomes: [String: Bool] = [:]

    /// Cheap O(1) signature: message count + the last message's block count.
    /// Bumps when a message or a block is appended (the only events that change
    /// the derivations), but NOT on per-token text growth.
    private var messageStructureSig: String {
        "\(session.messages.count)-\(session.messages.last?.blocks.count ?? 0)"
    }

    private func refreshDerived() {
        let g = grouped
        cachedTop = g.top
        cachedChildren = g.children
        cachedSubagentIds = subagentToolUseIds
        cachedEditOutcomes = fileEditOutcomes
    }

    private var conversationScroll: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 28) {
                    if session.messages.isEmpty {
                        emptyState
                    }
                    // Memoized — see refreshDerived(); never recomputed inline.
                    let answered = session.answeredQuestions
                    ForEach(cachedTop) { msg in
                        MessageView(message: msg,
                                    subagentChildren: cachedChildren,
                                    subagentToolUseIds: cachedSubagentIds,
                                    fileEditOutcomes: cachedEditOutcomes,
                                    answeredQuestions: answered,
                                    sessionCwd: session.cwd,
                                    sessionId: session.id,
                                    highlight: highlightQuery,
                                    isCurrentMatch: findVisible
                                        && currentMatch < matchIds.count
                                        && matchIds[currentMatch] == msg.id)
                            .id(msg.id)
                    }
                    if session.status == .running {
                        ThinkingIndicator(session: session)
                            .id("thinking")
                    }
                    // Bottom anchor — a trailing spacer that doubles as the
                    // breathing room above the composer. Auto-follow does
                    // scrollTo("bottom", anchor: .bottom), which aligns THIS
                    // view's bottom to the viewport bottom; making it tall
                    // means the last line lands a comfortable gap above the
                    // composer instead of butting against it. It's the very
                    // last element (no padding below it), so the auto-scroll
                    // position and the manual scroll-to-end position match.
                    Color.clear.frame(height: 32).id("bottom")
                }
                .padding(.horizontal, 24)
                .padding(.top, 20)
                .frame(maxWidth: 1180, alignment: .leading)
                .frame(maxWidth: .infinity)
                // Content size + position tracker. Lives in a background
                // GeometryReader so it never affects layout. Reports
                // (a) the LazyVStack's total height (content) and
                // (b) the negative top-offset relative to the "scroll"
                // coordinate space, which is the scroll Y. Together
                // with the outer viewport height we can compute the
                // exact distance from the trailing edge.
                .background(
                    GeometryReader { contentProxy in
                        Color.clear
                            .preference(
                                key: ContentHeightKey.self,
                                value: contentProxy.size.height
                            )
                            .preference(
                                key: ScrollYKey.self,
                                value: -contentProxy.frame(in: .named("scroll")).minY
                            )
                    }
                )
                // Reliable USER-scroll detection straight from the underlying
                // NSScrollView (the GeometryReader signals above don't fire
                // promptly mid-stream, so streaming-follow beat them). Drives
                // `atBottom` authoritatively.
                .background(ScrollBottomWatcher(atBottom: $atBottom))
            }
            .coordinateSpace(name: "scroll")
            // Jump-to-bottom button — appears bottom-right whenever the user
            // has scrolled away from the trailing edge. Tapping it scrolls to
            // the latest and re-engages auto-follow.
            .overlay(alignment: .bottomTrailing) {
                if !atBottom {
                    Button {
                        atBottom = true
                        withAnimation(.easeOut(duration: 0.22)) {
                            proxy.scrollTo("bottom", anchor: .bottom)
                        }
                    } label: {
                        Image(systemName: "arrow.down")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 34, height: 34)
                            .background(Circle().fill(Color.brandOrange))
                            .overlay(Circle().stroke(Color.white.opacity(0.15), lineWidth: 0.5))
                            .shadow(color: .black.opacity(0.35), radius: 6, y: 2)
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 20)
                    .padding(.bottom, 18)
                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
                    .help("Scroll to latest")
                }
            }
            .animation(.easeOut(duration: 0.15), value: atBottom)
            // Viewport height — measured on the ScrollView itself.
            .background(
                GeometryReader { viewportProxy in
                    Color.clear
                        .preference(
                            key: ViewportHeightKey.self,
                            value: viewportProxy.size.height
                        )
                }
            )
            // Content height changes do NOT update `atBottom` — only the
            // follow trigger reads it. Scroll / viewport changes do.
            // `atBottom` is driven authoritatively by ScrollBottomWatcher
            // (real NSScrollView events); these just keep the height metrics
            // around and no longer touch the follow gate.
            .onPreferenceChange(ContentHeightKey.self) { contentHeight = $0 }
            .onPreferenceChange(ScrollYKey.self) { scrollY = $0 }
            .onPreferenceChange(ViewportHeightKey.self) { viewportHeight = $0 }
            // NOTE: we deliberately do NOT use .defaultScrollAnchor(.bottom).
            // It re-pins to the bottom on EVERY content-size change,
            // unconditionally — so a growing stream (or a new message) yanked
            // the viewport down even while the user was scrolled up reading
            // earlier text. The default top anchor instead holds the user's
            // position when content is added below; we follow the bottom
            // ourselves, but only when they're already there (see below).
            // Land at the bottom on first mount (also forces the LazyVStack to
            // materialize its trailing rows — the blank-on-tab-switch fix).
            // Two passes: trailing rows often aren't measured on the first tick.
            .onAppear {
                DispatchQueue.main.async { proxy.scrollTo("bottom", anchor: .bottom) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
            // Auto-follow. Earlier attempts triggered off `contentHeight` (a
            // GeometryReader preference) which does NOT fire reliably while
            // text streams in — so the view never followed. Instead trigger
            // off the session's own signals, which DO change per chunk:
            //  • currentTurnOutputTokens — bumps on every streamed chunk
            //  • messages.count / blockCount — new messages and tool blocks
            //  • status — turn boundaries (thinking indicator in/out)
            // All gated on `atBottom` (maintained from real scroll events), so
            // we follow while the user is at the bottom and never yank them
            // when they've scrolled up. A new turn (status → running) snaps
            // `atBottom` true so sending a prompt always tracks its reply, and
            // a stuck flag can't permanently break following.
            .onChange(of: session.currentTurnOutputTokens) { _, _ in followBottom(proxy) }
            .onChange(of: session.messages.count) { _, _ in followBottom(proxy) }
            // Structural change (new message/block): refresh the memoized
            // derivations and follow. messageStructureSig is O(1), unlike the
            // old blockCount scan, and fires only on structure changes — not
            // per streamed token.
            .onChange(of: messageStructureSig, initial: true) { _, _ in
                refreshDerived()
                followBottom(proxy)
            }
            .onChange(of: session.status) { _, newStatus in
                if newStatus == .running { atBottom = true }
                followBottom(proxy)
            }
            // Find: scroll the current match to the middle of the viewport.
            .onChange(of: findScrollTick) { _, _ in
                guard currentMatch < matchIds.count else { return }
                withAnimation(.easeInOut(duration: 0.2)) {
                    proxy.scrollTo(matchIds[currentMatch], anchor: .center)
                }
            }
            // Sticky turn bar tapped → jump back to the live turn.
            .onChange(of: stickyScrollTick) { _, _ in
                withAnimation(.easeInOut(duration: 0.25)) {
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
                // `atBottom` is forced true until `didInitialScroll`, so this
                // keeps landing us at the bottom through the mount window. We
                // target the "bottom" sentinel — the very last element, BELOW
                // the thinking indicator — so switching to a running tab shows
                // the "thinking…" dots instead of clipping them off-screen.
                guard atBottom else { break }
                proxy.scrollTo("bottom", anchor: .bottom)
            }
            // Initial landing done — now real scroll events drive `atBottom`.
            didInitialScroll = true
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

    /// Bottom-follow used while content arrives. No-ops unless the user is at
    /// the trailing edge. Targets the stable "bottom" sentinel (always the
    /// very last element) and is non-animated + async so rapid streaming
    /// updates land cleanly without queuing overlapping animations.
    private func followBottom(_ proxy: ScrollViewProxy) {
        guard atBottom else { return }
        DispatchQueue.main.async {
            proxy.scrollTo("bottom", anchor: .bottom)
        }
    }

    /// Total content blocks across all messages — bumps when a tool-use or
    /// tool-result block is appended mid-turn (which doesn't change
    /// messages.count), so the follow tracks those too.
    private var blockCount: Int {
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
            let n = session.currentTurnOutputTokens + session.carriedTurnTokens
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
            // Per-turn only: verb + this turn's elapsed + this turn's tokens.
            // The timer is preserved across a force-send (see AgentSession),
            // so interrupting a thinking turn doesn't snap it back to 0.
            let e = elapsed(now: now)
            var parts: [String] = ["\(verb(elapsed: e))…"]
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

// MARK: - Scroll-tracking preference keys

private struct ContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct ScrollYKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct ViewportHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// Bridges to the underlying AppKit `NSScrollView` to detect USER scrolls
/// reliably — the SwiftUI GeometryReader signals don't fire promptly mid-
/// stream, so streaming auto-follow kept beating them and yanking the user
/// back. This sets `atBottom` false the instant the user grabs the scroller,
/// and recomputes from the real scroll position as they move (so reaching the
/// bottom re-engages follow). Programmatic `scrollTo` does NOT post live-scroll
/// notifications, so our own follow never false-triggers this.
private struct ScrollBottomWatcher: NSViewRepresentable {
    @Binding var atBottom: Bool
    var tolerance: CGFloat = 100

    func makeNSView(context: Context) -> NSView {
        let v = NSView(frame: .zero)
        context.coordinator.host = v
        DispatchQueue.main.async { context.coordinator.attach() }
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.parent = self
        DispatchQueue.main.async { context.coordinator.attach() }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator {
        var parent: ScrollBottomWatcher
        weak var host: NSView?
        weak var scrollView: NSScrollView?
        init(_ p: ScrollBottomWatcher) { parent = p }

        func attach() {
            guard scrollView == nil, let sv = host?.enclosingScrollView else { return }
            scrollView = sv
            let nc = NotificationCenter.default
            nc.addObserver(self, selector: #selector(willStart),
                           name: NSScrollView.willStartLiveScrollNotification, object: sv)
            nc.addObserver(self, selector: #selector(didScroll),
                           name: NSScrollView.didLiveScrollNotification, object: sv)
            nc.addObserver(self, selector: #selector(didScroll),
                           name: NSScrollView.didEndLiveScrollNotification, object: sv)
        }

        /// User grabbed the scroller — release follow immediately.
        @objc func willStart() {
            if parent.atBottom { parent.atBottom = false }
        }

        /// Recompute from the real scroll position so reaching the bottom
        /// re-engages follow and scrolling away keeps it off.
        @objc func didScroll() {
            guard let sv = scrollView, let doc = sv.documentView else { return }
            let off = sv.contentView.bounds.origin.y
            let viewportH = sv.contentView.bounds.height
            let distanceFromBottom = doc.bounds.height - (off + viewportH)
            let isBottom = distanceFromBottom <= parent.tolerance
            if parent.atBottom != isBottom { parent.atBottom = isBottom }
        }

        deinit { NotificationCenter.default.removeObserver(self) }
    }
}
