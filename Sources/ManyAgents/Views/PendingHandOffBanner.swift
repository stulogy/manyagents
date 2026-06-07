import SwiftUI

/// Banner shown above the composer when another agent has staged a
/// hand-off onto this session (chain-mode not in YOLO, or manually
/// staged via "Send to → Stage on target"). Lets the user approve as-
/// sent, edit the prompt before sending, or dismiss the hand-off.
struct PendingHandOffBanner: View {
    @ObservedObject var session: AgentSession
    @EnvironmentObject var manager: AgentManager
    @State private var editing: Bool = false
    @State private var editDraft: String = ""

    var body: some View {
        if let pending = session.pendingHandOff {
            VStack(alignment: .leading, spacing: 8) {
                header(pending)
                if editing {
                    editor(pending)
                } else {
                    preview(pending)
                }
                footer(pending)
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.brandOrange.opacity(0.07))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.brandOrange.opacity(0.30), lineWidth: 1)
            )
        }
    }

    private func header(_ p: AgentSession.PendingHandOff) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.turn.up.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.brandOrange)
            Text("Hand-off from ")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.secondary)
                + Text("\(p.sourceProjectName) · \(p.sourceTitle)")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundColor(.primary)
            Spacer(minLength: 0)
            if p.hopsRemaining > 0 {
                Text("\(p.hopsRemaining) hop\(p.hopsRemaining == 1 ? "" : "s") left")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.tertiary)
            } else {
                Text("chain ends here")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func preview(_ p: AgentSession.PendingHandOff) -> some View {
        Text(p.payload)
            .font(.system(size: 12.5))
            .foregroundStyle(.primary.opacity(0.9))
            .lineLimit(5)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(0.04))
            )
    }

    private func editor(_ p: AgentSession.PendingHandOff) -> some View {
        TextEditor(text: $editDraft)
            .font(.system(size: 12.5))
            .scrollContentBackground(.hidden)
            .padding(8)
            .frame(minHeight: 100, maxHeight: 220)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(Color.primary.opacity(0.15), lineWidth: 0.5)
            )
            .onAppear {
                if editDraft.isEmpty { editDraft = p.payload }
            }
    }

    private func footer(_ p: AgentSession.PendingHandOff) -> some View {
        HStack(spacing: 8) {
            Button {
                manager.dismissPendingHandOff(on: session)
                editing = false
                editDraft = ""
            } label: {
                Text("Dismiss")
                    .font(.system(size: 11.5, weight: .medium))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)

            Spacer(minLength: 0)

            Button {
                if editing {
                    // Switching from edit → preview discards in-progress
                    // edits; surface that by syncing to original.
                    editDraft = p.payload
                    editing = false
                } else {
                    editDraft = p.payload
                    editing = true
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: editing ? "eye" : "square.and.pencil")
                        .font(.system(size: 9, weight: .semibold))
                    Text(editing ? "Preview" : "Edit")
                        .font(.system(size: 11.5, weight: .medium))
                }
            }
            .buttonStyle(.borderless)

            Button {
                manager.approvePendingHandOff(
                    on: session,
                    editedPrompt: editing ? editDraft : nil
                )
                editing = false
                editDraft = ""
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 10, weight: .semibold))
                    Text("Send")
                        .font(.system(size: 11.5, weight: .semibold))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    Capsule().fill(Color.brandOrange)
                )
                .foregroundStyle(Color.black.opacity(0.85))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.return, modifiers: [.command, .shift])
        }
    }
}
