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
                 deadline: nil, text: b.text, recommendation: nil, urgent: true)
        }
        .buttonStyle(.plain)
    }

    /// Clicking the row goes to the tab; the tick marks it answered
    /// without going anywhere. Most of the time you'll answer in the tab
    /// and the row closes itself — the tick is for the ones that stopped
    /// mattering on their own.
    private func row(_ entry: AttentionEntry) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Button {
                manager.activeSessionId = entry.sessionId
                manager.previewActive = false
            } label: {
                card(icon: entry.kind == .decision ? "hand.raised.fill" : "info.circle.fill",
                     tab: entry.tabLabel, project: entry.projectName,
                     deadline: entry.deadline, text: entry.text,
                     recommendation: entry.recommendation,
                     urgent: entry.kind == .decision)
            }
            .buttonStyle(.plain)

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

    private func card(icon: String, tab: String, project: String, deadline: String?,
                      text: String, recommendation: String?, urgent: Bool) -> some View {
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
                .lineLimit(4)
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
