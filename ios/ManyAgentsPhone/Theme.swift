import SwiftUI

/// The Mac app's palette, so the two read as one product rather than a
/// companion app someone bolted on. Values match ManyAgents' own brand
/// orange and its dark window/raised-surface pair.
enum Theme {
    static let orange   = Color(red: 0.85, green: 0.40, blue: 0.20)
    static let canvas   = Color(red: 0.071, green: 0.071, blue: 0.078)   // window background
    static let raised   = Color(red: 0.125, green: 0.125, blue: 0.137)   // cards, rows
    static let hairline = Color.white.opacity(0.08)
    static let text     = Color(white: 0.94)
    static let dim      = Color(white: 0.62)

    /// Same status colours as the Mac's dots, so a glance means the same
    /// thing on either screen.
    static func status(_ s: String) -> Color {
        switch s {
        case "running": return orange
        case "waiting": return Color(red: 0.35, green: 0.62, blue: 1.0)
        case "error":   return Color(red: 0.90, green: 0.30, blue: 0.30)
        default:        return Color(white: 0.45)
        }
    }
}

/// Card surface used for rows and sections — one rounded rectangle with a
/// hairline, matching the Mac's project rows.
struct CardBackground: ViewModifier {
    var highlighted: Bool = false
    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(highlighted ? Theme.orange.opacity(0.12) : Theme.raised)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(highlighted ? Theme.orange.opacity(0.35) : Theme.hairline,
                                  lineWidth: 0.5)
            )
    }
}

extension View {
    func card(highlighted: Bool = false) -> some View {
        modifier(CardBackground(highlighted: highlighted))
    }
}
