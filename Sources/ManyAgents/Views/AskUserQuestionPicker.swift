import SwiftUI

/// Inline picker rendered between the conversation and the composer when
/// claude is mid-turn and has called AskUserQuestion. Mirrors the Claude
/// Code TUI experience: a clear question, option rows with label +
/// description, click to send the choice back as a tool_result. The
/// picker disappears the moment an answer goes out.
struct AskUserQuestionPicker: View {
    @ObservedObject var session: AgentSession
    @State private var selected: Set<String> = []
    @State private var customDraft: String = ""

    var body: some View {
        if let q = session.pendingAskUserQuestion {
            VStack(alignment: .leading, spacing: 12) {
                header(for: q)
                optionList(q)
                if q.multiSelect {
                    submitMultiButton(q)
                }
                customRow(q)
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.brandOrange.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.brandOrange.opacity(0.35), lineWidth: 1)
            )
            // Pin selection state to the toolUseId so switching questions
            // (or another picker landing) resets it.
            .id(q.toolUseId)
            .onChange(of: q.toolUseId) { _, _ in
                selected.removeAll()
                customDraft = ""
            }
        }
    }

    @ViewBuilder
    private func header(for q: AgentSession.AskState) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let h = q.header, !h.isEmpty {
                Text(h.uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(Color.brandOrange.opacity(0.85))
            }
            Text(q.question)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.leading)
        }
    }

    @ViewBuilder
    private func optionList(_ q: AgentSession.AskState) -> some View {
        VStack(spacing: 6) {
            ForEach(Array(q.options.enumerated()), id: \.element.id) { index, opt in
                Button {
                    if q.multiSelect {
                        if selected.contains(opt.label) {
                            selected.remove(opt.label)
                        } else {
                            selected.insert(opt.label)
                        }
                    } else {
                        session.answerQuestion(opt.label)
                    }
                } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Text("\(index + 1).")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 18, alignment: .leading)
                            .padding(.top, 2)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(opt.label)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(.primary)
                                .multilineTextAlignment(.leading)
                            if let d = opt.description, !d.isEmpty {
                                Text(d)
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.leading)
                            }
                        }
                        Spacer(minLength: 0)
                        if q.multiSelect {
                            Image(systemName: selected.contains(opt.label)
                                  ? "checkmark.square.fill"
                                  : "square")
                                .font(.system(size: 14))
                                .foregroundStyle(selected.contains(opt.label)
                                                 ? Color.brandOrange : .secondary)
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color(nsColor: .controlBackgroundColor).opacity(0.6))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color.primary.opacity(0.10), lineWidth: 0.5)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")),
                                  modifiers: [])
            }
        }
    }

    @ViewBuilder
    private func submitMultiButton(_ q: AgentSession.AskState) -> some View {
        Button {
            let answer = q.options
                .map(\.label)
                .filter { selected.contains($0) }
                .joined(separator: ", ")
            guard !answer.isEmpty else { return }
            session.answerQuestion(answer)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "checkmark.circle.fill")
                Text("Send selection")
            }
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.brandOrange.opacity(selected.isEmpty ? 0.3 : 1))
            )
            .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .disabled(selected.isEmpty)
    }

    @ViewBuilder
    private func customRow(_ q: AgentSession.AskState) -> some View {
        HStack(spacing: 8) {
            TextField("Or type your own answer…", text: $customDraft)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color(nsColor: .textBackgroundColor).opacity(0.5))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(Color.primary.opacity(0.10), lineWidth: 0.5)
                )
                .onSubmit { sendCustom() }
            Button {
                sendCustom()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(customDraft.trimmingCharacters(in: .whitespaces).isEmpty
                                     ? Color.secondary.opacity(0.5)
                                     : Color.brandOrange)
            }
            .buttonStyle(.plain)
            .disabled(customDraft.trimmingCharacters(in: .whitespaces).isEmpty)
            .help("Send free-form answer")
        }
    }

    private func sendCustom() {
        let trimmed = customDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        session.answerQuestion(trimmed)
    }
}
