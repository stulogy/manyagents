import SwiftUI

@main
struct ManyAgentsPhoneApp: App {
    @StateObject private var link = MacLink()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(link)
                // A pairing link pairs the app on tap — handy on the phone
                // (AirDrop the code to yourself) and the only way in on a
                // simulator, which has no camera to scan with.
                .onOpenURL { url in
                    if let p = MacLink.Pairing.parse(url.absoluteString) { link.pairing = p }
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
