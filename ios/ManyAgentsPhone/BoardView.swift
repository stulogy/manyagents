import SwiftUI

/// The board, grouped the way the Mac groups it: by project, because a
/// flat list of eighteen tabs is a wall you have to read every time.
/// Anything waiting on you is lifted out into its own section at the top —
/// that is the only thing you open the app in a hurry to find.
struct BoardView: View {
    @EnvironmentObject var link: MacLink
    @State private var showSettings = false
    @State private var collapsed: Set<String> = []
    /// Wrapped because `fullScreenCover(item:)` wants Identifiable, and a
    /// bare tab id string isn't.
    struct DriveTarget: Identifiable { let id: String }
    @State private var driveTab: DriveTarget?
    @State private var appointing = false
    @State private var showCompanionPicker = false

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

    /// The Mac's two-level sidebar: workspaces on top carrying the repos
    /// cloned inside them, each repo carrying its worktrees. `~/Sites/uhp`
    /// is one row with three repos under it, not four unrelated projects.
    struct Group: Identifiable {
        let id: String            // workspace or repo path
        let name: String
        var directTabs: [MacLink.Tab] = []          // tabs in the top repo itself
        var repos: [(name: String, tabs: [MacLink.Tab])] = []
        var count: Int { directTabs.count + repos.reduce(0) { $0 + $1.tabs.count } }
        var busy: Bool {
            directTabs.contains(where: \.isBusy) || repos.contains { $0.tabs.contains(where: \.isBusy) }
        }
    }

    private var groups: [Group] {
        let rest = link.board.filter { !$0.needsYou }
        // A repo nests under its workspace only when that workspace has tabs
        // of its own — otherwise it stands on its own, same rule as the Mac.
        let reposWithTabs = Set(rest.map(\.repo))
        func topKey(_ t: MacLink.Tab) -> String {
            (!t.workspace.isEmpty && t.workspace != t.repo && reposWithTabs.contains(t.workspace))
                ? t.workspace : t.repo
        }

        var built: [String: Group] = [:]
        var order: [String] = []
        for tab in rest {
            let key = topKey(tab)
            if built[key] == nil {
                let name = key == tab.repo ? tab.project : tab.workspaceName
                built[key] = Group(id: key, name: name.isEmpty ? tab.project : name)
                order.append(key)
            }
            if tab.repo == key {
                built[key]?.directTabs.append(tab)
            } else {
                if let i = built[key]?.repos.firstIndex(where: { $0.name == tab.project }) {
                    built[key]?.repos[i].tabs.append(tab)
                } else {
                    built[key]?.repos.append((name: tab.project, tabs: [tab]))
                }
            }
        }
        return order.compactMap { built[$0] }.sorted { a, b in
            if a.busy != b.busy { return a.busy }
            return a.count > b.count
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.canvas.ignoresSafeArea()
                if link.board.isEmpty {
                    // The companion stays reachable with an empty board.
                    // Hiding it here hid the one control that can fix the
                    // emptiness — it appoints an orchestrator on the Mac,
                    // and after a Mac restart that's exactly the state
                    // you're in.
                    VStack(spacing: 0) {
                        companionBar.padding(.horizontal, 14).padding(.top, 12)
                        EmptyBoard(connection: link.connection)
                    }
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 18) {
                            companionBar
                            if !needsYou.isEmpty {
                                section(title: "Needs you", tint: Theme.orange) {
                                    ForEach(needsYou) { tab in row(tab, highlighted: true) }
                                }
                            }
                            ForEach(groups) { group in
                                groupSection(group)
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
                ToolbarItem(placement: .topBarLeading) {
                    ConnectionDot(connection: link.connection)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: {
                        Image(systemName: "gearshape").foregroundStyle(Theme.dim)
                    }
                }
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .sheet(isPresented: $showCompanionPicker) {
                CompanionPicker { tab in
                    link.chooseCompanion(tab)
                    showCompanionPicker = false
                }
                .environmentObject(link)
                .presentationDetents([.medium])
            }
            .fullScreenCover(item: $driveTab) { target in
                DriveModeView(tabId: target.id)
                    .environmentObject(link)
                    .environmentObject(Voice.shared)
            }
        }
        .tint(Theme.orange)
    }

    /// The one control this app exists for.
    ///
    /// Everything below it is a tab doing one job. This talks to the
    /// orchestrator, which can see the whole board and drive it — so
    /// "what's everyone up to" and "tell the ops one to run the tests"
    /// both land somewhere that can actually answer. Kept at the top, big,
    /// and reachable with a thumb, because the moment you want it you are
    /// usually driving.
    @ViewBuilder
    private var companionBar: some View {
        Button {
            if let tab = link.companionTab {
                driveTab = DriveTarget(id: tab)
            } else {
                appointing = true
                link.askForCompanion(create: true) { tab in
                    appointing = false
                    driveTab = tab.map(DriveTarget.init)
                }
            }
        } label: {
            HStack(spacing: 13) {
                ZStack {
                    Circle().fill(Theme.orange.opacity(0.16)).frame(width: 44, height: 44)
                    if appointing {
                        ProgressView().controlSize(.small).tint(Theme.orange)
                    } else {
                        Image(systemName: "waveform")
                            .font(.system(size: 19, weight: .semibold))
                            .foregroundStyle(Theme.orange)
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Talk to ManyAgents")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Theme.text)
                    Text(companionSubtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.dim)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .overlay(alignment: .trailing) { companionSwitcher.padding(.trailing, 8) }
            .card(highlighted: true)
        }
        .buttonStyle(.plain)
        .disabled(appointing)
    }

    /// Names the board it's on. "Sees every tab" was a lie the moment a
    /// second orchestrator existed: each one covers its own project, and
    /// leaving that implicit meant you couldn't tell whose work you were
    /// asking about.
    private var companionSubtitle: String {
        if appointing { return "Starting one on your Mac…" }
        if let error = link.companionError, link.companionTab == nil { return error }
        guard let id = link.companionTab,
              let tab = link.board.first(where: { $0.id == id })
        else { return "Hands-free, across a project's tabs" }
        let count = link.tabCount(inScopeOf: tab)
        let where_ = link.scopeName(of: tab)
        if tab.isBusy { return "\(where_) · working" }
        return "\(where_) · \(count) tab\(count == 1 ? "" : "s")"
    }

    /// Switching boards is a first-class action, not a hidden one — with
    /// more than one orchestrator the top button is otherwise a coin toss
    /// the user never sees being flipped.
    @ViewBuilder
    private var companionSwitcher: some View {
        if link.orchestrators.count > 1 {
            Button { showCompanionPicker = true } label: {
                Image(systemName: "arrow.triangle.swap")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.orange)
                    .padding(8)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Switch which project you're talking to")
        } else {
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.dim)
        }
    }

    /// Talk to *this* project. One tap from the board, so the answer to
    /// "which one is it referring to" is "the one you tapped".
    @ViewBuilder
    private func groupTalkButton(_ group: Group) -> some View {
        Button {
            appointing = true
            link.askForCompanion(scope: group.id, create: true) { tab in
                appointing = false
                driveTab = tab.map(DriveTarget.init)
            }
        } label: {
            Image(systemName: "waveform")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.orange.opacity(0.85))
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Talk to \(group.name)")
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
    private func groupSection(_ group: Group) -> some View {
        let isCollapsed = collapsed.contains(group.id)
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    if isCollapsed { collapsed.remove(group.id) } else { collapsed.insert(group.id) }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                    Text(group.name.uppercased())
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(1.1)
                    Text("\(group.count)")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Theme.dim.opacity(0.7))
                    if group.busy {
                        Circle().fill(Theme.orange).frame(width: 5, height: 5)
                    }
                    Spacer()
                }
                .foregroundStyle(Theme.dim)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .overlay(alignment: .trailing) { groupTalkButton(group) }

            if !isCollapsed {
                ForEach(group.directTabs) { tab in tabRows(tab) }
                ForEach(group.repos, id: \.name) { repo in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 5) {
                            Image(systemName: "shippingbox")
                                .font(.system(size: 9, weight: .semibold))
                            Text(repo.name)
                                .font(.system(size: 10.5, weight: .medium))
                            Text("\(repo.tabs.count)")
                                .font(.system(size: 10))
                                .foregroundStyle(Theme.dim.opacity(0.6))
                        }
                        .foregroundStyle(Theme.dim)
                        .padding(.leading, 12)
                        ForEach(repo.tabs) { tab in
                            tabRows(tab).padding(.leading, 12)
                        }
                    }
                }
            }
        }
    }

