import SwiftUI

/// The orchestrator surface — a dedicated panel, separate from the per-session
/// Hand-off control, for running *other* agents from this one. Plain-language
/// framing of "coordinator mode", plus a live view of who it can dispatch to
/// and what it's dispatched so far.
struct OrchestratorPanel: View {
    @ObservedObject var session: AgentSession
    @EnvironmentObject var manager: AgentManager
    let onClose: () -> Void

    private var others: [AgentSession] {
        manager.sessions.filter { $0.id != session.id }
    }

    /// Dispatches this agent kicked off (most recent first). Falls back to
    /// showing source-less records so activity is visible even if the
    /// coordinator id wasn't threaded through.
    private var myDispatches: [AgentManager.DispatchRecord] {
        let mine = manager.dispatchLog.filter {
            $0.coordinatorId == session.id || $0.coordinatorId == nil
        }
        return Array(mine.suffix(8).reversed())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(0.4)
            VStack(alignment: .leading, spacing: 14) {
                toggleSection
                if session.isCoordinator {
                    agentsSection
                    if !myDispatches.isEmpty { activitySection }
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
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.brandOrange)
            Text("Orchestrator")
                .font(.system(size: 12.5, weight: .semibold))
            Spacer()
            Button { onClose() } label: {
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

    private var toggleSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: $session.isCoordinator) {
                Text("Let this agent run other agents")
                    .font(.system(size: 12.5, weight: .medium))
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            Text("It can see your other open agents, hand work to them, and open new ones (including sub-projects and further orchestrators) on its own. Takes effect on the next turn.")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var agentsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel("Agents it can run")
            if others.isEmpty {
                Text("No other agents open yet. Open one yourself (⌘N / ⌘T), or just ask this agent to create the ones it needs.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(others) { agent in
                    HStack(spacing: 8) {
                        statusDot(agent.status)
                        Text(ProjectNaming.name(forCwd: agent.cwd))
                            .font(.system(size: 11.5, weight: .medium))
                        Text(agent.aiTitle ?? agent.displayName)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        Text(statusText(agent.status))
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    private var activitySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel("Recent dispatches")
            ForEach(myDispatches) { rec in
                HStack(alignment: .top, spacing: 8) {
                    dispatchIcon(rec.state)
                        .frame(width: 12)
                        .padding(.top, 1)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("→ \(rec.targetLabel)")
                            .font(.system(size: 11.5, weight: .medium))
                        Text(rec.promptSummary)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    // MARK: - Bits

    private func sectionLabel(_ s: String) -> some View {
        Text(s.uppercased())
            .font(.system(size: 9.5, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(.secondary)
    }

    private func statusColor(_ status: AgentStatus) -> Color {
        switch status {
        case .running: return Color.brandOrange
        case .waiting: return .blue
        case .error:   return .red
        case .idle:    return .secondary
        }
    }

    private func statusText(_ status: AgentStatus) -> String {
        switch status {
        case .running: return "working"
        case .waiting: return "waiting"
        case .error:   return "error"
        case .idle:    return "idle"
        }
    }

    private func statusDot(_ status: AgentStatus) -> some View {
        Circle()
            .fill(statusColor(status))
            .frame(width: 7, height: 7)
    }

    @ViewBuilder
    private func dispatchIcon(_ state: AgentManager.DispatchRecord.State) -> some View {
        switch state {
        case .running:
            Image(systemName: "circle.dotted")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.brandOrange)
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 11))
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 11))
                .foregroundStyle(.red)
        }
    }
}
