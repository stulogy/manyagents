import SwiftUI

struct ProjectsSidebar: View {
    @EnvironmentObject var manager: AgentManager
    @Binding var viewMode: WorkspaceMode
    @State private var showNewSessionPicker = false

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
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(BrandGradient.warm)
                    .frame(width: 30, height: 30)
                Image(systemName: "rectangle.stack.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text("ManyAgents")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                Text(countLabel)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            viewModeToggle
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
                ForEach(manager.projects) { project in
                    ProjectRow(project: project)
                }
            }
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
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.primary.opacity(0.08))
        )
        .help(viewMode == .row ? "Switch to card overview" : "Switch to row view")
    }

    private func toggleButton(_ mode: WorkspaceMode, icon: String) -> some View {
        let isActive = viewMode == mode
        return Button {
            viewMode = mode
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
    @EnvironmentObject var manager: AgentManager
    @State private var isDropTarget = false

    var isActive: Bool { manager.activeProject?.cwd == project.cwd }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(project.displayName)
                    .font(.system(size: 13.5, weight: .semibold))
                Spacer()
                statusChips
            }
            Text(project.prettyCwd)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(.secondary)
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
    }

    private var statusChips: some View {
        HStack(spacing: 4) {
            let waiting = project.sessions.filter { $0.status == .waiting }.count
            let working = project.sessions.filter { $0.status == .running }.count
            let idle    = project.sessions.filter { $0.status == .idle    }.count
            let errored = project.sessions.filter { $0.status == .error   }.count
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
                .font(.system(size: 10, weight: .semibold))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule().fill(tint.opacity(0.18)))
        .foregroundStyle(tint)
    }
}
