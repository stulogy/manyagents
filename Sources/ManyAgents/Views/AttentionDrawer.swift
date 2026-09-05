import SwiftUI

/// A rolling list of what was asked of you and hasn't been answered.
///
/// The first cut of this was a live view of which tabs were idle. Wrong
/// thing: a tab that has finished is also a tab that isn't running, so it
/// filled with completion reports — "Done. Three files written, builds
/// clean" — none of which needed anyone. And it emptied itself when a tab
/// moved on, losing the question it existed to hold.
///
/// So: a log. An agent asks "do you want me to go ahead and build this?",
/// you're deep in something else and never see it, and the row stays put
/// until you answer in that tab or tick it off here.
struct AttentionDrawer: View {
    @EnvironmentObject var manager: AgentManager
    @Binding var open: Bool
    /// Rows read as three lines by default and open in place when tapped.
    /// A truncated question is often exactly the half that doesn't say
    /// what is being asked.
    @State private var expanded: Set<UUID> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(0.4)
            if manager.attentionCount == 0 {
                empty
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        // Modal blockers first: a suspended tool call is
                        // stopping that tab dead, right now.
                        ForEach(manager.liveBlockers) { b in
                            blockerRow(b)
                        }
                        ForEach(manager.openAttention) { entry in
                            row(entry)
                        }
                    }
                    .padding(12)
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.6))
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("Needs you")
                .font(.system(size: 12, weight: .semibold))
            if manager.attentionCount > 0 {
                Text("\(manager.attentionCount)")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.brandOrange))
                Spacer()
                Button("Clear") { manager.resolveAllAttention() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .help("Mark everything answered")
            } else {
                Spacer()
            }
            Button { open = false } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Hide (⌘⇧A)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(.tertiary)
            Text("Nothing waiting on you")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Text("A question you don't notice lands here and stays until it's answered.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 18)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func blockerRow(_ b: LiveBlocker) -> some View {
        Button {
            manager.activeSessionId = b.sessionId
            manager.previewActive = false
        } label: {
            card(icon: b.icon, tab: b.tabLabel, project: b.projectName,
                 deadline: nil, text: b.text, recommendation: nil, urgent: true,
                 lines: nil)
        }
        .buttonStyle(.plain)
    }

    /// Clicking the row goes to the tab; the tick marks it answered
    /// without going anywhere. Most of the time you'll answer in the tab
    /// and the row closes itself — the tick is for the ones that stopped
    /// mattering on their own.
    private func row(_ entry: AttentionEntry) -> some View {
        let isOpen = expanded.contains(entry.id)
        return HStack(alignment: .top, spacing: 6) {
            VStack(alignment: .leading, spacing: 0) {
                Button {
                    go(to: entry)
                } label: {
                    card(icon: entry.kind == .decision ? "hand.raised.fill" : "info.circle.fill",
                         tab: entry.tabLabel, project: entry.projectName,
                         deadline: entry.deadline, text: entry.text,
                         recommendation: entry.recommendation,
                         urgent: entry.kind == .decision,
                         lines: isOpen ? nil : 3)
                }
                .buttonStyle(.plain)
                // Only offered when there is more to see — a control that
                // does nothing on half the rows teaches you to ignore it.
                if isOpen || entry.text.count > 150 {
                    Button {
                        if isOpen { expanded.remove(entry.id) } else { expanded.insert(entry.id) }
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: isOpen ? "chevron.up" : "chevron.down")
                                .font(.system(size: 8, weight: .bold))
                            Text(isOpen ? "Less" : "More")
                                .font(.system(size: 10))
                        }
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                        .padding(.leading, 10)
                    }
                    .buttonStyle(.plain)
                }
            }

            Button {
                manager.resolveAttention(entry.id)
            } label: {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                    .padding(6)
            }
            .buttonStyle(.plain)
            .help("Mark answered")
        }
    }

    /// Land on the message that asked, not at the bottom of a transcript
    /// that has moved on since — which is what made clicking a row feel
    /// like it did nothing when the tab was already the one on screen.
    private func go(to entry: AttentionEntry) {
        manager.activeSessionId = entry.sessionId
        manager.previewActive = false
        guard let messageId = entry.messageId else { return }
        // After the tab switch has taken effect, so the target view exists.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            NotificationCenter.default.post(
                name: .maScrollToMessage, object: nil,
                userInfo: ["sessionId": entry.sessionId, "messageId": messageId])
        }
    }

    private func card(icon: String, tab: String, project: String, deadline: String?,
                      text: String, recommendation: String?, urgent: Bool,
                      lines: Int? = 4) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(urgent ? Color.brandOrange : .secondary)
                Text(tab)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                Text(project)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if let due = deadline, !due.isEmpty {
                    Text(due)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Color.brandOrange)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.brandOrange.opacity(0.15)))
                }
            }
            Text(text)
                .font(.system(size: 11.5))
                .foregroundStyle(.primary.opacity(0.85))
                .lineLimit(lines)
                .textSelection(.enabled)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            if let rec = recommendation, !rec.isEmpty {
                Text(rec)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .italic()
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(urgent ? Color.brandOrange.opacity(0.28) : Color.clear, lineWidth: 1)
        )
    }
}
