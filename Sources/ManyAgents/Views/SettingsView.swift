import SwiftUI

/// The app's preferences window (⌘,). Currently houses notification
/// settings; new groups can slot in as more preferences appear. Each control
/// binds straight to the UserDefaults keys `NotificationService` reads.
struct SettingsView: View {
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
    @EnvironmentObject private var updater: UpdaterViewModel

    var body: some View {
        Form {
            Section {
                Toggle("Automatically check for updates", isOn: $updater.automaticallyChecksForUpdates)
            } header: {
                Text("Updates")
            } footer: {
                Text("ManyAgents updates itself in place when a new version is available. You can also check any time from the ManyAgents menu.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

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
            } header: {
                Text("Notifications")
            } footer: {
                Text("A banner appears (and the chosen sound plays) when an agent stops working — finished, waiting on you, or errored. \"Only when ManyAgents isn't focused\" keeps it quiet while you're already watching.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }
}
