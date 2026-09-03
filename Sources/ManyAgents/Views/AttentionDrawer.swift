import SwiftUI

/// Everything waiting on you, from every project, in one place.
///
/// The thing this replaces is a message you have to ask for. Ask an
/// orchestrator what needs you and it produces exactly this list — six
/// items, each with what it would do by default — and then the message
/// scrolls away and you ask again tomorrow. This is that list, standing.
///
/// No dismiss button anywhere, on purpose. Every row clears itself when the
/// tab it belongs to moves on, so there is nothing to keep tidy. A list
/// that needs grooming becomes another inbox to ignore, which is the exact
/// failure it exists to prevent.
struct AttentionDrawer: View {
    @EnvironmentObject var manager: AgentManager
    @Binding var open: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(0.4)
            if manager.attentionItems.isEmpty {
                empty
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(manager.attentionItems) { item in
                            row(item)
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
            if manager.attentionDecisionCount > 0 {
                Text("\(manager.attentionDecisionCount)")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.brandOrange))
            }
            Spacer()
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
            Text("Questions, blocked tools and anything an orchestrator flags land here.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 18)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// One row, and clicking it goes to the tab that raised it. That jump
    /// is the whole interaction: the drawer says what and where, the answer
    /// is always given in the tab itself, where the context is.
    private func row(_ item: AttentionItem) -> some View {
        Button {
            manager.activeSessionId = item.sessionId
            manager.previewActive = false
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 5) {
                    Image(systemName: item.source.icon)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(item.kind == .decision ? Color.brandOrange : .secondary)
                    Text(item.tabLabel)
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                    Text(item.projectName)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if let due = item.deadline, !due.isEmpty {
                        Text(due)
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Color.brandOrange)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.brandOrange.opacity(0.15)))
                    }
                }
                Text(item.summary)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.primary.opacity(0.85))
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                // The orchestrator's default. Most rows become one tap
                // because of this line: you're saying yes to a plan, not
                // reconstructing the question from scratch.
                if let rec = item.recommendation, !rec.isEmpty {
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
                    .stroke(item.kind == .decision
                            ? Color.brandOrange.opacity(0.28) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}
