import SwiftUI
import AppKit

/// Shown when Claude Code isn't installed or isn't logged in. Walks the
/// user through the fix and rechecks on demand.
struct OnboardingView: View {
    @ObservedObject var readiness: ClaudeReadiness

    var body: some View {
        VStack(spacing: 22) {
            header
            VStack(alignment: .leading, spacing: 18) {
                step1
                step2
            }
            .frame(maxWidth: 520, alignment: .leading)

            Button {
                readiness.refresh()
            } label: {
                HStack(spacing: 6) {
                    if readiness.state == .checking {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                    Text(readiness.state == .checking ? "Checking…" : "I'm ready — check again")
                }
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(BrandGradient.warm)
                )
                .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .disabled(readiness.state == .checking)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(BrandGradient.warm)
                    .frame(width: 56, height: 56)
                Image(systemName: "rectangle.stack.fill")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(.white)
            }
            Text("Almost there.")
                .font(.system(size: 17, weight: .semibold, design: .rounded))
            Text("ManyAgents uses your Claude Code login — no separate API key needed.")
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 480)
        }
    }

    // MARK: - Steps

    @ViewBuilder
    private var step1: some View {
        StepRow(
            number: "1",
            title: "Install Claude Code",
            detail: "If you haven't already, install the CLI.",
            done: readiness.state != .missingBinary
        ) {
            ShellSnippet(command: "brew install anthropic/claude/claude")
            Link(destination: URL(string: "https://docs.claude.com/en/docs/claude-code/setup")!) {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.up.right.square")
                    Text("Installation guide")
                }
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Color.activeHighlight)
            }
        }
    }

    @ViewBuilder
    private var step2: some View {
        StepRow(
            number: "2",
            title: "Log in to Claude Code",
            detail: "Open Terminal and run the login command. It pops a browser tab where you sign in with your Claude Max account.",
            done: readiness.state == .ready
        ) {
            ShellSnippet(command: "claude login")
        }
    }
}

// MARK: - Pieces

private struct StepRow<Trailing: View>: View {
    let number: String
    let title: String
    let detail: String
    let done: Bool
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                Circle()
                    .fill(done ? Color.green.opacity(0.18) : Color.primary.opacity(0.08))
                    .frame(width: 28, height: 28)
                if done {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.green)
                } else {
                    Text(number)
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .strikethrough(done, color: .secondary)
                    .foregroundStyle(done ? .secondary : .primary)
                Text(detail)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                trailing()
            }
        }
    }
}

private struct ShellSnippet: View {
    let command: String

    var body: some View {
        HStack(spacing: 8) {
            Text("$ \(command)")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.primary.opacity(0.9))
                .textSelection(.enabled)
            Spacer(minLength: 0)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(6)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(Color.primary.opacity(0.08))
                    )
            }
            .buttonStyle(.plain)
            .help("Copy")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(Color.primary.opacity(0.10), lineWidth: 0.5)
        )
    }
}
