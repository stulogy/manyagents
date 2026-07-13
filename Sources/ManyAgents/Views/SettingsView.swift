import SwiftUI

/// The app's preferences window (⌘,), split into tabs so each concern
/// has room to grow. Each control binds straight to the UserDefaults
/// keys its service reads.
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsTab()
                .tabItem { Label("General", systemImage: "gearshape") }
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