    /// A tab row, prefixed with its checkout when it lives in a worktree.
    @ViewBuilder
    private func tabRows(_ tab: MacLink.Tab) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if tab.isWorktree {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 8, weight: .semibold))
                    Text(tab.checkout)
                        .font(.system(size: 9.5))
                }
                .foregroundStyle(Theme.dim.opacity(0.75))
                .padding(.leading, 12)
            }
            row(tab, highlighted: false)
                .padding(.leading, tab.isWorktree ? 12 : 0)
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

/// Just a dot. The old chip crammed the Mac's name into a circular
/// toolbar slot and rendered as "St…", which said nothing and looked
/// broken; the name lives in Settings, where there's room for it.
struct ConnectionDot: View {
    let connection: MacLink.Connection
    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 9, height: 9)
            .opacity(connecting && pulse ? 0.25 : 1)
            .onAppear {
                guard connecting else { return }
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                    pulse = true
                }
            }
            .accessibilityLabel(label)
    }

    private var connecting: Bool {
        if case .connecting = connection { return true }
        return false
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
        case .connected:  return "Connected to your Mac"
        case .macOffline: return "Mac offline"
        case .connecting: return "Connecting"
        case .failed:     return "Connection error"
        case .idle:       return "Offline"
        }
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
                    NavigationLink {
                        VoiceSettingsView()
                    } label: {
                        LabeledContent("Voice") {
                            Text(voiceSummary).foregroundStyle(.secondary)
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

    private var voiceSummary: String {
        let settings = VoiceSettings.shared
        guard settings.engine == .elevenLabs else { return "This iPhone" }
        return settings.hasKey ? settings.voiceName : "Needs a key"
    }
}
