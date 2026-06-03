import SwiftUI

struct WorkspaceView: View {
    @EnvironmentObject var manager: AgentManager
    @EnvironmentObject var readiness: ClaudeReadiness
    @AppStorage("sidebar.width") private var sidebarWidth: Double = 260
    @AppStorage("workspace.viewMode") private var viewModeRaw: String = WorkspaceMode.row.rawValue

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
    let isActive: Bool
    let onSelect: () -> Void
    let onClose: () -> Void
    @State private var hover = false
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
        .onTapGesture(perform: onSelect)
        .onHover { hover = $0 }
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
