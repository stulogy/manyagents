import SwiftUI

@main
struct ManyAgentsPhoneApp: App {
    @StateObject private var link = MacLink()
    @StateObject private var voice = Voice.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(link)
                .environmentObject(voice)
                // A pairing link pairs the app on tap — handy on the phone
                // (AirDrop the code to yourself) and the only way in on a
                // simulator, which has no camera to scan with.
                .onOpenURL { url in
                    if let p = MacLink.Pairing.parse(url.absoluteString) { link.pairing = p }
                    #if DEBUG
                    // Debug builds only: `xcrun simctl openurl booted
                    // "manyagents://voicetest"` exercises the whole speech
                    // path headlessly. Voice bugs are silent by
                    // definition, and tapping through three screens to
                    // reproduce one is how they stay unfixed.
                    if url.host == "voicetest" || url.path == "voicetest" {
                        VoiceDiagnostics.run(url: url)
                    }
                    #endif
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { link.appDidBecomeActive() }
                }
                .tint(Theme.orange)
                .preferredColorScheme(.dark)
        }
    }
}

struct RootView: View {
    @EnvironmentObject var link: MacLink

    var body: some View {
        if link.pairing == nil {
            PairView()
        } else {
            BoardView()
        }
    }
}
