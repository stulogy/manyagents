import SwiftUI
import AppKit

struct ProjectsSidebar: View {
    @EnvironmentObject var manager: AgentManager
    @Binding var viewMode: WorkspaceMode
    @Binding var sidebarCollapsed: Bool
    @State private var showNewSessionPicker = false
    /// Projects whose worktrees are folded away, newline-joined so the choice
    /// survives a relaunch. Default is EXPANDED: a tab that was just spawned
    /// must never start life hidden behind a chevron.
    @AppStorage("sidebar.collapsedWorktrees") private var collapsedProjects: String = ""

    private func isExpanded(_ cwd: String) -> Bool {
        !collapsedProjects.split(separator: "\n").contains(Substring(cwd))
    }

    private func toggleExpanded(_ cwd: String) {
        var set = collapsedProjects.split(separator: "\n").map(String.init)
        if let idx = set.firstIndex(of: cwd) { set.remove(at: idx) } else { set.append(cwd) }
        collapsedProjects = set.joined(separator: "\n")
    }

    var body: some View {
        ZStack {
            sidebarBackground
            VStack(spacing: 0) {
                header
                Divider().opacity(0.3)
                projectList
                Spacer(minLength: 0)
                Divider().opacity(0.3)
                newButton
                    .padding(.horizontal, 14)
                    .padding(.vertical, 14)
            }
        }
        .fileImporter(
            isPresented: $showNewSessionPicker,
            allowedContentTypes: [.folder]
        ) { result in
            if case .success(let url) = result {
                manager.spawn(cwd: url.path)
            }
        }
    }

    // MARK: - Background (matches ClaudeDeck: window gradient + accent radial blurs)

