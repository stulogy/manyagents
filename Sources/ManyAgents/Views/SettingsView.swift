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
    @EnvironmentObject private var stayAwake: StayAwake
    @EnvironmentObject private var wifi: WiFiWatchdog

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
                Text("\"While agents are working\" holds the Mac awake only during a turn, then lets it sleep again. Closing the lid is a special case: macOS sleeps on lid close regardless of that, so the lid option changes a system-wide power setting (pmset disablesleep) and needs your admin password. ManyAgents puts it back when you switch the option off or quit. Wi-Fi recovery only ever asks macOS to rejoin a network you've already saved.")
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
