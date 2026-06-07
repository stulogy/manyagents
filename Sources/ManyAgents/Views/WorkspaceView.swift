import SwiftUI

struct WorkspaceView: View {
    @EnvironmentObject var manager: AgentManager
    @EnvironmentObject var readiness: ClaudeReadiness
    @AppStorage("sidebar.width") private var sidebarWidth: Double = 260
    @AppStorage("workspace.viewMode") private var viewModeRaw: String = WorkspaceMode.row.rawValue
    @State private var pendingCloseTarget: AgentSession?
    @State private var showShortcuts: Bool = false

    private var viewMode: Binding<WorkspaceMode> {
        Binding(
            get: { WorkspaceMode(rawValue: viewModeRaw) ?? .row },
            set: { viewModeRaw = $0.rawValue }
        )
    }

    var body: some View {
        HStack(spacing: 0) {
            ProjectsSidebar(viewMode: viewMode)
                .frame(width: CGFloat(sidebarWidth))
            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(width: 1)
            mainPane
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                tabStrip(for: project)
                // Contained "panel" — same shape as ClaudeDeck's right pane,
                // so the conversation reads as a distinct surface inside the
                // window background instead of bleeding edge-to-edge.
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color(nsColor: .windowBackgroundColor).opacity(0.75))
                        .shadow(color: Color.black.opacity(0.35), radius: 14, x: 0, y: 4)
                    if let session = manager.activeSession {
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

    private func tabStrip(for project: ProjectEntry) -> some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(project.sessions) { s in
                        AgentTab(session: s,
                                 isActive: manager.activeSessionId == s.id,
                                 onSelect: { manager.activeSessionId = s.id },
                                 onClose: { manager.close(s) })
                    }
                    Button {
                        manager.spawn(cwd: project.cwd)
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 10, weight: .bold))
                            .frame(width: 24, height: 24)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(Color.primary.opacity(0.05))
                            )
                    }
                    .buttonStyle(.plain)
                    .help("New tab in this project")
                }
                .padding(.leading, 14)
                .padding(.trailing, 6)
            }
            .layoutPriority(1)
        }
        .padding(.vertical, 8)
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

    private var label: String {
        if let t = session.aiTitle, !t.isEmpty { return t }
        switch session.status {
        case .idle:    return "Ready"
        case .running: return "Working…"
        case .waiting: return "Waiting on you"
        case .error:   return "Error"
        }
    }

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
            // Chain glyph — shown when this tab is part of a wired
            // pipeline (either feeding another agent or being fed by
            // one) or operating as a coordinator. Visual cue only;
            // chain settings live in the conversation header.
            if session.chainTargetId != nil ||
               session.chainSourceId != nil ||
               session.isCoordinator {
                Image(systemName: session.isCoordinator
                      ? "network"
                      : (session.chainTargetId != nil
                         ? "arrow.turn.up.right"
                         : "arrow.turn.down.right"))
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color.brandOrange.opacity(0.85))
                    .help(session.isCoordinator
                          ? "Coordinator agent — orchestrates other sessions via MCP"
                          : "Part of an active chain")
            }
            // Pending-hand-off bell — drawn instead of/alongside chain
            // glyph when this tab has a hand-off waiting for approval.
            if session.pendingHandOff != nil {
                Image(systemName: "envelope.badge.fill")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color.brandOrange)
                    .help("Pending hand-off from another agent")
            }
            Text(label)
                .font(.system(size: 12, weight: isActive ? .semibold : .medium))
                .lineLimit(1)
                .frame(maxWidth: 220, alignment: .leading)
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
                }
            }
            Divider()
            Button("Close Tab", role: .destructive, action: onClose)
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
}
