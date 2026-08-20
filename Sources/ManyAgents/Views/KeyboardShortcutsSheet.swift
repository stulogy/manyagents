import SwiftUI

/// Reference card listing every keyboard shortcut ManyAgents supports.
/// Triggered from Help → Keyboard Shortcuts (⌘/).
struct KeyboardShortcutsSheet: View {
    let onClose: () -> Void

    private struct Shortcut: Identifiable {
        let id = UUID()
        let keys: [String]
        let description: String
    }

    private struct Section: Identifiable {
        let id = UUID()
        let title: String
        let shortcuts: [Shortcut]
    }

    private let sections: [Section] = [
        Section(title: "Sessions", shortcuts: [
            Shortcut(keys: ["⌘", "N"], description: "New session (pick a folder)"),
            Shortcut(keys: ["⌘", "T"], description: "New tab in the current project"),
            Shortcut(keys: ["⌘", "W"], description: "Close current tab (asks for confirmation)"),
            Shortcut(keys: ["⌘", "⇧", "R"], description: "Resume previous sessions…"),
        ]),
        Section(title: "Navigation", shortcuts: [
            Shortcut(keys: ["⌘", "`"], description: "Cycle to the next project"),
            Shortcut(keys: ["⌘", "⇧", "`"], description: "Cycle to the next tab in the current project"),
            Shortcut(keys: ["⌘", "⇧", "L"], description: "Toggle card / list view"),
        ]),
        Section(title: "Composer", shortcuts: [
            Shortcut(keys: ["↩"], description: "Send — queues behind a running turn"),
            Shortcut(keys: ["⌘", "↩"], description: "Send NOW — into the running turn, ahead of the queue"),
            Shortcut(keys: ["⇧", "↩"], description: "New line"),
            Shortcut(keys: ["⌘", "V"], description: "Paste — includes screenshots & images"),
        ]),
        Section(title: "AskUserQuestion picker", shortcuts: [
            Shortcut(keys: ["1", "–", "9"], description: "Pick option by number"),
        ]),
        Section(title: "Help", shortcuts: [
            Shortcut(keys: ["⌘", "/"], description: "Show this sheet"),
            Shortcut(keys: ["⌘", ","], description: "Settings"),
            Shortcut(keys: ["⌘", "Q"], description: "Quit ManyAgents"),
        ])
    ]

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(sections) { section in
                        sectionView(section)
                    }
                }
                .padding(20)
            }
            footer
        }
        .frame(width: 460, height: 540)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "command")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Color.brandOrange)
            Text("Keyboard Shortcuts")
                .font(.system(size: 16, weight: .semibold))
            Spacer()
            Button {
                onClose()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(
            Color(nsColor: .windowBackgroundColor).opacity(0.6)
        )
        .overlay(
            Rectangle()
                .fill(Color.primary.opacity(0.10))
                .frame(height: 0.5)
                .frame(maxHeight: .infinity, alignment: .bottom)
        )
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Image(systemName: "info.circle")
                .font(.system(size: 10))
            Text("Missing one you'd like? Open an issue at github.com/stulogy/manyagents.")
                .font(.system(size: 11))
        }
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .overlay(
            Rectangle()
                .fill(Color.primary.opacity(0.10))
                .frame(height: 0.5)
                .frame(maxHeight: .infinity, alignment: .top)
        )
    }

    @ViewBuilder
    private func sectionView(_ section: Section) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(section.title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(.secondary)
            VStack(spacing: 4) {
                ForEach(section.shortcuts) { sc in
                    HStack(spacing: 10) {
                        Text(sc.description)
                            .font(.system(size: 12.5))
                            .foregroundStyle(.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        HStack(spacing: 4) {
                            ForEach(Array(sc.keys.enumerated()), id: \.offset) { _, k in
                                Text(k)
                                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(
                                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                                            .fill(Color.primary.opacity(0.08))
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                                            .stroke(Color.primary.opacity(0.15), lineWidth: 0.5)
                                    )
                                    .foregroundStyle(.primary)
                            }
                        }
                    }
                }
            }
        }
    }
}
