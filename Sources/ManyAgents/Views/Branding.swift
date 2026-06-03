import SwiftUI

/// Brand surface treatment used by the sidebar logo chip and the New Session
/// button. Matches ClaudeDeck's BrandGradient.warm exactly so the two apps
/// read as a family.
enum BrandGradient {
    static var warm: LinearGradient {
        LinearGradient(
            colors: [
                Color.brandOrange,
                Color.brandOrange.opacity(0.82)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

/// Top-level layout choice: tabs+conversation in the right pane, or a grid
/// of every agent across every project.
enum WorkspaceMode: String { case row, card }

extension Color {
    /// Warm orange — the primary brand tint. Same sRGB triplet ClaudeDeck
    /// uses for its AccentColor.colorset (#E25B27 light / #F2724F dark).
    /// We define it explicitly here because relying on the asset catalog's
    /// AccentColor sometimes falls through to the system blue tint when
    /// SwiftUI hasn't picked the catalog entry up yet.
    static let brandOrange = Color(.sRGB, red: 0.886, green: 0.357, blue: 0.153, opacity: 1)

    /// Cool complement to the warm orange. Used for "this is selected"
    /// state — active tab outline, active project row tint. Identical to
    /// ClaudeDeck's Color.activeHighlight.
    static let activeHighlight = Color(red: 0.27, green: 0.46, blue: 0.94)
}
