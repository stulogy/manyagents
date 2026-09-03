import SwiftUI

struct WorkspaceView: View {
    @EnvironmentObject var manager: AgentManager
    @EnvironmentObject var readiness: ClaudeReadiness
    @EnvironmentObject var stayAwake: StayAwake
    @AppStorage("sidebar.width") private var sidebarWidth: Double = 260
    @AppStorage("sidebar.collapsed") private var sidebarCollapsed: Bool = false
    @AppStorage("workspace.viewMode") private var viewModeRaw: String = WorkspaceMode.row.rawValue
    @State private var pendingCloseTarget: AgentSession?
    @State private var showShortcuts: Bool = false
    @State private var indicatorPulse: Bool = false
    @AppStorage("attention.open") private var attentionOpen: Bool = false
    @Environment(\.openSettings) private var openSettings

    /// Only present while we actually hold the assertion. A badge, not a
    /// control: a Button or SettingsLink in the toolbar gets macOS's own
    /// button chrome drawn behind it, so the capsule ended up sitting
    /// inside a second oval. A plain view plus the openSettings action
    /// keeps the click without the container.
    @ViewBuilder
    private var stayAwakeIndicator: some View {
        if stayAwake.isHoldingAwake {
            HStack(spacing: 4) {
                Circle()
                    .fill(indicatorTint)
                    .frame(width: 5, height: 5)
                    .opacity(indicatorPulse ? 0.3 : 1)
                Text("Caffeinated")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(indicatorTint)
            }
            .padding(.horizontal, 8)
            // Fixed, deliberately small height: a toolbar item taller than
            // the standard control metric makes the whole unified title bar
            // grow the moment this appears.
            .frame(height: 17)
            .background(
                Capsule()
                    .fill(indicatorTint.opacity(0.14))
                    .overlay(Capsule().strokeBorder(indicatorTint.opacity(0.35), lineWidth: 0.5))
            )
            .fixedSize()
            .contentShape(Capsule())
            .onTapGesture { openSettings() }
            .help(stayAwake.indicatorHelp)
            .onAppear {
                withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                    indicatorPulse = true
                }
            }
            .onDisappear { indicatorPulse = false }
        }
    }

    /// Red while it's costing battery, amber on power. The colour is the
    /// whole signal — an earlier version drew a battery glyph next to it,
    /// but it was a fixed `battery.25` symbol that never read the real
    /// charge, so it looked like a low-battery warning it couldn't back up.
    /// Opens the drawer, and carries the count so a question raised in a
    /// project you aren't looking at is visible without hunting for it.
    private var attentionButton: some View {
        Button {
            attentionOpen.toggle()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "bell")
                    .font(.system(size: 12, weight: .medium))
                if manager.attentionDecisionCount > 0 {
                    Text("\(manager.attentionDecisionCount)")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.brandOrange))
                }
            }
        }
        .help(manager.attentionDecisionCount == 0
              ? "Nothing waiting on you (⌘⇧A)"
              : "\(manager.attentionDecisionCount) waiting on you (⌘⇧A)")
        .keyboardShortcut("a", modifiers: [.command, .shift])
    }

    private var indicatorTint: Color {
        stayAwake.onBattery ? Color(red: 0.90, green: 0.25, blue: 0.25) : Color.brandOrange
    }

    private var viewMode: Binding<WorkspaceMode> {
        Binding(
            get: { WorkspaceMode(rawValue: viewModeRaw) ?? .row },
            set: { viewModeRaw = $0.rawValue }
        )
    }

    var body: some View {
        HStack(spacing: 0) {
            if !sidebarCollapsed {
                ProjectsSidebar(viewMode: viewMode, sidebarCollapsed: $sidebarCollapsed)
                    .frame(width: CGFloat(sidebarWidth))
                    .transition(.move(edge: .leading))
                Rectangle()
                    .fill(Color.primary.opacity(0.08))
                    .frame(width: 1)
            }
            mainPane
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if attentionOpen {
                Rectangle()
                    .fill(Color.primary.opacity(0.08))
                    .frame(width: 1)
                AttentionDrawer(open: $attentionOpen)
                    .frame(width: 300)
                    .transition(.move(edge: .trailing))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: attentionOpen)
        .toolbar {
            // Title bar, not the sidebar: the sidebar collapses (⌘⇧S) and
            // this must not vanish with it. Stopping a Mac from sleeping
            // should never be invisible — least of all on battery.
            //
            // macOS 26 gives every toolbar item its own glass container,
            // which drew a second capsule around the badge. Hide it where
            // the API exists; older systems never drew one.
            if #available(macOS 26.0, *) {
                ToolbarItem(placement: .automatic) {
                    stayAwakeIndicator
                }
                .sharedBackgroundVisibility(.hidden)
            } else {
                ToolbarItem(placement: .automatic) {
                    stayAwakeIndicator
                }
            }
            ToolbarItem(placement: .automatic) {
                attentionButton
            }
        }
        .animation(.easeInOut(duration: 0.2), value: sidebarCollapsed)
        .onReceive(NotificationCenter.default.publisher(for: .maToggleSidebar)) { _ in
            withAnimation(.easeInOut(duration: 0.2)) { sidebarCollapsed.toggle() }
        }
        .background(mainBackground)
        .sheet(isPresented: Binding(
            get: { manager.pendingRestore != nil },
            set: { presented in
                if !presented, manager.pendingRestore != nil {
                    manager.dismissPendingSnapshot()
                }
            }
        )) {
            if let snap = manager.pendingRestore {
                RestoreSessionsSheet(
                    snapshot: snap,
                    onReopen: { manager.acceptPendingSnapshot() },
                    onDiscard: { manager.discardPendingSnapshot() },
                    onDismiss: { manager.dismissPendingSnapshot() }
                )
            }
        }
        // Close-tab confirmation. ⌘W stages the active session into
        // pendingCloseTarget which presents this alert; clicking Close
        // actually drops it.
        .alert("Close this tab?",
               isPresented: Binding(
                get: { pendingCloseTarget != nil },
                set: { if !$0 { pendingCloseTarget = nil } }
               ),
               presenting: pendingCloseTarget) { target in
            Button("Close", role: .destructive) {
                manager.close(target)
                pendingCloseTarget = nil
            }
            Button("Cancel", role: .cancel) {
                pendingCloseTarget = nil
            }
        } message: { target in
            let label = target.aiTitle?.isEmpty == false ? target.aiTitle! : target.displayName
            Text("“\(label)” will be removed from this workspace. You can reopen it later via Session → Resume Previous Sessions… as long as the underlying claude transcript still exists.")
        }
        .sheet(isPresented: $showShortcuts) {
            KeyboardShortcutsSheet(onClose: { showShortcuts = false })
        }
        // Menu-bar commands publish notifications; the active window
        // routes them through the manager. Scoped per WorkspaceView so
        // multi-window setups stay coherent.
        .onReceive(NotificationCenter.default.publisher(for: .maNewTab)) { _ in
            manager.spawnInActiveProject()
        }
        .onReceive(NotificationCenter.default.publisher(for: .maCloseTab)) { _ in
            if let s = manager.activeSession { pendingCloseTarget = s }
        }
        .onReceive(NotificationCenter.default.publisher(for: .maCycleProject)) { _ in
            manager.cycleNextProject()
        }
        .onReceive(NotificationCenter.default.publisher(for: .maCycleTab)) { _ in
            manager.cycleNextTabInActiveProject()
        }
        .onReceive(NotificationCenter.default.publisher(for: .maToggleViewMode)) { _ in
            viewMode.wrappedValue = viewMode.wrappedValue == .row ? .card : .row
        }
        .onReceive(NotificationCenter.default.publisher(for: .maShowShortcuts)) { _ in
            showShortcuts = true
        }
    }

    private var mainBackground: some View {
        LinearGradient(
            colors: [Color(nsColor: .underPageBackgroundColor),
                     Color(nsColor: .windowBackgroundColor)],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
    }

    @ViewBuilder
    private var mainPane: some View {
        // Onboarding always wins when claude isn't installed or logged in —
        // every other path would silently fail without auth.
        if readiness.state == .missingBinary || readiness.state == .notAuthenticated {
            OnboardingView(readiness: readiness)
        } else if manager.sessions.isEmpty {
            emptyState
        } else if viewMode.wrappedValue == .card {
            AgentCardsGrid(onPick: { session in
                manager.activeSessionId = session.id
                viewMode.wrappedValue = .row
            })
        } else if let project = manager.activeProject {
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    if sidebarCollapsed {
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                sidebarCollapsed = false
                            }
                        } label: {
                            Image(systemName: "sidebar.left")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(.secondary)
                                .padding(.leading, 14)
                                .padding(.trailing, 6)
                        }
                        .buttonStyle(.plain)
                        .help("Show sidebar")
                    }
                    // The strip stays visible over the preview now. It used
                    // to be replaced by a Spacer, on the reasoning that one
                    // shared browser wasn't per-tab — but the preview is per
                    // checkout, and the toggle lives in the strip, so hiding
                    // it hid the way back.
                    tabStrip(for: project)
                }
                // Contained "panel" — same shape as ClaudeDeck's right pane,
                // so the conversation reads as a distinct surface inside the
                // window background instead of bleeding edge-to-edge.
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color(nsColor: .windowBackgroundColor).opacity(0.75))
                        .shadow(color: Color.black.opacity(0.35), radius: 14, x: 0, y: 4)
                    if manager.previewActive, let scope = manager.activePreviewScope {
                        // Keyed by scope so switching projects rebuilds
                        // against that checkout's browser instead of
                        // rendering the previous one's page.
                        PreviewView(scope: scope)
                            .id(scope)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    } else if let session = manager.activeSession {
                        // CRITICAL: tie the ConversationView's identity to
                        // the session id so SwiftUI doesn't leak composer
                        // @State across tab switches.
                        ConversationView(session: session)
                            .id(session.id)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .padding(.horizontal, 14)
                .padding(.bottom, 14)
                .padding(.top, 4)
            }
        } else {
            selectProjectState
        }
    }

    /// Tabs scroll; the two controls don't. They used to live inside the
    /// scroll view, so a project with a dozen tabs pushed "new tab" and the
    /// browser toggle off the right-hand edge — the two things you always
    /// want reachable were the first to disappear.
    private func tabStrip(for project: ProjectEntry) -> some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(project.sessions) { s in
                        // Also stays lit under the preview. The tab is still
                        // the selected one — the browser is showing over its
                        // conversation, not instead of it — and the toggle
                        // beside the strip is already lit orange to say so.
                        AgentTab(session: s,
                                 isActive: manager.activeSessionId == s.id,
                                 onSelect: {
                                     manager.activeSessionId = s.id
                                     manager.previewActive = false
                                 },
                                 onClose: { manager.close(s) })
                    }
                }
                .padding(.leading, 14)
                .padding(.trailing, 4)
            }
            HStack(spacing: 4) {
                newTabButton(for: project)
                previewToggle
            }
            .padding(.trailing, 14)
        }
        .padding(.vertical, 8)
    }

    private func newTabButton(for project: ProjectEntry) -> some View {
        Button {
            manager.spawn(cwd: project.cwd)
        } label: {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(0.05))
                .frame(width: 28, height: 24)
                .overlay(
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.secondary)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("New tab in this project")
    }

    /// Browser toggle, at the end of the tab strip — the preview belongs to
    /// the checkout the active tab is in, so it sits with that project's
    /// tabs rather than being an app-wide mode. Shows the port when there's
    /// a page: orange glyph when one is waiting, solid orange when it's on
    /// screen, grey when this project has nothing to show.
    ///
    /// It briefly carried the port, to tell two worktrees apart. Wrong on
    /// two counts: the address bar sits directly under it showing the same
    /// URL, and `Text(":\(port)")` interpolates an Int through the locale
    /// formatter — port 3015 rendered as ":3,015". The URL belongs in the
    /// tooltip, which is where it is.
    @ViewBuilder
    private var previewToggle: some View {
        let url = manager.activePreviewURL
        let on = manager.previewActive
        Button {
            manager.previewActive.toggle()
        } label: {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(on ? Color.brandOrange : Color.primary.opacity(0.05))
                .frame(width: 28, height: 24)
                .overlay(
                    Image(systemName: "globe")
                        .font(.system(size: 11, weight: .semibold))
                        // White on the solid orange, matching the sidebar's
                        // switcher — black read as a different control.
                        .foregroundStyle(on ? Color.white
                                            : (url == nil ? .secondary : Color.brandOrange))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(url == nil && !on)
        .keyboardShortcut("p", modifiers: [.command, .shift])
        .help(url == nil ? "No preview for this project yet"
                         : (on ? "Back to the conversation" : "Show \(url!.absoluteString)"))
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "sparkles")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.tertiary)
            Text("No agents yet")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("Click ‘New session’ to point ManyAgents at a project folder.")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var selectProjectState: some View {
        VStack(spacing: 10) {
            Image(systemName: "sidebar.left")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.tertiary)
            Text("Select a project")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct AgentTab: View {
    @ObservedObject var session: AgentSession
    @EnvironmentObject var manager: AgentManager
    let isActive: Bool
    let onSelect: () -> Void
    let onClose: () -> Void
    @State private var hover = false
    @State private var isDropTarget = false
    @State private var showRename = false
    @State private var renameDraft = ""
    @State private var showBoard = false
    /// Staged worktree removal: the git checks run off the main thread, then
    /// this presents the verdict for confirmation — or the refusal.
    @State private var removalPrompt: WorktreeRemovalPrompt?

    private var label: String {
        if let t = session.aiTitle, !t.isEmpty { return t }
        switch session.status {
        case .idle:    return "Ready"
        case .running: return "Working…"
        case .waiting: return "Waiting on you"
        case .error:   return "Error"
        }
    }

    private var checkout: String { ProjectNaming.checkoutLabel(forCwd: session.cwd) }

    private var isWorktreeTab: Bool { GitWorktrees.kind(forCwd: session.cwd) == .worktree }

    private var dotColor: Color {
        switch session.status {
        case .idle:    return .secondary
        case .running: return Color.activeHighlight
        case .waiting: return .orange
        case .error:   return .red
        }
    }

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(dotColor)
                .frame(width: 7, height: 7)
            // Orchestrator hat — a brain icon you click to peek at what
            // it sees and is thinking. An eye-slash marks a tab the user
            // has hidden from the orchestrator.
            if session.isCoordinator {
                Button { showBoard = true } label: {
                    Image(systemName: "brain.head.profile")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.brandOrange)
                }
                .buttonStyle(.plain)
                .help("Orchestrator — click to see what it knows / is thinking")
                .popover(isPresented: $showBoard, arrowEdge: .bottom) {
                    OrchestratorIndicatorPopover(orchestrator: session)
                        .environmentObject(manager)
                }
            } else if session.hiddenFromOrchestrator && manager.orchestrator(for: session.cwd) != nil {
                Image(systemName: "eye.slash")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .help("Hidden from the orchestrator")
            }
            if session.isAutoNaming && (session.aiTitle?.isEmpty ?? true) {
                ProgressView()
                    .controlSize(.mini)
                    .frame(maxWidth: 220, alignment: .leading)
                    .help("Naming…")
            } else {
                Text(label)
                    .font(.system(size: 12, weight: isActive ? .semibold : .medium))
                    .lineLimit(1)
                    .frame(maxWidth: 220, alignment: .leading)
            }
            // Which checkout this tab is in. Worktrees stopped being sidebar
            // rows, so without this two tabs of one repo on two branches are
            // indistinguishable in the strip.
            if !checkout.isEmpty {
                HStack(spacing: 3) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 8, weight: .semibold))
                    Text(checkout)
                        .font(.system(size: 10, weight: .medium))
                        .lineLimit(1)
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Capsule().fill(Color.primary.opacity(0.08)))
                .help("Working in \(ProjectNaming.prettyCwd(session.cwd))")
            }
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 14, height: 14)
                    .background(
                        Circle().fill(hover ? Color.primary.opacity(0.12) : Color.clear)
                    )
                    .opacity(hover || isActive ? 1 : 0.4)
            }
            .buttonStyle(.plain)
            .help("Close agent")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isActive ? Color.activeHighlight.opacity(0.22) : Color.primary.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(isActive ? Color.activeHighlight.opacity(0.5) : Color.clear, lineWidth: 1)
        )
        .foregroundStyle(isActive ? Color.activeHighlight : .primary)
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(alignment: .leading) {
            // Vertical insertion indicator while a drag hovers this tab.
            if isDropTarget {
                Rectangle()
                    .fill(Color.brandOrange)
                    .frame(width: 2)
            }
        }
        .onTapGesture(perform: onSelect)
        .onHover { hover = $0 }
        .draggable(session.id.uuidString) {
            HStack(spacing: 6) {
                Circle().fill(dotColor).frame(width: 6, height: 6)
                Text(label)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color.activeHighlight.opacity(0.85)))
            .foregroundStyle(.white)
        }
        .dropDestination(for: String.self) { items, _ in
            guard let raw = items.first,
                  let movedId = UUID(uuidString: raw),
                  movedId != session.id else { return false }
            manager.reorderSession(movedId: movedId, before: session.id)
            return true
        } isTargeted: { targeted in
            isDropTarget = targeted
        }
        .contextMenu {
            Button("Rename Tab…") {
                renameDraft = session.aiTitle ?? ""
                showRename = true
            }
            if session.aiTitle?.isEmpty == false {
                Button("Reset to Auto-Name") {
                    session.aiTitle = nil
                    // Raise the spinner NOW — AutoNamer's debounced scan
                    // starts ~600ms later, and without this the label
                    // flashes the status placeholder in the gap.
                    session.isAutoNaming = true
                }
            }
            Divider()
            // Name the hat by its scope: a tab in a nested repo leads that
            // repo, it doesn't take the workspace board.
            let hatLabel = session.repoRoot == session.projectRoot
                ? "Make Orchestrator"
                : "Make Lead of \(ProjectNaming.name(forCwd: session.repoRoot))"
            Button(session.isCoordinator ? "Stop Orchestrating" : hatLabel) {
                // Just do it — the user picked this tab on purpose.
                manager.toggleOrchestrator(session)
            }
            if !session.isCoordinator {
                // Only meaningful once an orchestrator exists to hide from.
                Button(session.hiddenFromOrchestrator ? "Show to Orchestrator" : "Hide from Orchestrator") {
                    session.hiddenFromOrchestrator.toggle()
                }
                .disabled(manager.orchestrator(for: session.cwd) == nil)
            }
            Divider()
            // Which model this tab runs on. Worth surfacing even at .auto:
            // with Optimize Mode on, a dispatched tab is quietly downgraded,
            // and nothing else in the UI said so.
            Menu("Model: \(session.effectiveModelLabel)") {
                Button {
                    session.modelTier = .auto
                } label: {
                    Label("Automatic", systemImage: session.modelTier == .auto ? "checkmark" : "")
                }
                Button {
                    session.modelTier = .full
                } label: {
                    Label("Full model", systemImage: session.modelTier == .full ? "checkmark" : "")
                }
                Button {
                    session.modelTier = .cheap
                } label: {
                    Label("Cheaper model", systemImage: session.modelTier == .cheap ? "checkmark" : "")
                }
            }
            Divider()
            if isWorktreeTab {
                // Closing the tab leaves the worktree behind, which is how
                // one repo here reached 86 of them. Removal is gated: clean
                // tree, commits merged or pushed, or it refuses and says why.
                Button("Close Tab and Remove Worktree…") { stageWorktreeRemoval() }
            }
            Button("Close Tab", role: .destructive, action: onClose)
        }
        .alert(removalPrompt?.title ?? "",
               isPresented: Binding(get: { removalPrompt != nil },
                                    set: { if !$0 { removalPrompt = nil } }),
               presenting: removalPrompt) { prompt in
            if prompt.canRemove {
                Button("Remove", role: .destructive) { performRemoval(prompt) }
                Button("Cancel", role: .cancel) { removalPrompt = nil }
            } else {
                Button("OK", role: .cancel) { removalPrompt = nil }
            }
        } message: { prompt in
            Text(prompt.message)
        }
        .alert("Rename tab", isPresented: $showRename) {
            TextField("Title", text: $renameDraft)
            Button("Save") {
                let trimmed = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                session.aiTitle = trimmed
            }
            .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Enter a short label for this agent. It persists across launches.")
        }
    }

    /// Check the worktree off the main thread, then present the verdict.
    /// Refusals are shown rather than swallowed: "3 unpushed commits" is the
    /// useful answer, and it says what to do before trying again.
    private func stageWorktreeRemoval() {
        let cwd = session.cwd
        let name = ProjectNaming.name(forCwd: cwd)
        let siblings = manager.sessions.filter { $0.cwd == cwd }.count
        Task.detached {
            let verdict = GitWorktrees.safety(ofWorktree: cwd)
            await MainActor.run {
                if verdict.removable {
                    let others = siblings - 1
                    let note = others > 0
                        ? " \(others) other tab\(others == 1 ? "" : "s") in it will close too (recoverable via Resume)."
                        : ""
                    removalPrompt = WorktreeRemovalPrompt(
                        title: "Remove worktree “\(name)”?",
                        message: "The branch is safe — \(verdict.reason) — so the directory can go.\(note)",
                        canRemove: true, cwd: cwd)
                } else {
                    removalPrompt = WorktreeRemovalPrompt(
                        title: "Can’t remove “\(name)”",
                        message: "It has \(verdict.reason). Commit and push (or merge) that work first, and this becomes removable.",
                        canRemove: false, cwd: cwd)
                }
            }
        }
    }

    private func performRemoval(_ prompt: WorktreeRemovalPrompt) {
        removalPrompt = nil
        // Close the tabs BEFORE deleting the directory: a session left
        // pointing at a hole is the state the sidebar has to flag in orange.
        for s in manager.sessions where s.cwd == prompt.cwd { manager.close(s) }
        let cwd = prompt.cwd
        Task.detached {
            if case .failure(let err) = GitWorktrees.remove(worktree: cwd) {
                await MainActor.run {
                    removalPrompt = WorktreeRemovalPrompt(
                        title: "Couldn’t remove the worktree",
                        message: "git refused: \(err.message)",
                        canRemove: false, cwd: cwd)
                }
            }
        }
    }
}

