import Foundation
import Network
import Combine

/// Thin wrapper around `NWPathMonitor`. Publishes whether the Mac
/// currently has a usable network path, and emits a one-shot signal
/// every time the connection comes back up after being down. The
/// auto-resumer in AgentManager subscribes to that signal to retry
/// any sessions that failed while offline.
@MainActor
final class NetworkMonitor: ObservableObject {
    static let shared = NetworkMonitor()

    @Published private(set) var isOnline: Bool = true
    /// Fires every off→on transition. Subscribers get the new
    /// online state (always true at the time of firing).
    let cameOnline = PassthroughSubject<Void, Never>()

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "manyagents.netmonitor")

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            // Hop to main so @Published mutations don't fire from a
            // background queue (SwiftUI hates that).
            DispatchQueue.main.async {
                guard let self else { return }
                let online = path.status == .satisfied
                let wasOnline = self.isOnline
                if online != wasOnline {
                    self.isOnline = online
                    if online {
                        self.cameOnline.send()
                    }
                }
            }
        }
        monitor.start(queue: queue)
    }
}
