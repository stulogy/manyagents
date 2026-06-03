import SwiftUI
import AppKit

@main
struct ManyAgentsApp: App {
    @StateObject private var manager = AgentManager()
    @StateObject private var autoNamer = AutoNamer()
    @StateObject private var readiness = ClaudeReadiness()
    @State private var restored = false

    init() {
        Self.registerBundledFont()
    }

    var body: some Scene {
        WindowGroup("ManyAgents") {
            WorkspaceView()
                .environmentObject(manager)
                .environmentObject(readiness)
                .tint(Color.brandOrange)
                .frame(minWidth: 960, minHeight: 600)
                .onAppear {
                    guard !restored else { return }
                    restored = true
                    readiness.refresh()
                    manager.restorePersisted()
                    autoNamer.attach(manager: manager)
                }
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: true))
        .defaultSize(width: 1240, height: 820)
    }

    /// xcodegen flattens our Resources/Fonts folder into the bundle's
    /// Resources root, so macOS auto-registration via Info.plist's
    /// `ATSApplicationFontsPath` doesn't find the file. Registering manually
    /// is path-independent and idempotent — matches the technique
    /// ClaudeDeck uses so monospaced text reads identically across both apps.
    nonisolated(unsafe) private static var fontRegistered = false
    private static func registerBundledFont() {
        guard !fontRegistered else { return }
        fontRegistered = true
        guard let url = Bundle.main.url(forResource: "JetBrainsMono-Regular", withExtension: "ttf") else {
            return
        }
        var error: Unmanaged<CFError>?
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error)
    }
}
