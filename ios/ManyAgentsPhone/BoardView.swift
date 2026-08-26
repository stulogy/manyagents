import SwiftUI

/// The board, grouped the way the Mac groups it: by project, because a
/// flat list of eighteen tabs is a wall you have to read every time.
/// Anything waiting on you is lifted out into its own section at the top —
/// that is the only thing you open the app in a hurry to find.
struct BoardView: View {
    @EnvironmentObject var link: MacLink
    @State private var showSettings = false
    @State private var collapsed: Set<String> = []

    private var needsYou: [MacLink.Tab] {
        // Written out rather than as a tuple comparison: the tuple form
        // sends the type checker into a corner and slows every build.
        link.board.filter { $0.needsYou }.sorted { a, b in
            let aBlocked = a.blocked != nil
            let bBlocked = b.blocked != nil
            if aBlocked != bBlocked { return aBlocked }
            return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
        }
    }

    /// Everything else, bucketed by project and ordered by the project's
    /// liveliness so the thing you're working on is near the top.
    private var projects: [(name: String, tabs: [MacLink.Tab])] {
        let rest = link.board.filter { !$0.needsYou }
        let grouped = Dictionary(grouping: rest, by: { $0.project })
        return grouped
            .map { (name: $0.key, tabs: $0.value.sorted { $0.title < $1.title }) }
            .sorted { a, b in
                let aBusy = a.tabs.contains { $0.isBusy }
                let bBusy = b.tabs.contains { $0.isBusy }
                if aBusy != bBusy { return aBusy }
                if a.tabs.count != b.tabs.count { return a.tabs.count > b.tabs.count }
                return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.canvas.ignoresSafeArea()
                if link.board.isEmpty {
                    EmptyBoard(connection: link.connection)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 18) {
                            if !needsYou.isEmpty {
                                section(title: "Needs you", tint: Theme.orange) {
                                    ForEach(needsYou) { tab in row(tab, highlighted: true) }
                                }
                            }
                            ForEach(projects, id: \.name) { project in
                                projectSection(project)
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                    }
                    .refreshable { link.refreshBoard() }
                }
            }
            .navigationTitle("ManyAgents")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.canvas, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { ConnectionChip(connection: link.connection,
                                                                       mac: link.pairing?.mac) }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: {
                        Image(systemName: "gearshape").foregroundStyle(Theme.dim)
                    }
                }
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
        }
        .tint(Theme.orange)
    }

    @ViewBuilder
    private func section<Content: View>(title: String, tint: Color,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(1.1)
                .foregroundStyle(tint)
            content()
        }
    }

    @ViewBuilder
    private func projectSection(_ project: (name: String, tabs: [MacLink.Tab])) -> some View {
        let isCollapsed = collapsed.contains(project.name)
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    if isCollapsed { collapsed.remove(project.name) } else { collapsed.insert(project.name) }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                    Text(project.name.uppercased())
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(1.1)
                    Text("\(project.tabs.count)")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Theme.dim)
                    if project.tabs.contains(where: { $0.isBusy }) {
                        Circle().fill(Theme.orange).frame(width: 5, height: 5)
                    }
                    Spacer()
                }
                .foregroundStyle(Theme.dim)
            }
            .buttonStyle(.plain)

            if !isCollapsed {
                ForEach(project.tabs) { tab in row(tab, highlighted: false) }
            }
        }
    }

    private func row(_ tab: MacLink.Tab, highlighted: Bool) -> some View {
        NavigationLink {
            TabChatView(tabId: tab.id)
        } label: {
            HStack(spacing: 11) {
                StatusDot(status: tab.status, pulsing: tab.isBusy)
                VStack(alignment: .leading, spacing: 3) {
                    Text(tab.title)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        if highlighted {
                            Text(tab.project)
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.dim)
                        }
                        if !highlighted && !tab.isBusy && tab.blocked == nil {
                            Text(tab.status == "error" ? "error" : "ready")
                                .font(.system(size: 11))
                                .foregroundStyle(tab.status == "error" ? Theme.status("error") : Theme.dim)
                        }
                        if let blocked = tab.blocked {
                            Label(blocked == "permission"
                                  ? (tab.permissionTool.map { "approve \($0)" } ?? "needs approval")
                                  : "answer its question",
                                  systemImage: "hand.raised.fill")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Theme.orange)
                                .lineLimit(1)
                        } else if tab.isBusy {
                            Text("working")
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.orange)
                        }
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.dim.opacity(0.6))
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 11)
            .card(highlighted: highlighted)
        }
        .buttonStyle(.plain)
    }
}

