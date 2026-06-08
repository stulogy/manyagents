import SwiftUI

/// Per-session hand-off config — pick which agent this one's reply flows to
/// when it finishes, whether it sends automatically, and a safety limit on
/// chain length. Orchestrator/coordinator mode lives in its own panel
/// (`OrchestratorPanel`), kept separate so the two ideas don't blur together.
struct ChainSettingsPopover: View {
    @ObservedObject var session: AgentSession
    @EnvironmentObject var manager: AgentManager
    let onClose: () -> Void

    private var candidates: [AgentSession] {
        manager.sessions.filter { $0.id != session.id }
    }

    private var targetBinding: Binding<UUID?> {
        Binding(
            get: { session.chainTargetId },
            set: { session.chainTargetId = $0 }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(0.4)
            VStack(alignment: .leading, spacing: 14) {
                targetSection
                yoloSection
                budgetSection
                if session.remainingHops < session.chainHopBudget {
                    Divider().opacity(0.3)
                    chainStatusSection
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
        .frame(width: 360)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.turn.down.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.brandOrange)
            Text("Hand-off")
                .font(.system(size: 12.5, weight: .semibold))
            Spacer()
            Button {
                onClose()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var targetSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            sectionLabel("Hand off to")
            Picker("Target", selection: targetBinding) {
                Text("None — no auto hand-off").tag(UUID?.none)
                ForEach(candidates) { c in
                    Text(targetLabel(c)).tag(UUID?.some(c.id))
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .disabled(candidates.isEmpty)
            Text(targetHelpText)
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var targetHelpText: String {
        if candidates.isEmpty {
            return "Spawn another session (⌘N or ⌘T) to wire a chain."
        }
        if session.chainTargetId == nil {
            return "When this agent finishes a turn, its last reply will hand off to the picked target."
        }
        return "Fires once this agent's status flips to Idle / Waiting after a clean turn."
    }

    private var yoloSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: $session.chainYoloMode) {
                HStack(spacing: 5) {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(session.chainYoloMode ? Color.brandOrange : .secondary)
                    Text("Send automatically")
                        .font(.system(size: 12, weight: .medium))
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .disabled(session.chainTargetId == nil)
            Text(session.chainYoloMode
                 ? "Hand-offs fire immediately. Target won't see a banner — the prompt just lands and starts the next turn."
                 : "Hand-offs stage as a banner on the target. You can review / edit / dismiss before they fire.")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var budgetSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                sectionLabel("Stop after")
                Spacer()
                Text("\(session.chainHopBudget) hand-offs")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Slider(value: Binding(
                get: { Double(session.chainHopBudget) },
                set: { session.chainHopBudget = Int($0.rounded()) }
            ), in: 1...20, step: 1)
            .controlSize(.small)
            Text("A safety limit — the chain stops itself after this many hand-offs so two agents can't keep passing work back and forth forever.")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }


    private var chainStatusSection: some View {
        HStack(spacing: 6) {
            Image(systemName: "link.circle.fill")
                .font(.system(size: 11))
                .foregroundStyle(Color.brandOrange.opacity(0.85))
            Text("In a chain — \(session.remainingHops) hand-off\(session.remainingHops == 1 ? "" : "s") left")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.primary)
            Spacer()
            Button("Reset") {
                session.remainingHops = session.chainHopBudget
                session.chainSourceId = nil
            }
            .buttonStyle(.borderless)
            .font(.system(size: 10.5))
            .foregroundStyle(.tertiary)
        }
    }

    private func sectionLabel(_ s: String) -> some View {
        Text(s.uppercased())
            .font(.system(size: 9.5, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(.secondary)
    }

    private func targetLabel(_ s: AgentSession) -> String {
        let project = ProjectNaming.name(forCwd: s.cwd)
        let title = s.aiTitle ?? s.displayName
        return "\(project) · \(title)"
    }
}
