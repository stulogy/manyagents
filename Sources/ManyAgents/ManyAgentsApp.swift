import SwiftUI
import AppKit
import Sparkle

/// Wraps Sparkle's updater so SwiftUI can drive a "Check for Updates…" menu
/// item and reflect whether a check is currently possible. Created lazily as a
/// @StateObject, so it never spins up in the headless MCP-subprocess mode
/// (that path exits in `init` before any view — hence no Sparkle there).
final class UpdaterViewModel: ObservableObject {
    @Published var canCheckForUpdates = false
    /// Bound to the Settings toggle. Mirrors Sparkle's own persisted setting.
    @Published var automaticallyChecksForUpdates: Bool {
        didSet {
            controller.updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates
        }
    }
    private let controller: SPUStandardUpdaterController

    init() {
        let controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        self.controller = controller
        self.automaticallyChecksForUpdates = controller.updater.automaticallyChecksForUpdates
        controller.updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }

    func checkForUpdates() { controller.updater.checkForUpdates() }
}

@main
struct ManyAgentsApp: App {
    @StateObject private var manager = AgentManager()
    @StateObject private var autoNamer = AutoNamer()
    @StateObject private var readiness = ClaudeReadiness()
    @StateObject private var updater = UpdaterViewModel()
    @State private var restored = false

    init() {
        // Same binary, two modes. When `claude` re-invokes us as the
        // MCP subprocess for a coordinator session, the CLI args carry
        // --mcp-stdio + the relay socket + an auth token; we skip
        // SwiftUI entirely and run the JSON-RPC MCP loop until stdin
        // closes. The SwiftUI scene below never materialises in this
        // mode because we exit() out of run() before App.body fires.
        if let args = MCPStdioServer.parseArgs(CommandLine.arguments) {
            MCPStdioServer.run(args)
        }
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
                    manager.loadPendingSnapshot()
                    autoNamer.attach(manager: manager)
                    // Register the notification delegate + request permission
                    // so "agent finished" banners can fire.
                    NotificationService.shared.bootstrap()
                }
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: true))
        .defaultSize(width: 1240, height: 820)
        .commands {
            // "Check for Updates…" in the app menu, right under About.
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { updater.checkForUpdates() }
                    .disabled(!updater.canCheckForUpdates)
            }
            // File menu additions — keep the sidebar's New Session ⌘N
            // working by adding via after-newItem rather than replacing.
            CommandGroup(after: .textEditing) {
                Button("Find…") {
                    NotificationCenter.default.post(name: .maFind, object: nil)
                }
                .keyboardShortcut("f", modifiers: .command)
            }
            CommandGroup(after: .newItem) {
                Button("New Tab in Project") {
                    NotificationCenter.default.post(name: .maNewTab, object: nil)
                }
                .keyboardShortcut("t", modifiers: .command)
                Divider()
                Button("Close Tab") {
                    NotificationCenter.default.post(name: .maCloseTab, object: nil)
                }
                .keyboardShortcut("w", modifiers: .command)
            }
            CommandMenu("Session") {
                Button("Resume Previous Sessions…") {
                    manager.loadPendingSnapshot()
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                Divider()
                Button("Next Project") {
                    NotificationCenter.default.post(name: .maCycleProject, object: nil)
                }
                .keyboardShortcut("`", modifiers: .command)
                Button("Next Tab in Project") {
                    NotificationCenter.default.post(name: .maCycleTab, object: nil)
                }
                .keyboardShortcut("`", modifiers: [.command, .shift])
                Divider()
                Button("Toggle Card / List View") {
                    NotificationCenter.default.post(name: .maToggleViewMode, object: nil)
                }
                .keyboardShortcut("l", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .help) {
                Button("Keyboard Shortcuts") {
                    NotificationCenter.default.post(name: .maShowShortcuts, object: nil)
                }
                .keyboardShortcut("/", modifiers: .command)
            }
        }

        // Usage history (⌘⇧U, also listed in the Window menu). Reads the
        // JSONL UsageLog that AgentSession appends to on every turn.
        Window("Usage", id: "usage") {
            UsageView()
        }
        .keyboardShortcut("u", modifiers: [.command, .shift])
        .defaultSize(width: 620, height: 560)

        // Standard macOS preferences window (⌘,). Houses notification + update settings.
        Settings {
            SettingsView()
                .environmentObject(updater)
        }
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

extension Notification.Name {
    static let maNewTab           = Notification.Name("ManyAgents.newTab")
    static let maCloseTab         = Notification.Name("ManyAgents.closeTab")
    static let maCycleProject     = Notification.Name("ManyAgents.cycleProject")
    static let maCycleTab         = Notification.Name("ManyAgents.cycleTab")
    static let maToggleViewMode   = Notification.Name("ManyAgents.toggleViewMode")
    static let maShowShortcuts    = Notification.Name("ManyAgents.showShortcuts")
    static let maFind             = Notification.Name("ManyAgents.find")
    static let maFocusSession     = Notification.Name("ManyAgents.focusSession")
}
