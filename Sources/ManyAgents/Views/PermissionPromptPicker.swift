import SwiftUI

/// Banner that surfaces a `permission_prompt` request from claude
/// (sensitive-path writes, settings changes, etc.) as an Allow / Deny
/// choice. Stays on screen until the user picks one; the relay's
/// `awaitPermissionDecision` is blocked until then.
struct PermissionPromptPicker: View {
    @ObservedObject var session: AgentSession

    var body: some View {
        if let pending = session.pendingPermission {
            VStack(alignment: .leading, spacing: 10) {
                header(pending)
                inputPreview(pending)
                buttons(pending)
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.brandOrange.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.brandOrange.opacity(0.40), lineWidth: 1)
            )
        }
    }

    private func header(_ p: AgentSession.PendingPermission) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.shield.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.brandOrange)
            VStack(alignment: .leading, spacing: 1) {
                Text("Permission required")
                    .font(.system(size: 13, weight: .semibold))
                Text("Claude wants to run ")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    + Text(p.toolName)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(.primary)
            }
            Spacer()
        }
    }

    /// Compact "what would happen" block — the most likely-relevant
    /// keys (file_path / command / url / pattern) up top, then the
    /// rest in a small expandable details row.
    private func inputPreview(_ p: AgentSession.PendingPermission) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(headlineKeys, id: \.self) { key in
                if let val = p.toolInput[key]?.stringValue, !val.isEmpty {
                    keyValueRow(key: key, value: val)
                }
            }
            if hasNonHeadlineKeys(p) {
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(otherKeys(p), id: \.self) { key in
                            if let val = p.toolInput[key]?.stringValue {
                                keyValueRow(key: key, value: val)
                            }
                        }
                    }
                    .padding(.top, 4)
                } label: {
                    Text("Other inputs")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.tertiary)
                }
                .controlSize(.small)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
    }

    private let headlineKeys = ["file_path", "path", "command", "url", "pattern"]

    private func hasNonHeadlineKeys(_ p: AgentSession.PendingPermission) -> Bool {
        p.toolInput.keys.contains(where: { !headlineKeys.contains($0) })
    }
    private func otherKeys(_ p: AgentSession.PendingPermission) -> [String] {
        p.toolInput.keys.filter { !headlineKeys.contains($0) }.sorted()
    }

    private func keyValueRow(key: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(key)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .leading)
            Text(value)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(.primary)
                .lineLimit(3)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func buttons(_ p: AgentSession.PendingPermission) -> some View {
        HStack(spacing: 8) {
            Spacer(minLength: 0)
            Button {
                session.respondToPermission(allow: false, message: "User denied via ManyAgents.")
            } label: {
                Text("Deny")
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 5)
            }
            .keyboardShortcut(.cancelAction)

            Button {
                session.respondToPermission(allow: true)
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .semibold))
                    Text("Allow")
                        .font(.system(size: 12, weight: .semibold))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 5)
                .background(
                    Capsule().fill(Color.brandOrange)
                )
                .foregroundStyle(Color.black.opacity(0.9))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.return, modifiers: [.command])
        }
    }
}