struct ConnectionChip: View {
    let connection: MacLink.Connection
    let mac: String?

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(color)
                .lineLimit(1)
        }
    }

    private var color: Color {
        switch connection {
        case .connected:  return Color(red: 0.30, green: 0.78, blue: 0.45)
        case .macOffline: return Theme.orange
        case .failed:     return Theme.status("error")
        default:          return Theme.dim
        }
    }

    private var label: String {
        switch connection {
        case .idle:       return "offline"
        case .connecting: return "connecting"
        case .connected:  return mac ?? "connected to your Mac"
        case .macOffline: return "Mac asleep"
        case .failed:     return "error"
        }
    }
}

struct EmptyBoard: View {
    let connection: MacLink.Connection

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 32))
                .foregroundStyle(Theme.dim)
            Text(title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.text)
            Text(detail)
                .font(.system(size: 13))
                .foregroundStyle(Theme.dim)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 44)
        }
    }

    private var icon: String {
        switch connection {
        case .connected:  return "rectangle.stack"
        case .macOffline: return "moon.zzz"
        default:          return "wifi.exclamationmark"
        }
    }
    private var title: String {
        switch connection {
        case .connected:  return "No tabs open"
        case .macOffline: return "Your Mac is offline"
        case .failed:     return "Can't reach the relay"
        default:          return "Connecting…"
        }
    }
    private var detail: String {
        switch connection {
        case .connected:  return "Open a session in ManyAgents and it shows up here."
        case .macOffline: return "ManyAgents isn't running, or the Mac is asleep. This reconnects on its own."
        case .failed:     return "Check the relay is reachable, then pull to retry."
        default:          return "Reaching your Mac…"
        }
    }
}

/// Filled dot, gently pulsing while a tab is mid-turn — the same read as
/// the Mac's own status dots.
struct StatusDot: View {
    let status: String
    var pulsing: Bool = false
    @State private var on = false

    var body: some View {
        Circle()
            .fill(Theme.status(status))
            .frame(width: 8, height: 8)
            .opacity(pulsing && on ? 0.3 : 1)
            .onAppear {
                guard pulsing else { return }
                withAnimation(.easeInOut(duration: 1).repeatForever(autoreverses: true)) { on = true }
            }
    }
}

struct SettingsView: View {
    @EnvironmentObject var link: MacLink
    @Environment(\.dismiss) private var dismiss
    @State private var justTapped = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Paired Mac") {
                    LabeledContent("Mac", value: link.pairing?.mac ?? "—")
                    LabeledContent("Room", value: link.pairing?.room ?? "—")
                    // Reconnect used to give no sign it had done anything.
                    // Showing live state here means the button has visible
                    // consequences: connecting → connected, or the reason
                    // it can't.
                    LabeledContent("Connection") {
                        HStack(spacing: 6) {
                            ConnectionChip(connection: link.connection, mac: nil)
                            if case .connecting = link.connection {
                                ProgressView().controlSize(.mini)
                            }
                        }
                    }
                }
                Section {
                    Button {
                        justTapped = true
                        link.reconnect()
                        Task {
                            try? await Task.sleep(for: .seconds(2))
                            justTapped = false
                        }
                    } label: {
                        HStack {
                            Text(justTapped ? "Reconnecting…" : "Reconnect")
                            Spacer()
                            if justTapped { ProgressView().controlSize(.mini) }
                        }
                    }
                    .disabled(justTapped)
                    Button("Unpair this phone", role: .destructive) {
                        link.unpair()
                        dismiss()
                    }
                } footer: {
                    Text("Transcripts are encrypted end to end with the pairing key. The relay only forwards sealed envelopes.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}
