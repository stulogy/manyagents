import SwiftUI

/// Popover for the "Send to →" action on a completed message. Picks a
/// target session (any other open agent), lets the user tweak the prompt
/// text before sending, and offers two send modes:
///   * "Send" — fires immediately, no banner on the target. Use this
///     when you're confident in the prompt as-is.
///   * "Stage on target" — lands as a pendingHandOff banner on the
///     target so its owner sees what's coming and can edit / dismiss.
struct HandOffSheet: View {
    let sourceSessionId: UUID
    /// Pre-filled prompt text. Usually the source assistant message
    /// the user clicked Send-to on.
    let initialPayload: String
    let onClose: () -> Void

    @EnvironmentObject var manager: AgentManager
    @State private var draft: String = ""
    @State private var selectedTargetId: UUID?

    private var sourceLabel: String {
        guard let s = manager.sessions.first(where: { $0.id == sourceSessionId }) else { return "this agent" }
        let project = ProjectNaming.name(forCwd: s.cwd)
        let title = s.aiTitle ?? s.displayName
        return "\(project) · \(title)"
    }

    /// Every session except the source — can't hand off to yourself.
    private var candidates: [AgentSession] {
        manager.sessions.filter { $0.id != sourceSessionId }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(0.4)
            if candidates.isEmpty {
                emptyState
            } else {
                content
            }
        }
        .frame(width: 460)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            if draft.isEmpty { draft = initialPayload }
            if selectedTargetId == nil { selectedTargetId = candidates.first?.id }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.turn.up.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.brandOrange)
            VStack(alignment: .leading, spacing: 1) {
                Text("Send to another agent")
                    .font(.system(size: 13, weight: .semibold))
                Text("From \(sourceLabel)")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button {
                onClose()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "person.2")
                .font(.system(size: 20, weight: .light))
                .foregroundStyle(.tertiary)
            Text("No other agents to send to")
                .font(.system(size: 12, weight: .semibold))
            Text("Spawn another session (⌘N or ⌘T) to hand off work to it.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(24)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Target picker
            VStack(alignment: .leading, spacing: 4) {
                Text("Target")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.5)
                    .foregroundStyle(.secondary)
                Picker("Target", selection: $selectedTargetId) {
                    ForEach(candidates) { c in
                        Text(targetLabel(c)).tag(Optional(c.id))
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }

            // Prompt editor
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Prompt")
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(0.5)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Reset to message text") {
                        draft = initialPayload
                    }
                    .buttonStyle(.borderless)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                }
                TextEditor(text: $draft)
                    .font(.system(size: 12.5))
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .frame(minHeight: 100, maxHeight: 200)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.primary.opacity(0.04))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(Color.primary.opacity(0.12), lineWidth: 0.5)
                    )
            }

            HStack(spacing: 8) {
                Spacer()
                Button("Stage on target") {
                    runHandOff(autoSend: false)
                }
                .controlSize(.regular)
                .help("Drops a pending hand-off banner on the target so its owner can review before it fires.")
                Button {
                    runHandOff(autoSend: true)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "paperplane.fill")
                            .font(.system(size: 10, weight: .semibold))
                        Text("Send now")
                    }
                }
                .keyboardShortcut(.return, modifiers: [.command])
                .controlSize(.regular)
                .buttonStyle(.borderedProminent)
                .tint(Color.brandOrange)
                .disabled(selectedTargetId == nil || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private func targetLabel(_ s: AgentSession) -> String {
        let project = ProjectNaming.name(forCwd: s.cwd)
        let title = s.aiTitle ?? s.displayName
        let status = statusLabel(for: s.status)
        return "\(project) · \(title) — \(status)"
    }

    private func statusLabel(for status: AgentStatus) -> String {
        switch status {
        case .idle:    return "Idle"
        case .running: return "Working"
        case .waiting: return "Waiting"
        case .error:   return "Error"
        }
    }

    private func runHandOff(autoSend: Bool) {
        guard let target = selectedTargetId else { return }
        manager.handOff(from: sourceSessionId,
                        to: target,
                        prompt: draft.trimmingCharacters(in: .whitespacesAndNewlines),
                        autoSend: autoSend)
        onClose()
    }
}