/// The brain-icon popover: what the orchestrator SEES (its live board of the
/// other tabs) and what it's THINKING (its self-written notes). Read-only —
/// a window into the orchestrator's current understanding.
private struct OrchestratorIndicatorPopover: View {
    @ObservedObject var orchestrator: AgentSession
    @EnvironmentObject var manager: AgentManager

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 7) {
                Image(systemName: "brain.head.profile")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.brandOrange)
                Text("Orchestrator")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.primary)
            }

            VStack(alignment: .leading, spacing: 8) {
                sectionLabel("SEES")
                // Match the board the orchestrator actually sees: its whole
                // workspace, plus any tab it dispatched elsewhere. Matching
                // raw cwds showed the user a shorter list than the
                // orchestrator was working from.
                let others = manager.sessions.filter {
                    $0.id != orchestrator.id && !$0.hiddenFromOrchestrator
                        && ($0.projectRoot == orchestrator.projectRoot
                            || $0.reportToOrchestratorId == orchestrator.id)
                }
                if others.isEmpty {
                    Text("No other tabs in this project.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                } else {
                    ForEach(others) { s in
                        HStack(alignment: .top, spacing: 7) {
                            Circle().fill(dotColor(s.status))
                                .frame(width: 6, height: 6).padding(.top, 5)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(s.aiTitle ?? s.displayName)
                                        .font(.system(size: 12.5, weight: .semibold))
                                        .foregroundStyle(Color.primary)
                                    if orchestrator.mutedTabIds.contains(s.id) {
                                        Text("muted")
                                            .font(.system(size: 9, weight: .semibold))
                                            .foregroundStyle(.secondary)
                                            .padding(.horizontal, 5).padding(.vertical, 1)
                                            .background(Capsule().fill(Color.primary.opacity(0.1)))
                                    }
                                }
                                Text(s.status.boardLabel + (s.latestSnippet.isEmpty ? "" : " · \(s.latestSnippet)"))
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                    }
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                sectionLabel("THINKING")
                Text(orchestrator.orchestratorNotes.isEmpty
                     ? "No notes yet — the orchestrator records its plan here as it works."
                     : orchestrator.orchestratorNotes)
                    .font(.system(size: 12))
                    .foregroundStyle(orchestrator.orchestratorNotes.isEmpty ? .secondary : .primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(width: 330)
        // The popover is anchored inside the active tab, whose foreground
        // base is Color.activeHighlight (blue). Hierarchical styles
        // (.primary/.secondary) resolve RELATIVE to that base, so everything
        // came out blue. Re-base the whole subtree to the CONCRETE primary
        // label color so .primary→white text and .secondary→grey as intended.
        .foregroundStyle(Color.primary)
        .tint(Color.primary)
    }

    private func sectionLabel(_ t: String) -> some View {
        Text(t)
            .font(.system(size: 9.5, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(.secondary)
    }

    private func dotColor(_ s: AgentStatus) -> Color {
        switch s {
        case .idle:    return .secondary
        case .running: return Color.activeHighlight
        case .waiting: return .orange
        case .error:   return .red
        }
    }
}

/// One staged worktree removal — the confirmation, or the refusal.
private struct WorktreeRemovalPrompt: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    /// false when this is a refusal: the alert then only explains itself.
    let canRemove: Bool
    let cwd: String
}
