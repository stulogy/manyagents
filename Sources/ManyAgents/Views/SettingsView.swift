import SwiftUI
import CoreImage
import AppKit

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
            OptimizeSettingsTab()
                .tabItem { Label("Optimize", systemImage: "bolt.badge.clock") }
            PhoneSettingsTab()
                .tabItem { Label("Phone", systemImage: "iphone") }
        }
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct GeneralSettingsTab: View {
    @AppStorage(ClaudeBridge.Keys.model)
    private var preferredModel = ""
    @AppStorage(VoiceCapture.Keys.inputDeviceUID)
    private var inputDeviceUID = ""
    @EnvironmentObject private var stayAwake: StayAwake
    @EnvironmentObject private var wifi: WiFiWatchdog

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
            Section {
                Picker("Microphone", selection: $inputDeviceUID) {
                    Text("System Default").tag("")
                    ForEach(VoiceCapture.availableInputs()) { device in
                        Text(device.name).tag(device.id)
                    }
                }
            } footer: {
                Text("Used for voice input in the composer. System Default follows the input selected in macOS Sound settings — pick a specific microphone if your default input is an audio interface.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Keep the Mac awake", selection: $stayAwake.mode) {
                    ForEach(StayAwake.Mode.allCases) { m in
                        Text(m.label).tag(m)
                    }
                }

                Toggle("Keep going with the lid closed", isOn: $stayAwake.keepGoingWithLidClosed)
                    .disabled(stayAwake.mode == .off)

                Toggle("Reconnect Wi-Fi if it drops", isOn: $wifi.isEnabled)

                LabeledContent("Status") {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(stayAwake.statusText)
                        Text(wifi.statusText)
                            .foregroundStyle(.secondary)
                    }
                    .font(.system(size: 11))
                    .fixedSize(horizontal: false, vertical: true)
                }

                if stayAwake.needsLidSleepRevert {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text("A previous run left lid sleep switched off system-wide.")
                            .font(.system(size: 11))
                        Spacer()
                        Button("Put it back") {
                            stayAwake.setSystemLidSleepDisabled(false)
                        }
                    }
                }
            } header: {
                Text("Staying awake")
            } footer: {
                Text("Both are off unless you switch them on. \"While agents are working\" holds the Mac awake only during a turn, then lets it sleep again. Closing the lid is a special case: macOS sleeps on lid close regardless, so that option changes a system-wide power setting (pmset disablesleep) and asks for your admin password once, when you switch it. It stays in effect after you quit ManyAgents, until you switch it back off here — nothing re-applies or reverts it behind your back. Wi-Fi recovery only ever asks macOS to rejoin a network you've already saved.")
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
                                    .controlSize(.small)
                                    .disabled(connectors.loginInFlight != nil || connectors.logoutInFlight != nil)
                                }
                            } else if server.status == .connected {
                                if server.name.hasPrefix("claude.ai") {
                                    // These grants live on the claude.ai
                                    // account; refresh already purges the
                                    // stale-token cache, so the status here
                                    // is verified. Managing the grant
                                    // happens on claude.ai.
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
                Link("Manage connectors on claude.ai", destination: URL(string: "https://claude.ai/settings/connectors")!)
                    .font(.system(size: 11))
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

private struct OptimizeSettingsTab: View {
    @AppStorage(OptimizeMode.Keys.enabled)
    private var enabled = false
    @AppStorage(OptimizeMode.Keys.subagentModel)
    private var subagentModel = OptimizeMode.Defaults.subagentModel
    @AppStorage(OptimizeMode.Keys.autoCompactThreshold)
    private var autoCompactThreshold = OptimizeMode.Defaults.autoCompactThreshold

    var body: some View {
        Form {
            Section {
                Toggle("Optimize Mode", isOn: $enabled)
            } footer: {
                Text("For running several orchestrators across projects and worktrees at once, where every dispatched tab and subagent piling up its own context adds up in tokens. Off by default — nothing here changes how ManyAgents behaves until you turn it on.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Section {
                Picker("Subagent model", selection: $subagentModel) {
                    ForEach(ClaudeBridge.availableModels, id: \.id) { m in
                        Text(m.label).tag(m.id)
                    }
                }
                .disabled(!enabled)
            } footer: {
                Text("The DEFAULT for a tab an orchestrator spawns or dispatches — never the orchestrator (or a repo lead) itself, and never a tab you opened and drive by hand. The orchestrator can ask for the full model when it hands over heavy work, and any tab can be moved either way from its own menu; a tab not on your main model says so next to its context gauge. \"Default\" leaves dispatched tabs on your main Model, i.e. no downgrade.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Auto-compact threshold")
                        Spacer()
                        Text("\(Int(autoCompactThreshold * 100))%")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: $autoCompactThreshold, in: 0.10...0.75, step: 0.05)
                        .disabled(!enabled)
                }
            } footer: {
                Text("Every tab — orchestrators included — rolls its context into a fresh working brief once it crosses this fraction of the model's window, well before claude's own ceiling-triggered compaction. Different from the Compact button: the visible conversation is never cleared, only the model's live memory resets, so scrollback and search keep working across it. A \"Context auto-compacted\" line marks where it happened.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}


// MARK: - Phone

private struct PhoneSettingsTab: View {
    @EnvironmentObject private var phone: PhoneLink
    @AppStorage("manyagents.phonelink.relayToken") private var relayToken = ""

    var body: some View {
        Form {
            Section {
                Toggle("Let my phone reach these tabs", isOn: $phone.isEnabled)
                SecureField("Relay token", text: $relayToken)
                LabeledContent("Status") {
                    Text(statusText)
                        .font(.system(size: 11))
                        .foregroundStyle(statusColor)
                }
            } header: {
                Text("Phone access")
            } footer: {
                Text("ManyAgents dials out to the relay, so there's no port to open and it works from cellular. The relay only forwards sealed envelopes — the pairing key below never leaves this Mac and your phone, and transcripts are encrypted end to end.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            if phone.isEnabled {
                Section {
                    HStack(alignment: .top, spacing: 14) {
                        QRCodeView(text: phone.pairingPayload)
                            .frame(width: 132, height: 132)
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Scan this in the ManyAgents phone app to pair.")
                                .font(.system(size: 11))
                            Text("Room \(phone.room)")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                            Button("Generate a new code") { phone.regenerateSecret() }
                                .controlSize(.small)
                            Text("Revokes any paired phone.")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                        }
                        Spacer(minLength: 0)
                    }
                } header: {
                    Text("Pairing")
                }
            }
        }
        .formStyle(.grouped)
    }

    private var statusText: String {
        switch phone.state {
        case .off:             return "Off"
        case .connecting:      return "Connecting to the relay…"
        case .waitingForPhone: return "Connected — waiting for your phone"
        case .paired:          return phone.connectedDevice.map { "Connected: \($0)" } ?? "A client is connected"
        case .failed(let why): return why
        }
    }

    private var statusColor: Color {
        switch phone.state {
        case .paired:          return .green
        case .failed:          return .orange
        default:               return .secondary
        }
    }
}

/// Renders the pairing string as a QR the phone camera can read. Built with
/// CoreImage so there's no dependency to add for one image.
private struct QRCodeView: View {
    let text: String

    var body: some View {
        if let image = qr() {
            Image(nsImage: image)
                .interpolation(.none)
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else {
            RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.08))
        }
    }

    private func qr() -> NSImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let ci = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else { return nil }
        let rep = NSCIImageRep(ciImage: ci)
        let img = NSImage(size: rep.size)
        img.addRepresentation(rep)
        return img
    }
}
