import Foundation
import Combine
import CoreWLAN
import AppKit

/// Watches `NetworkMonitor` and tries to get Wi-Fi back when the path
/// goes away — the "I closed the lid, the router rebooted, and eight
/// agents were mid-turn" case.
///
/// It never picks a network for you: everything here nudges macOS into
/// re-running its own auto-join against your preferred networks, which
/// keeps credentials out of this app entirely. The ladder is
/// disassociate → power cycle, on a widening backoff, and it stops the
/// moment the path comes back. `NetworkMonitor.cameOnline` then drives
/// AgentManager's existing auto-resumer, so agents that failed while
/// offline retry themselves.
@MainActor
final class WiFiWatchdog: ObservableObject {

    enum State: Equatable {
        case online
        case offlineWaiting(nextAttemptIn: Int)
        case recovering(String)
        case noWiFiHardware
        case disabled
    }

    enum Keys {
        static let enabled = "manyagents.wifiwatchdog.enabled"
    }

    @Published var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            UserDefaults.standard.set(isEnabled, forKey: Keys.enabled)
            isEnabled ? evaluate() : cancelPending(setState: .disabled)
        }
    }

    @Published private(set) var state: State = .online
    /// Consecutive recovery attempts for the current outage. Resets on
    /// reconnect so a later blip starts from the short delay again.
    @Published private(set) var attempts = 0
    @Published private(set) var lastAction: String?
    @Published private(set) var lastActionAt: Date?

    /// Seconds to wait before attempt N. Starts gentle — most drops fix
    /// themselves inside 15 s and cycling the radio too eagerly makes
    /// things worse, not better.
    private let backoff: [Int] = [15, 30, 60, 120, 300]

    private var pending: DispatchWorkItem?
    private var cancellables: Set<AnyCancellable> = []

    init() {
        let defaults = UserDefaults.standard
        // Off until asked for. It only ever acts while the network is
        // already down, but cycling someone's radio uninvited is still
        // not ours to decide.
        self.isEnabled = (defaults.object(forKey: Keys.enabled) as? Bool) ?? false

        NetworkMonitor.shared.$isOnline
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.evaluate() }
            .store(in: &cancellables)

        // Waking from sleep re-runs auto-join on its own; give it a few
        // seconds before we start poking the radio.
        NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.didWakeNotification)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleAttempt(in: 10) }
            }
            .store(in: &cancellables)

        evaluate()
    }

    // MARK: - State machine

    private func evaluate() {
        guard isEnabled else { state = .disabled; return }
        guard interface != nil else { state = .noWiFiHardware; return }

        if NetworkMonitor.shared.isOnline {
            cancelPending(setState: .online)
            attempts = 0
            return
        }
        // Already counting down to the next attempt — leave it alone.
        if case .offlineWaiting = state, pending != nil { return }
        if case .recovering = state { return }
        scheduleAttempt(in: backoff[min(attempts, backoff.count - 1)])
    }

    private func scheduleAttempt(in seconds: Int) {
        guard isEnabled, interface != nil else { return }
        guard !NetworkMonitor.shared.isOnline else { return }
        pending?.cancel()
        state = .offlineWaiting(nextAttemptIn: seconds)
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.attemptRecovery() }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(seconds), execute: work)
    }

    private func cancelPending(setState newState: State) {
        pending?.cancel()
        pending = nil
        state = newState
    }

    // MARK: - Recovery ladder

    private func attemptRecovery() {
        pending = nil
        guard isEnabled, let wifi = interface else { return }
        guard !NetworkMonitor.shared.isOnline else {
            state = .online
            attempts = 0
            return
        }

        attempts += 1
        do {
            if !wifi.powerOn() {
                // Radio is off entirely — just turning it back on will
                // trigger auto-join.
                state = .recovering("turning Wi-Fi back on")
                try wifi.setPower(true)
                note("Turned Wi-Fi back on")
            } else if attempts % 2 == 1 {
                // Odd attempts: drop the association and let macOS
                // re-run auto-join against the preferred network list.
                state = .recovering("rejoining the network")
                wifi.disassociate()
                note("Disassociated to force a rejoin")
            } else {
                // Even attempts: full radio cycle. Heavier, but it clears
                // driver-level wedges that a disassociate can't.
                state = .recovering("restarting Wi-Fi")
                try wifi.setPower(false)
                note("Cycling the Wi-Fi radio")
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self, let wifi = self.interface else { return }
                        try? wifi.setPower(true)
                        self.note("Wi-Fi radio back on")
                    }
                }
            }
        } catch {
            note("Wi-Fi recovery failed: \(error.localizedDescription)")
        }

        // Give the join a chance to land before deciding it failed.
        scheduleAttempt(in: backoff[min(attempts, backoff.count - 1)])
    }

    private func note(_ text: String) {
        lastAction = text
        lastActionAt = Date()
    }

    /// The default Wi-Fi interface, or nil on a Mac without one (or when
    /// CoreWLAN can't see it — a Mac mini on Ethernet, say).
    private var interface: CWInterface? {
        CWWiFiClient.shared().interface()
    }

    var statusText: String {
        switch state {
        case .disabled:
            return "Won't touch Wi-Fi."
        case .noWiFiHardware:
            return "No Wi-Fi interface on this Mac."
        case .online:
            return lastAction.map { "Connected. Last action: \($0.lowercased())." }
                ?? "Connected."
        case .offlineWaiting(let secs):
            return "Offline — retrying in \(secs)s (attempt \(attempts + 1))."
        case .recovering(let what):
            return "Offline — \(what)…"
        }
    }
}
