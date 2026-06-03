import SwiftUI

/// Semantic typography. Apple's New York serif (`.serif`) for assistant
/// prose mirrors the claude.ai web app's "Tiempos"-style feel — literary,
/// breathable, easy on the eyes for long responses. SF Pro for everything
/// else (UI chrome, user prompts, code). Centralized here so the look stays
/// consistent across views.
enum AppFont {
    /// Long-form assistant prose. SF Pro Text at a comfortable reading
    /// size — same family as the macOS system text everywhere else, so
    /// the conversation reads as a native chat surface, not a
    /// document. Slight negative tracking sharpens the spacing.
    static func assistantProse(_ size: CGFloat = 14.5) -> Font {
        .system(size: size, weight: .regular, design: .default)
    }

    /// User-side text. Same family as assistant prose so the conversation
    /// reads as one continuous thread.
    static func userProse(_ size: CGFloat = 14.5) -> Font {
        .system(size: size, weight: .regular, design: .default)
    }

    /// Composer input.
    static func composer(_ size: CGFloat = 14) -> Font {
        .system(size: size, weight: .regular, design: .default)
    }

    /// Inline status / metadata lines.
    static func caption(_ size: CGFloat = 11.5) -> Font {
        .system(size: size, weight: .medium, design: .default)
    }

    /// Code / monospaced.
    static func mono(_ size: CGFloat = 12.5) -> Font {
        .system(size: size, weight: .regular, design: .monospaced)
    }

    /// Headings (rounded for warmth, matches sidebar brand).
    static func heading(_ size: CGFloat = 15) -> Font {
        .system(size: size, weight: .semibold, design: .rounded)
    }
}

/// Reading defaults that pair with the serif body text.
extension View {
    /// Apply the breathing-room treatment to a block of assistant prose:
    /// generous line height, subtle tracking, selection enabled.
    func assistantTextStyle() -> some View {
        self
            .font(AppFont.assistantProse())
            .lineSpacing(4)
            .tracking(-0.2)
            .textSelection(.enabled)
            .multilineTextAlignment(.leading)
    }

    func userTextStyle() -> some View {
        self
            .font(AppFont.userProse())
            .lineSpacing(3)
            .tracking(-0.2)
            .textSelection(.enabled)
            .multilineTextAlignment(.leading)
    }
}
