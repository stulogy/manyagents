import SwiftUI

/// The app's preferences window (⌘,), split into tabs so each concern
/// has room to grow. Each control binds straight to the UserDefaults
/// keys its service reads.
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsTab()
                .tabItem { Label("General", systemImage: "gearshape") }
            ConnectorsSettingsTab()
                .tabItem { Label("Connectors", systemImage: "puzzlepiece.extension") }
            NotificationSettingsTab()
                .tabItem { Label("Notifications", systemImage: "bell.badge") }
            UpdateSettingsTab()
                .tabItem { Label("Updates", systemImage: "arrow.triangle.2.circlepath") }
        }
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct GeneralSettingsTab: View {
    @AppStorage(ClaudeBridge.Keys.model)
    private var preferredModel = ""

    var body: some View {
        Form {
            Section {
                Picker("Model", selection: $preferredModel) {
                    ForEach(ClaudeBridge.availableModels, id: \.id) { m in
                        Text(m.label).tag(m.id)
                    }
                }
            } footer: {
                Text("Applies to new sessions. Change it mid-conversation and the session respawns on the new model with history preserved.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct ConnectorsSettingsTab: View {
    @ObservedObject private var connectors = MCPConnectors.shared
    @Environment(\.openURL) private var openURL

    var body: some View {
        Form {
            Section {
                if connectors.servers.isEmpty {
                    HStack {
                        Text(connectors.refreshing ? "Checking MCP servers…" : "No MCP servers configured.")
                            .foregroundStyle(.secondary)
                        if connectors.refreshing { ProgressView().controlSize(.small) }
                    }
                } else {
                    ForEach(connectors.servers) { server in
                        HStack(spacing: 8) {
                            Circle()
                                .fill(statusColor(server.status))
                                .frame(width: 7, height: 7)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(server.name)
                                    .font(.system(size: 12.5, weight: .medium))
                                Text(statusLabel(server.status))
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if server.status == .needsAuth {
                                if connectors.loginInFlight == server.name {
                                    HStack(spacing: 6) {
                                        ProgressView().controlSize(.small)
                                        Button("Cancel") {
                                            MCPConnectors.shared.cancelLogin()
                                        }
                                        .controlSize(.small)
                                    }
                                } else {
                                    Button("Authenticate") {
                                        MCPConnectors.shared.login(server.name)
                                    }
                                    .disabled(connectors.loginInFlight != nil || connectors.logoutInFlight != nil)
                                }
                            } else if server.status == .connected {
                                if server.name.hasPrefix("claude.ai") {
                                    // These grants live on the claude.ai
                                    // account; local logout is a no-op, so
                                    // don't offer a Disconnect that lies.
                                    Button("Manage…") {
                                        openURL(URL(string: "https://claude.ai/settings/connectors")!)
                                    }
                                    .controlSize(.small)
                                    .help("claude.ai connectors are managed on claude.ai — disconnect or switch the Google account there, then refresh here.")
                                } else if connectors.logoutInFlight == server.name {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Button("Disconnect") {
                                        MCPConnectors.shared.logout(server.name)
                                    }
                                    .controlSize(.small)
                                    .disabled(connectors.loginInFlight != nil || connectors.logoutInFlight != nil)
                                }
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }

                if let msg = connectors.lastLoginMessage {
                    Text(msg)
                        .font(.system(size: 11))
                        .foregroundStyle(connectors.lastLoginSucceeded == true ? .green : .secondary)
                        .textSelection(.enabled)
                }
            } header: {
                HStack {
                    Text("MCP Servers")
                    Spacer()
                    Button {
                        MCPConnectors.shared.refresh()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .buttonStyle(.borderless)
                    .disabled(connectors.refreshing)
                }
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Authenticate runs the CLI's own browser sign-in and stores the token in your keychain, so it covers every session. Sessions reconnect on their next message.")
                    Text("Some claude.ai connectors (like Google Drive) can only be authorized on claude.ai itself. If Authenticate says so, use the link below, then hit refresh here.")
                    Link("Manage connectors on claude.ai", destination: URL(string: "https://claude.ai/settings/connectors")!)
                        .font(.system(size: 11))
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { MCPConnectors.shared.refresh() }
    }

    private func statusColor(_ s: MCPConnectors.Server.Status) -> Color {
        switch s {
        case .connected: return .green
        case .needsAuth: return .orange
        case .failed:    return .red
        }
    }

    private func statusLabel(_ s: MCPConnectors.Server.Status) -> String {
        switch s {
        case .connected:        return "Connected"
        case .needsAuth:        return "Needs authentication"
        case .failed(let why):  return why
        }
    }
}

private struct NotificationSettingsTab: View {
    @AppStorage(NotificationService.Keys.enabled)
    private var enabled = true
    @AppStorage(NotificationService.Keys.sound)
    private var sound = true
    @AppStorage(NotificationService.Keys.soundName)
    private var soundName = "Glass"
    @AppStorage(NotificationService.Keys.onlyWhenInactive)
    private var onlyWhenInactive = true
    @AppStorage(NotificationService.Keys.notifyOnError)
    private var notifyOnError = true

    var body: some View {
        Form {
            Section {
                Toggle("Notify when an agent finishes", isOn: $enabled)

                Toggle("Play a sound", isOn: $sound)
                    .disabled(!enabled)

                Picker("Sound", selection: $soundName) {
                    ForEach(NotificationService.systemSounds, id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
                .disabled(!enabled || !sound)
                .onChange(of: soundName) { _, new in
                    NotificationService.shared.previewSound(new)
                }

                Toggle("Also notify on errors", isOn: $notifyOnError)
                    .disabled(!enabled)

                Toggle("Only when ManyAgents isn't focused", isOn: $onlyWhenInactive)
                    .disabled(!enabled)
            } footer: {
                Text("A banner appears (and the chosen sound plays) when an agent stops working — finished, waiting on you, or errored. \"Only when ManyAgents isn't focused\" keeps it quiet while you're already watching.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct UpdateSettingsTab: View {
    @EnvironmentObject private var updater: UpdaterViewModel

    var body: some View {
        Form {
            Section {
                Toggle("Automatically check for updates", isOn: $updater.automaticallyChecksForUpdates)
                Button("Check Now") { updater.checkForUpdates() }
                    .disabled(!updater.canCheckForUpdates)
            } footer: {
                Text("ManyAgents updates itself in place when a new version is available. You can also check any time from the ManyAgents menu.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