    private var sidebarBackground: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(nsColor: .windowBackgroundColor),
                    Color(nsColor: .underPageBackgroundColor)
                ],
                startPoint: .top, endPoint: .bottom
            )
            GeometryReader { proxy in
                Circle()
                    .fill(Color.brandOrange.opacity(0.18))
                    .frame(width: proxy.size.width * 1.4)
                    .blur(radius: 120)
                    .offset(x: -proxy.size.width * 0.4, y: -proxy.size.height * 0.5)
                Circle()
                    .fill(Color.brandOrange.opacity(0.10))
                    .frame(width: proxy.size.width * 1.2)
                    .blur(radius: 140)
                    .offset(x: proxy.size.width * 0.3, y: proxy.size.height * 0.6)
            }
            .allowsHitTesting(false)
        }
        .ignoresSafeArea()
    }

    private var header: some View {
        HStack(spacing: 10) {
            viewModeToggle
            Spacer()
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    sidebarCollapsed = true
                }
            } label: {
                Image(systemName: "sidebar.left")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Hide sidebar (⌘⇧S)")
            .keyboardShortcut("s", modifiers: [.command, .shift])
        }
        .padding(.horizontal, 14)
        .padding(.top, 16)
        .padding(.bottom, 14)
    }

    private var newButton: some View {
        Button {
            showNewSessionPicker = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.brandOrange)
                Text("New session")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.primary)
                Spacer()
                Text("⌘N")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.primary.opacity(0.10), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .keyboardShortcut("n", modifiers: .command)
    }

    private var projectList: some View {
        ScrollView {
            VStack(spacing: 6) {
                ForEach(manager.projectTree) { group in
                    let expanded = isExpanded(group.project.cwd)
                    ProjectRow(
                        project: group.project,
                        hiddenSessions: expanded ? [] : group.worktrees.flatMap(\.sessions),
                        foldState: group.worktrees.isEmpty
                            ? nil
                            : (expanded: expanded, toggle: { toggleExpanded(group.project.cwd) }),
                        worktreeCount: group.worktrees.count
                    )
                    // Worktrees of this project, indented under it — same
                    // repo, different branch, so they belong to this row
                    // rather than standing beside it as separate projects.
                    if expanded {
                        ForEach(group.worktrees) { wt in
                            ProjectRow(project: wt, isWorktree: true)
                                .padding(.leading, 14)
                        }
                    }
                }
            }
            .animation(.easeInOut(duration: 0.16), value: collapsedProjects)
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
        }
    }

    private var countLabel: String {
        let n = manager.projects.count
        return n == 1 ? "1 project" : "\(n) projects"
    }

    /// Compact row/card switcher pinned to the right of the header. Same
    /// hand-rolled pill ClaudeDeck uses.
    private var viewModeToggle: some View {
        HStack(spacing: 3) {
            toggleButton(.row, icon: "list.bullet")
            toggleButton(.card, icon: "square.grid.2x2")
            browserToggle
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.primary.opacity(0.08))
        )
        .help(viewMode == .row ? "Switch to card overview" : "Switch to row view")
    }

    /// Icon-only Browser toggle, living with the view-mode switcher.
    /// Exclusive third state: the browser renders in the row-mode pane,
    /// so entering it forces row mode (cards ignores previewActive).
    private var browserToggle: some View {
        Button {
            manager.previewActive.toggle()
            if manager.previewActive && viewMode == .card {
                viewMode = .row
            }
        } label: {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(manager.previewActive ? Color.brandOrange : Color.clear)
                .frame(width: 32, height: 24)
                .overlay(
                    Image(systemName: "globe")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(manager.previewActive ? .white : .secondary)
                )
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .help("Browser — shared session across all agents (⌘⇧P)")
        .keyboardShortcut("p", modifiers: [.command, .shift])
    }

    private func toggleButton(_ mode: WorkspaceMode, icon: String) -> some View {
        let isActive = viewMode == mode && !manager.previewActive
        return Button {
            // Mutually exclusive with the browser — picking a view mode
            // always leaves the browser (both lit at once read as broken).
            viewMode = mode
            manager.previewActive = false
        } label: {
            // Background first, icon as overlay — and a contentShape that
            // matches the full rectangle so the entire pill area is
            // hit-testable, not just the icon glyph itself.
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isActive ? Color.brandOrange : Color.clear)
                .frame(width: 32, height: 24)
                .overlay(
                    Image(systemName: icon)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(isActive ? Color.white : .secondary)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Project row

private struct ProjectRow: View {
    let project: ProjectEntry
    /// Worktree rows read as a branch of the row above: a leading glyph, the
    /// branch-ish part of the name, and no repetition of the parent's path.
    var isWorktree: Bool = false
    /// Worktrees folded away under this row. Empty unless this is a parent
    /// with a collapsed group — their sessions still count toward its chips.
    var hiddenSessions: [AgentSession] = []
    /// Non-nil when this row owns worktrees: drives the fold chevron.
    var foldState: (expanded: Bool, toggle: () -> Void)? = nil
    @EnvironmentObject var manager: AgentManager
    @State private var isDropTarget = false
    /// Staged worktree removal: the safety check runs off the main thread,
    /// then this presents its verdict for confirmation (or its refusal).
    @State private var removalPrompt: WorktreeRemovalPrompt?

    var isActive: Bool { manager.activeProject?.cwd == project.cwd }
    /// The directory was deleted while its tabs stayed open — a worktree
    /// cleanup does this six times over. The row looked perfectly healthy,
    /// so say it plainly instead.
    private var isMissing: Bool { !ProjectNaming.directoryExists(project.cwd) }

    private var kind: GitWorktrees.Kind { GitWorktrees.kind(forCwd: project.cwd) }

    private var nestedGlyph: String {
        switch kind {
        case .worktree: return "arrow.triangle.branch"
        case .nestedRepo: return "shippingbox"
        case .subdirectory, .root: return "folder"
        }
    }

    private var nestedGlyphHelp: String {
        switch kind {
        case .worktree: return "A git worktree of this project"
        case .nestedRepo: return "A separate repo inside this project"
        case .subdirectory, .root: return "A folder inside this project"
        }
    }

    /// "6" worktrees under this project — shown beside the fold chevron so a
    /// collapsed row still says how much is tucked underneath it.
    private var hiddenCountLabel: String {
        guard let fold = foldState else { return "" }
        return fold.expanded ? "" : "\(worktreeCount)"
    }
    var worktreeCount: Int = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if isWorktree {
                    // The glyph says WHAT this row is. They all used to wear
                    // the branch icon, which called a separately-cloned repo
                    // a worktree and a plain subfolder a branch.
                    Image(systemName: nestedGlyph)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .help(nestedGlyphHelp)
                }
                Text(isWorktree ? project.worktreeLabel : project.displayName)
                    .font(.system(size: isWorktree ? 12.5 : 13.5, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(isMissing ? .secondary : .primary)
                if isMissing {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(.orange)
                        .help("This directory no longer exists — the tabs here can't run anything. Close them.")
                }
                if let fold = foldState {
                    // Fold the worktrees away — six port branches are worth
                    // seeing while they work and worth hiding afterwards.
                    Button(action: fold.toggle) {
                        HStack(spacing: 2) {
                            Image(systemName: fold.expanded ? "chevron.down" : "chevron.right")
                                .font(.system(size: 8, weight: .bold))
                            Text("\(hiddenCountLabel)")
                                .font(.system(size: 9.5, weight: .semibold))
                                .monospacedDigit()
                        }
                        .foregroundStyle(.tertiary)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(fold.expanded ? "Hide worktrees" : "Show worktrees")
                }
                Spacer(minLength: 6)
                statusChips
            }
            Text(isMissing ? "\(project.prettyCwd)  (deleted)" : project.prettyCwd)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(isMissing ? .orange.opacity(0.75) : .secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isActive ? Color.activeHighlight.opacity(0.18) : Color.primary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(isActive ? Color.activeHighlight.opacity(0.45) : .clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .overlay(alignment: .top) {
            // Drop indicator — thin orange line above the row when a
            // dragged project is hovering over it.
            if isDropTarget {
                Rectangle()
                    .fill(Color.brandOrange)
                    .frame(height: 2)
            }
        }
        .onTapGesture { manager.activate(project: project) }
        .draggable(project.cwd) {
            // Compact drag preview so the cursor stays close to the drop
            // target and the row underneath stays legible.
            HStack(spacing: 6) {
                Image(systemName: "rectangle.stack.fill")
                    .font(.system(size: 10, weight: .semibold))
                Text(project.displayName)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(Color.brandOrange.opacity(0.9)))
            .foregroundStyle(.white)
        }
        .dropDestination(for: String.self) { items, _ in
            guard let movedCwd = items.first, movedCwd != project.cwd else { return false }
            manager.reorderProject(movedCwd: movedCwd, before: project.cwd)
            return true
        } isTargeted: { targeted in
            isDropTarget = targeted
        }
        .contextMenu {
            Button {
                manager.activate(project: project)
            } label: { Label("Open", systemImage: "arrow.right.circle") }

            Button {
                manager.spawn(cwd: project.cwd)
            } label: { Label("New session here", systemImage: "plus.bubble") }

            Divider()

            Button {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: project.cwd)])
            } label: { Label("Reveal in Finder", systemImage: "folder") }

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(project.cwd, forType: .string)
            } label: { Label("Copy path", systemImage: "doc.on.doc") }

            if kind == .worktree, !isMissing {
                Divider()
                // The lifecycle hole this closes: the orchestrator cuts a
                // worktree per parallel task and nothing ever removed them.
                // Safe ones go from here; the rest explain themselves.
                Button {
                    stageWorktreeRemoval()
                } label: { Label("Remove worktree…", systemImage: "trash") }
            }

            Divider()

            Button(role: .destructive) {
                // ProjectEntry.sessions is a snapshot, so iterating while
                // manager.close() mutates the live array is safe.
                for s in project.sessions { manager.close(s) }
            } label: {
                Label(isMissing
                      ? "Close \(project.sessions.count) tab\(project.sessions.count == 1 ? "" : "s") (directory deleted)"
                      : (project.sessions.count <= 1
                         ? "Close session"
                         : "Close project (\(project.sessions.count) sessions)"),
                      systemImage: "xmark")
            }
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
    }

    /// Check the worktree off the main thread, then present the verdict.
    /// Refusals are shown, not hidden: "3 unpushed commits" is the useful
    /// answer, and it tells the user what to do before trying again.
    private func stageWorktreeRemoval() {
        let cwd = project.cwd
        let name = project.worktreeLabel
        let tabs = project.sessions.count
        Task.detached {
            let verdict = GitWorktrees.safety(ofWorktree: cwd)
            await MainActor.run {
                if verdict.removable {
                    let tabNote = tabs == 0
                        ? ""
                        : " Its \(tabs) open tab\(tabs == 1 ? "" : "s") will be closed first (recoverable via Resume)."
                    removalPrompt = WorktreeRemovalPrompt(
                        title: "Remove worktree “\(name)”?",
                        message: "The branch is safe — \(verdict.reason) — so the directory can go.\(tabNote)",
                        canRemove: true,
                        cwd: cwd)
                } else {
                    removalPrompt = WorktreeRemovalPrompt(
                        title: "Can't remove “\(name)”",
                        message: "It has \(verdict.reason). Commit and push (or merge) that work first, and this will be removable.",
                        canRemove: false,
                        cwd: cwd)
                }
            }
        }
    }

    private func performRemoval(_ prompt: WorktreeRemovalPrompt) {
        removalPrompt = nil
        // Close the tabs BEFORE deleting the directory, so no session is left
        // pointing at a hole — the state we started flagging in 0.9.2.
        for s in project.sessions { manager.close(s) }
        let cwd = prompt.cwd
        Task.detached {
            let result = GitWorktrees.remove(worktree: cwd)
            if case .failure(let err) = result {
                await MainActor.run {
                    removalPrompt = WorktreeRemovalPrompt(
                        title: "Couldn't remove the worktree",
                        message: "git refused: \(err.message)",
                        canRemove: false,
                        cwd: cwd)
                }
            }
        }
    }

    private var statusChips: some View {
        HStack(spacing: 4) {
            // Counts its OWN tabs, plus the worktrees' when they're folded
            // away — otherwise collapsing the group would silently hide six
            // running agents behind a quiet-looking row.
            let counted = project.sessions + hiddenSessions
            let waiting = counted.filter { $0.status == .waiting }.count
            let working = counted.filter { $0.status == .running }.count
            let idle    = counted.filter { $0.status == .idle    }.count
            let errored = counted.filter { $0.status == .error   }.count
            if waiting > 0 {
                Chip(icon: "hand.raised.fill", text: "\(waiting)", tint: .orange, spin: false)
            }
            if working > 0 {
                Chip(icon: "arrow.triangle.2.circlepath", text: "\(working)",
                     tint: Color.activeHighlight, spin: true)
            }
            if idle > 0 {
                Chip(icon: "moon.fill", text: "\(idle)", tint: .secondary, spin: false)
            }
            if errored > 0 {
                Chip(icon: "exclamationmark.triangle.fill", text: "\(errored)",
                     tint: .red, spin: false)
            }
        }
    }
}

private struct Chip: View {
    let icon: String
    let text: String
    let tint: Color
    let spin: Bool
    @State private var rotation: Double = 0

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 8, weight: .semibold))
                .rotationEffect(.degrees(spin ? rotation : 0))
                .onAppear {
                    guard spin else { return }
                    withAnimation(.linear(duration: 1.6).repeatForever(autoreverses: false)) {
                        rotation = 360
                    }
                }
            Text(text)
                // Monospaced digits so a chip doesn't change width as a count
                // ticks 9 → 10, and never wraps or truncates: the count was
                // being clipped mid-glyph when the row ran short of width,
                // which read as a broken icon.
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize()
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule().fill(tint.opacity(0.18)))
        .foregroundStyle(tint)
        .fixedSize()
    }
}

/// One staged worktree removal — the confirmation or the refusal.
private struct WorktreeRemovalPrompt: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    /// false when this is a refusal: the alert then just explains itself.
    let canRemove: Bool
    let cwd: String
}
