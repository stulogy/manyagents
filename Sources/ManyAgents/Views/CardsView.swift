import SwiftUI

/// At-a-glance grid of every agent across every project. Mirrors
/// ClaudeDeck's AgentCardsGrid so the two apps share the same overview UX.
struct AgentCardsGrid: View {
    @EnvironmentObject var manager: AgentManager
    let onPick: (AgentSession) -> Void

    private static let columns = [GridItem(.adaptive(minimum: 280, maximum: 360), spacing: 14)]

    private var sortedSessions: [AgentSession] {
        let order: (AgentStatus) -> Int = { s in
            switch s {
            case .waiting: return 0
            case .running: return 1
            case .idle:    return 2
            case .error:   return 3
            }
        }
        return manager.sessions.sorted { a, b in
            if order(a.status) != order(b.status) {
                return order(a.status) < order(b.status)
            }
            return a.messages.count > b.messages.count
        }
    }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: Self.columns, spacing: 14) {
                ForEach(sortedSessions) { session in
                    AgentCard(session: session)
                        .onTapGesture { onPick(session) }
                }
            }
            .padding(14)
        }
    }
}

private struct AgentCard: View {
    @ObservedObject var session: AgentSession
    @State private var hover = false

    private var title: String {
        if let t = session.aiTitle, !t.isEmpty { return t }
        switch session.status {
        case .waiting: return "Waiting on you"
        case .running: return "Working…"
        case .idle:    return "Ready"
        case .error:   return "Error"
        }
    }

    private var statusTint: Color {
        switch session.status {
        case .waiting: return .orange
        case .running: return Color.activeHighlight
        case .idle:    return .secondary
        case .error:   return .red
        }
    }

    private var statusLabel: String {
        switch session.status {
        case .waiting: return "Waiting on you"
        case .running: return "Working"
        case .idle:    return "Idle"
        case .error:   return "Error"
        }
    }

    private var lastUserText: String? {
        for msg in session.messages.reversed() where msg.role == .user {
            let t = msg.flatText
            if !t.isEmpty { return t }
        }
        return nil
    }

    private var lastAssistantText: String? {
        for msg in session.messages.reversed() where msg.role == .assistant {
            let t = msg.flatText
            if !t.isEmpty { return t }
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "folder")
                    .font(.system(size: 10, weight: .semibold))
                Text(ProjectNaming.name(forCwd: session.cwd))
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(.secondary)

            Text(title)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .lineLimit(2)
                .multilineTextAlignment(.leading)

            statusChip

            if let prompt = lastUserText {
                Text(prompt)
                    .font(.system(size: 12))
                    .foregroundStyle(.primary.opacity(0.85))
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let reply = lastAssistantText, session.status != .idle {
                Text(reply)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 0)

            HStack(spacing: 10) {
                if session.totalInputTokens + session.totalOutputTokens > 0 {
                    Label("\(session.totalInputTokens + session.totalOutputTokens) tok",
                          systemImage: "circle.grid.3x3")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                        .labelStyle(.titleAndIcon)
                }
                Spacer(minLength: 0)
                Text("\(session.messages.count) msgs")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 168, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(hover ? 1 : 0.7))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(hover ? Color.brandOrange.opacity(0.45) : Color.primary.opacity(0.08),
                        lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(hover ? 0.18 : 0.08), radius: hover ? 10 : 4, x: 0, y: 2)
        .onHover { hover = $0 }
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .animation(.easeInOut(duration: 0.12), value: hover)
    }

    private var statusChip: some View {
        HStack(spacing: 5) {
            if session.status == .running {
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.7)
                    .frame(width: 8, height: 8)
            } else {
                Circle()
                    .fill(statusTint)
                    .frame(width: 7, height: 7)
            }
            Text(statusLabel)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(statusTint)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(statusTint.opacity(0.12)))
    }
}
