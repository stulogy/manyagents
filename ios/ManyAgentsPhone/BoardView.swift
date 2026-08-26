import SwiftUI

/// Every tab on the Mac, newest state first. The one job this screen has
/// is answering "is anything waiting on me?" from across the room, so
/// tabs that need you sort to the top and say why.
struct BoardView: View {
    @EnvironmentObject var link: MacLink
    @State private var showSettings = false

    private var ordered: [MacLink.Tab] {
        link.board.sorted { a, b in
            if a.needsYou != b.needsYou { return a.needsYou }
            if a.isBusy != b.isBusy { return a.isBusy }
            return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if link.board.isEmpty {
                    emptyState
                } else {
                    List(ordered) { tab in
                        NavigationLink {
                            TabChatView(tabId: tab.id)
                        } label: {
                            row(tab)
                        }
                    }
                    .listStyle(.plain)
                    .refreshable { link.refreshBoard() }
                }
            }
            .navigationTitle("Tabs")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { connectionChip }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                }
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
        }
    }

    private func row(_ tab: MacLink.Tab) -> some View {
        HStack(spacing: 11) {
            StatusDot(status: tab.status, pulsing: tab.isBusy)
            VStack(alignment: .leading, spacing: 2) {
                Text(tab.title)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(tab.project)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let blocked = tab.blocked {
                        Text(blocked == "permission"
                             ? "needs approval\(tab.permissionTool.map { ": \($0)" } ?? "")"
                             : "asked you a question")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.orange)
                            .lineLimit(1)
                    } else if tab.status == "waiting" {
                        Text("waiting on you")
                            .font(.caption)
                            .foregroundStyle(.blue)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: connectionIcon)
                .font(.system(size: 34))
                .foregroundStyle(.secondary)
            Text(emptyTitle).font(.headline)
            Text(emptyDetail)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
    }

    private var connectionChip: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(chipColor)
                .frame(width: 7, height: 7)
            Text(chipText)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(chipColor)
        }
    }

    private var chipColor: Color {
        switch link.connection {
        case .connected:  return .green
        case .macOffline: return .orange
        case .failed:     return .red
        default:          return .secondary
        }
    }

    private var chipText: String {
        switch link.connection {
        case .idle:        return "offline"
        case .connecting:  return "connecting"
        case .connected:   return link.pairing?.mac ?? "connected"
        case .macOffline:  return "Mac asleep"
        case .failed:      return "error"
        }
    }

    private var connectionIcon: String {
        switch link.connection {
        case .connected: return "rectangle.stack"
        case .macOffline: return "moon.zzz"
        default: return "wifi.exclamationmark"
        }
    }

    private var emptyTitle: String {
        switch link.connection {
        case .connected:  return "No tabs open"
        case .macOffline: return "Your Mac is offline"
        case .failed:     return "Can't reach the relay"
        default:          return "Connecting…"
        }
    }

    private var emptyDetail: String {
        switch link.connection {
        case .connected:  return "Open a session in ManyAgents on your Mac and it shows up here."
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
            .fill(Color.status(status))
            .frame(width: 9, height: 9)
            .opacity(pulsing && on ? 0.35 : 1)
            .onAppear {
                guard pulsing else { return }
                withAnimation(.easeInOut(duration: 1).repeatForever(autoreverses: true)) { on = true }
            }
    }
}

struct SettingsView: View {
    @EnvironmentObject var link: MacLink
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Paired Mac") {
                    LabeledContent("Mac", value: link.pairing?.mac ?? "—")
                    LabeledContent("Room", value: link.pairing?.room ?? "—")
                    LabeledContent("Relay", value: link.pairing?.relay ?? "—")
                }
                Section {
                    Button("Reconnect") { link.reconnect() }
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
