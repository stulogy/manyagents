import SwiftUI

/// Inline card rendered when claude emits a tool_use block. Adapts its
/// presentation per tool — Bash gets the command, Edit gets the file path
/// and (when present) old/new diff, Read/Grep get a one-line target.
struct ToolUseCard: View {
    let toolName: String
    let input: [String: AnyCodable]
    /// Set for file-edit tools (Edit/Write/…) once their result has
    /// arrived: `true` when the edit succeeded — the verbose
    /// "…updated successfully" result row is suppressed and folded into a
    /// ✓ here instead. `nil` for everything else (pending, errors, or
    /// non-edit tools, which keep their own result row).
    var succeeded: Bool? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            if !brief.isEmpty {
                Text(brief)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.primary.opacity(0.85))
                    .lineLimit(6)
                    .multilineTextAlignment(.leading)
                    .textSelection(.enabled)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(toolTint.opacity(0.35), lineWidth: 1)
        )
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: iconName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(toolTint)
            Text(toolName)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(toolTint)
            Spacer(minLength: 0)
            if succeeded == true {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.green)
                    .help("Updated successfully")
            }
        }
    }

    private var iconName: String {
        switch toolName {
        case "Bash": return "terminal"
        case "Read": return "doc.text"
        case "Edit", "MultiEdit": return "pencil.line"
        case "Write": return "doc.badge.plus"
        case "Grep": return "magnifyingglass"
        case "Glob": return "folder.badge.questionmark"
        case "WebFetch", "WebSearch": return "globe"
        case "Task", "Agent": return "sparkles"
        case "ToolSearch": return "magnifyingglass.circle"
        default: return "wrench.and.screwdriver"
        }
    }

    private var toolTint: Color {
        switch toolName {
        case "Bash": return .blue
        case "Edit", "MultiEdit", "Write": return .orange
        case "Read", "Grep", "Glob": return .cyan
        case "Task": return .purple
        default: return .gray
        }
    }

    /// One-line (or short-multi-line) human-readable description of the call.
    private var brief: String {
        switch toolName {
        case "Bash":
            return input["command"]?.stringValue ?? ""
        case "Read", "Edit", "MultiEdit", "Write":
            return input["file_path"]?.stringValue ?? ""
        case "Grep":
            let pattern = input["pattern"]?.stringValue ?? ""
            let path = input["path"]?.stringValue ?? ""
            return path.isEmpty ? pattern : "\(pattern)  in  \(path)"
        case "Glob":
            return input["pattern"]?.stringValue ?? ""
        case "WebFetch":
            return input["url"]?.stringValue ?? ""
        case "WebSearch":
            return input["query"]?.stringValue ?? ""
        case "Task", "Agent":
            return input["description"]?.stringValue
                ?? input["prompt"]?.stringValue
                ?? ""
        case "ToolSearch":
            return input["query"]?.stringValue ?? ""
        default:
            // Unknown tool — surface its first string input rather than
            // rendering a naked card with just the name. Picks the
            // most-commonly-meaningful key when present, otherwise just
            // the first non-empty string value.
            let priority = ["query", "url", "command", "file_path", "path", "pattern", "prompt", "description"]
            for k in priority {
                if let v = input[k]?.stringValue, !v.isEmpty { return v }
            }
            return input.values.compactMap { $0.stringValue }.first(where: { !$0.isEmpty }) ?? ""
        }
    }
}
