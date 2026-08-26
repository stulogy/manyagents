import SwiftUI

/// One tab's conversation. You are talking to that agent directly — the
/// text here is the text on the Mac, not a summary of it.
struct TabChatView: View {
    let tabId: String
    @EnvironmentObject var link: MacLink
    @State private var draft = ""
    @FocusState private var composerFocused: Bool

    private var tab: MacLink.Tab? { link.board.first { $0.id == tabId } }
    private var messages: [MacLink.Msg] { link.messages[tabId] ?? [] }

    @State private var driveMode = false

    var body: some View {
        VStack(spacing: 0) {
            if let tab, tab.blocked != nil {
                BlockedBanner(tab: tab)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(messages) { m in
                            MessageBubble(message: m).id(m.id)
                        }
                        if tab?.isBusy == true {
                            WorkingRow().id("working")
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                }
                .onChange(of: messages.count) { _, _ in
                    withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                }
                .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
            }

            composer
        }
        .background(Theme.canvas)
        .navigationTitle(tab?.title ?? "Tab")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.canvas, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 12) {
                    if let tab {
                        StatusDot(status: tab.status, pulsing: tab.isBusy)
                    }
                    Button { driveMode = true } label: {
                        Image(systemName: "waveform.circle.fill")
                            .font(.system(size: 19))
                            .foregroundStyle(Theme.orange)
                    }
                    .accessibilityLabel("Talk to this tab")
                }
            }
        }
        .fullScreenCover(isPresented: $driveMode) {
            DriveModeView(tabId: tabId)
        }
        .onAppear { link.openTab(tabId) }
        .onDisappear { link.closeTab(tabId) }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Message…", text: $draft, axis: .vertical)
                .lineLimit(1...6)
                .textFieldStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(
                    RoundedRectangle(cornerRadius: 18)
                        .fill(Theme.raised)
                )
                .focused($composerFocused)

            Button {
                link.send(draft, to: tabId)
                draft = ""
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(draft.trimmingCharacters(in: .whitespaces).isEmpty
                                     ? Theme.dim : Theme.orange)
            }
            .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Theme.canvas)
    }
}

/// The two things that stop a tab dead: a permission request and a
/// question. Answering them from the phone is the whole point of being
/// able to reach the board from away.
struct BlockedBanner: View {
    let tab: MacLink.Tab
    @EnvironmentObject var link: MacLink
    @State private var answer = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "hand.raised.fill").font(.caption)
                Text(tab.blocked == "permission" ? "Waiting for your approval" : "It asked you something")
                    .font(.subheadline.weight(.semibold))
            }
            if tab.blocked == "permission" {
                if let tool = tab.permissionTool {
                    Text(tool)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 10) {
                    Button("Allow") { link.respondPermission(tab: tab.id, allow: true) }
                        .buttonStyle(.borderedProminent)
                    Button("Deny") { link.respondPermission(tab: tab.id, allow: false) }
                        .buttonStyle(.bordered)
                }
            } else {
                HStack(spacing: 8) {
                    TextField("Your answer", text: $answer)
                        .textFieldStyle(.roundedBorder)
                    Button("Send") {
                        link.answerQuestion(tab: tab.id, answer: answer)
                        answer = ""
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(answer.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Theme.orange.opacity(0.14))
                .overlay(RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Theme.orange.opacity(0.35), lineWidth: 0.5))
        )
    }
}

struct MessageBubble: View {
    let message: MacLink.Msg

    var body: some View {
        switch message.role {
        case "user":
            HStack {
                Spacer(minLength: 40)
                Text(message.text)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(RoundedRectangle(cornerRadius: 16).fill(Theme.orange.opacity(0.20)))
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        case "system":
            Text(message.text)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .center)
        default:
            VStack(alignment: .leading, spacing: 9) {
                ForEach(Array(message.blocks.enumerated()), id: \.offset) { _, block in
                    switch block {
                    case .text(let t):
                        Markdown(raw: t)
                    case .tool(let name, let detail):
                        ToolChip(name: name, detail: detail)
                    case .toolError(let t):
                        Text(t)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.red)
                            .lineLimit(6)
                    case .image:
                        Label("image", systemImage: "photo")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A tool call as one quiet line. On a laptop you want the payload; on a
/// phone you want to know it ran and move on.
struct ToolChip: View {
    let name: String
    let detail: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
            Text(name)
                .font(.system(size: 11, weight: .semibold))
            if !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(Capsule().fill(Theme.raised))
    }

    private var icon: String {
        switch name {
        case "Bash":                     return "terminal"
        case "Read", "Glob", "Grep":     return "doc.text.magnifyingglass"
        case "Write", "Edit":            return "square.and.pencil"
        case "WebFetch", "WebSearch":    return "globe"
        case "Task", "Agent":            return "person.2"
        default:                         return "wrench.and.screwdriver"
        }
    }
}

struct WorkingRow: View {
    @State private var on = false
    var body: some View {
        HStack(spacing: 7) {
            Circle().fill(Theme.orange).frame(width: 6, height: 6).opacity(on ? 0.3 : 1)
            Text("Working…").font(.caption).foregroundStyle(.secondary)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { on = true }
        }
    }
}
