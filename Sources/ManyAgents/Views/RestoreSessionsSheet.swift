import SwiftUI

/// Sheet that surfaces on launch when a saved snapshot is found. Same
/// shape as ClaudeDeck's restore sheet: lists what was open last time,
/// gives the user Reopen / Start fresh / dismiss.
struct RestoreSessionsSheet: View {
    let snapshot: AgentManager.Snapshot
    let onReopen: () -> Void
    let onDiscard: () -> Void
    let onDismiss: () -> Void

    private var byCwd: [(cwd: String, count: Int)] {
        var map: [String: Int] = [:]
        for a in snapshot.agents { map[a.cwd, default: 0] += 1 }
        return map.map { (cwd: $0.key, count: $0.value) }
            .sorted { $0.cwd.localizedCaseInsensitiveCompare($1.cwd) == .orderedAscending }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "arrow.counterclockwise.circle.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(Color.brandOrange)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Resume previous session?")
                        .font(.system(size: 15, weight: .semibold))
                    Text(summaryLine)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: 6) {
                ForEach(snapshot.agents) { a in
                    HStack(spacing: 8) {
                        Image(systemName: "circle.fill")
                            .font(.system(size: 5))
                            .foregroundStyle(.secondary)
                        Text(a.aiTitle?.isEmpty == false ? a.aiTitle! : a.displayName)
                            .font(.system(size: 12.5, weight: .medium))
                        Text(prettyCwd(a.cwd))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 0)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.04))
            )

            HStack(spacing: 10) {
                Button("Start fresh", role: .destructive, action: onDiscard)
                    .buttonStyle(.bordered)
                Spacer(minLength: 0)
                Button("Decide later", action: onDismiss)
                    .buttonStyle(.bordered)
                Button("Reopen", action: onReopen)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 440, maxWidth: 540)
    }

    private var summaryLine: String {
        let agents = snapshot.agents.count
        let projects = byCwd.count
        let a = agents == 1 ? "1 agent" : "\(agents) agents"
        let p = projects == 1 ? "1 project" : "\(projects) projects"
        return "\(a) across \(p) from last launch"
    }

    private func prettyCwd(_ cwd: String) -> String {
        let home = NSHomeDirectory()
        if cwd.hasPrefix(home) { return "~" + cwd.dropFirst(home.count) }
        return cwd
    }
}
