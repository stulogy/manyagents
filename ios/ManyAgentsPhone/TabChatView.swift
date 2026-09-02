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
    private var previewRuns: PreviewRuns { PreviewRuns.build(messages) }

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
                            MessageBubble(message: m, preview: previewRuns).id(m.id)
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
                .environmentObject(link)
                .environmentObject(Voice.shared)
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

/// Which preview blocks to hide, and how many steps the survivor stands
/// for. Keyed "<seq>-<blockIndex>" because the phone's blocks carry no
/// tool_use id — position is the only handle there is.
struct PreviewRuns {
    var hidden: Set<String> = []
    var steps: [String: Int] = [:]

    static func key(_ seq: Int, _ index: Int) -> String { "\(seq)-\(index)" }

    /// Driving a browser is a look-act-look loop: one "check this page" is a
    /// dozen calls. On a phone that filled the screen with the mechanics of
    /// looking, and away from the Mac the only question is whether anything
    /// is happening at all — so the run collapses to its last call.
    static func build(_ messages: [MacLink.Msg]) -> PreviewRuns {
        var out = PreviewRuns()
        var run: [String] = []

        func close() {
            guard let last = run.last else { return }
            out.steps[last] = run.count
            for k in run.dropLast() { out.hidden.insert(k) }
            run = []
        }

        for m in messages {
            guard m.role != "user" else { close(); continue }
            for (i, block) in m.blocks.enumerated() {
                let key = Self.key(m.seq, i)
                switch block {
                case .tool(let name, _) where ToolNaming.isPreviewTool(name):
                    run.append(key)
                case .toolError where !run.isEmpty:
                    // A failed step inside a run — part of the same action.
                    out.hidden.insert(key)
                default:
                    close()
                }
            }
        }
        close()
        return out
    }
}

struct MessageBubble: View {
    let message: MacLink.Msg
    var preview = PreviewRuns()

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
                ForEach(Array(message.blocks.enumerated()), id: \.offset) { i, block in
                    let key = PreviewRuns.key(message.seq, i)
                    if preview.hidden.contains(key) {
                        EmptyView()
                    } else {
                    switch block {
                    case .text(let t):
                        Markdown(raw: t)
                    case .tool(let name, let detail):
                        // A collapsed run shows its step count and drops the
                        // selector — which selector was tried is the least
                        // interesting thing about it.
                        let steps = preview.steps[key] ?? 1
                        ToolChip(name: name,
                                 detail: steps > 1 ? "" : detail,
                                 steps: steps)
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
    /// Steps folded into this chip when it stands for a run of preview
    /// calls. 1 means it is just itself.
    var steps: Int = 1

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
            Text(title)
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

    /// Read as words, never as the wire name. The phone showed a column of
    /// `mcp__manyagents__preview_look` with no way to tell whether anything
    /// was happening — which, away from the Mac, is the only question.
    private var title: String {
        if steps > 1 { return "Drove the preview · \(steps) steps" }
        return ToolNaming.cardTitle(for: name)
    }

    private var icon: String {
        if ToolNaming.isPreviewTool(name) { return "globe" }
        if ToolNaming.isManyAgents(name) { return "brain.head.profile" }
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
