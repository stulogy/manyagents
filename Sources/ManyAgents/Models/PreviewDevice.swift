import Foundation
import CoreGraphics

/// What the preview pretends to be.
///
/// Responsive work was the one thing the panel couldn't help with: a
/// desktop-width WKWebView claiming to be a Mac gets the desktop layout, so
/// checking a phone breakpoint meant leaving the app for a real device or a
/// headless browser the user can't see.
///
/// Two halves have to agree or the page lies. The WIDTH drives CSS media
/// queries; the USER AGENT drives everything the server and the app's own
/// JS decide — SSR device detection, `navigator.userAgent` branches, and
/// touch-vs-pointer behaviour. Setting only the width gets you a narrow
/// desktop page, which is exactly the bug people ship.
enum PreviewDevice: String, CaseIterable, Identifiable {
    case desktop, iPhone, iPad

    var id: String { rawValue }

    var label: String {
        switch self {
        case .desktop: return "Desktop"
        case .iPhone:  return "iPhone"
        case .iPad:    return "iPad"
        }
    }

    var icon: String {
        switch self {
        case .desktop: return "display"
        case .iPhone:  return "iphone"
        case .iPad:    return "ipad"
        }
    }

    /// CSS width the page is laid out at. nil means "fill the panel".
    /// iPhone 15/16 Pro is 393pt; iPad portrait is 820pt — both the real
    /// logical widths, so a breakpoint at 768 or 430 behaves as it will on
    /// the device rather than at some rounded-off approximation.
    var width: CGFloat? {
        switch self {
        case .desktop: return nil
        case .iPhone:  return 393
        case .iPad:    return 820
        }
    }

    /// Height to letterbox to, so the viewport aspect is honest. nil fills.
    var height: CGFloat? {
        switch self {
        case .desktop: return nil
        case .iPhone:  return 852
        case .iPad:    return 1180
        }
    }

    /// Mobile Safari's own string. nil leaves WebKit's default, which
    /// already identifies as Safari on macOS.
    ///
    /// The version numbers matter less than the tokens: "iPhone", "Mobile",
    /// and the absence of "Macintosh" are what every device-detection
    /// library actually keys on.
    var userAgent: String? {
        switch self {
        case .desktop:
            return nil
        case .iPhone:
            return "Mozilla/5.0 (iPhone; CPU iPhone OS 18_5 like Mac OS X) "
                 + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Mobile/15E148 Safari/604.1"
        case .iPad:
            return "Mozilla/5.0 (iPad; CPU OS 18_5 like Mac OS X) "
                 + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Mobile/15E148 Safari/604.1"
        }
    }

    /// How the page describes itself back to an agent, so a screenshot of a
    /// phone layout isn't mistaken for a broken desktop one.
    var describedForAgent: String {
        switch self {
        case .desktop: return "desktop"
        case .iPhone:  return "iPhone (393×852, mobile Safari)"
        case .iPad:    return "iPad (820×1180, mobile Safari)"
        }
    }
}
