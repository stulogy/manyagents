import Foundation
import Combine
import AppKit
import IOKit.pwr_mgt
import IOKit.ps

/// Keeps the Mac running while agents are mid-turn. Three layers, each
/// stronger (and more intrusive) than the last:
///
/// 1. `beginActivity` — stops App Nap throttling our timers and the
///    `claude` subprocesses we own. Free, always safe.
/// 2. `PreventUserIdleSystemSleep` — the `caffeinate -i` assertion. Stops
///    the idle sleep timer. The display can still sleep; we deliberately
///    don't assert display wakefulness, there's no reason to burn the
///    panel for a background agent.
/// 3. `PreventSystemSleep` + `pmset disablesleep` — the lid-closed case.
///    On Apple Silicon the assertion alone does NOT survive a lid close;
///    only the `pmset` setting does, and that needs an admin password.
///    Strictly opt-in, and put back the moment it's switched off.
@MainActor
final class StayAwake: ObservableObject {

    enum Mode: String, CaseIterable, Identifiable {
        case off
        case whileWorking
        case always

        var id: String { rawValue }

        var label: String {
            switch self {
            case .off:          return "Never"
            case .whileWorking: return "While agents are working"
            case .always:       return "Always, while ManyAgents is open"
            }
        }
    }

    enum Keys {
        static let mode        = "manyagents.stayawake.mode"
        static let lidClosed   = "manyagents.stayawake.lidClosed"
        /// Sticky record that WE set the system-wide lid-sleep override.
        /// Survives a crash so the next launch can offer to put it back.
        static let didDisable  = "manyagents.stayawake.didDisableLidSleep"
    }

    @Published var mode: Mode {
        didSet {
            guard mode != oldValue else { return }
            UserDefaults.standard.set(mode.rawValue, forKey: Keys.mode)
            evaluate()
        }
    }

    /// Opt-in to the admin-privileged part. Only meaningful with a mode
    /// other than `.off`.
    @Published var keepGoingWithLidClosed: Bool {
        didSet {
            guard keepGoingWithLidClosed != oldValue else { return }
            UserDefaults.standard.set(keepGoingWithLidClosed, forKey: Keys.lidClosed)
            evaluate()
        }
    }

    /// True while we hold at least the idle-sleep assertion.
    @Published private(set) var isHoldingAwake = false
    /// True while the system-wide lid-sleep override is ours and active.
    @Published private(set) var lidSleepDisabled = false
    /// True when a previous run left the override on — force quit, crash,
    /// power cut. Surfaced in Settings with a "put it back" button rather
    /// than throwing a password prompt at launch.
    @Published private(set) var needsLidSleepRevert = false
    @Published private(set) var lastError: String?

    private var idleAssertion: IOPMAssertionID = 0
    private var systemAssertion: IOPMAssertionID = 0
    private var activityToken: NSObjectProtocol?
    private weak var manager: AgentManager?
    private var cancellables: Set<AnyCancellable> = []

    init() {
        let defaults = UserDefaults.standard
        // Off until asked for. Holding a power assertion is the kind of
        // thing that should never happen because an app decided for you.
        self.mode = Mode(rawValue: defaults.string(forKey: Keys.mode) ?? "") ?? .off
        self.keepGoingWithLidClosed = defaults.bool(forKey: Keys.lidClosed)

        // NOTHING that blocks belongs in here. This runs inside SwiftUI's
        // @StateObject instantiation, and Process.waitUntilExit() spins a
        // nested runloop, which re-enters the graph mid-update and makes
        // AttributeGraph abort the process on launch. The system read
        // happens in `attach`, off the main thread, after the app is up.

        // Always release everything on the way out. Terminating without
        // this leaves the Mac unable to sleep until the next reboot.
        NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.releaseEverything() }
            }
            .store(in: &cancellables)
    }

    /// Watch the session list so `.whileWorking` can follow along. The
    /// manager republishes every inner-session change, so a status flip
    /// lands here; debounced because that fires on every streamed token.
    func attach(manager: AgentManager) {
        self.manager = manager
        refreshSystemLidState()
        manager.objectWillChange
            .debounce(for: .milliseconds(400), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.evaluate() }
            .store(in: &cancellables)
        evaluate()
    }

    /// Read the live lid-sleep setting off the main thread, then reconcile.
    /// Adopting a setting that's already in place avoids asking for a
    /// password to re-apply it — a reboot clears it, a relaunch doesn't.
    private func refreshSystemLidState() {
        Task.detached(priority: .utility) {
            let systemDisabled = Self.systemLidSleepDisabled()
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.lidSleepDisabled = systemDisabled
                let defaults = UserDefaults.standard
                if defaults.bool(forKey: Keys.didDisable) {
                    if systemDisabled {
                        // Ours from a previous run. Still wanted? Keep it.
                        // If the option is off, offer to put it back rather
                        // than doing it silently — reverting needs a
                        // password too.
                        self.needsLidSleepRevert =
                            !(self.keepGoingWithLidClosed && self.mode != .off)
                    } else {
                        // A reboot (or someone else) already put it back.
                        defaults.set(false, forKey: Keys.didDisable)
                    }
                }
                self.evaluate()
            }
        }
    }

    /// Human-readable one-liner for the Settings footer / status row.
    var statusText: String {
        if let lastError { return lastError }
        switch mode {
        case .off:
            return "The Mac sleeps on its usual schedule."
        case .whileWorking, .always:
            if !isHoldingAwake {
                return mode == .whileWorking
                    ? "Idle — the Mac can sleep until an agent starts working."
                    : "Not holding (no assertion)."
            }
            if keepGoingWithLidClosed && lidSleepDisabled {
                return Self.onACPower()
                    ? "Awake, lid close included."
                    : "Awake, lid close included — but on battery macOS may still sleep."
            }
            return "Awake. Closing the lid will still sleep the Mac."
        }
    }

    // MARK: - Evaluation

    /// Single decision point: work out whether we should be holding, and
    /// reconcile the actual assertions with that.
    private func evaluate() {
        let shouldHold: Bool
        switch mode {
        case .off:          shouldHold = false
        case .always:       shouldHold = true
        case .whileWorking: shouldHold = anyAgentBusy
        }

        if shouldHold {
            acquire()
        } else {
            release()
        }

        // The system-wide override tracks the toggle, not the momentary
        // hold — asking for a password every time an agent starts a turn
        // would be intolerable.
        let wantLidOverride = keepGoingWithLidClosed && mode != .off
        if wantLidOverride != lidSleepDisabled {
            setSystemLidSleepDisabled(wantLidOverride)
        }
    }

    private var anyAgentBusy: Bool {
        guard let manager else { return false }
        return manager.sessions.contains { $0.status == .running || !$0.pendingPrompts.isEmpty }
    }

    // MARK: - Assertions

    private func acquire() {
        if activityToken == nil {
            activityToken = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .idleSystemSleepDisabled, .automaticTerminationDisabled],
                reason: "ManyAgents is running agents"
            )
        }
        if idleAssertion == 0 {
            var aid: IOPMAssertionID = 0
            let ok = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "ManyAgents: agents running" as CFString,
                &aid
            )
            if ok == kIOReturnSuccess { idleAssertion = aid }
        }
        // The AC-power assertion. Not sufficient for a lid close on Apple
        // Silicon by itself, but it's the right thing to hold alongside
        // the pmset override and it costs nothing.
        if keepGoingWithLidClosed && systemAssertion == 0 {
            var aid: IOPMAssertionID = 0
            let ok = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventSystemSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "ManyAgents: agents running with the lid closed" as CFString,
                &aid
            )
            if ok == kIOReturnSuccess { systemAssertion = aid }
        }
        if !keepGoingWithLidClosed && systemAssertion != 0 {
            IOPMAssertionRelease(systemAssertion)
            systemAssertion = 0
        }
        isHoldingAwake = idleAssertion != 0
    }

    private func release() {
        if idleAssertion != 0 {
            IOPMAssertionRelease(idleAssertion)
            idleAssertion = 0
        }
        if systemAssertion != 0 {
            IOPMAssertionRelease(systemAssertion)
            systemAssertion = 0
        }
        if let token = activityToken {
            ProcessInfo.processInfo.endActivity(token)
            activityToken = nil
        }
        isHoldingAwake = false
    }

    /// Drop every hold INCLUDING the system-wide override. Quit path.
    private func releaseEverything() {
        release()
        if lidSleepDisabled || UserDefaults.standard.bool(forKey: Keys.didDisable) {
            setSystemLidSleepDisabled(false)
        }
    }

    // MARK: - Lid sleep override

    /// Flip the system-wide `disablesleep` setting. Needs an admin
    /// password, so it goes through the standard authorization prompt.
    /// Turning it OFF re-prompts — unavoidable, it's a root-owned setting.
    @discardableResult
    func setSystemLidSleepDisabled(_ disabled: Bool) -> Bool {
        let script = "do shell script \"/usr/bin/pmset -a disablesleep \(disabled ? 1 : 0)\""
                   + " with administrator privileges"
        var errorInfo: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&errorInfo)

        if let errorInfo {
            let code = (errorInfo["NSAppleScriptErrorNumber"] as? Int) ?? 0
            if code == -128 {
                lastError = "Password prompt cancelled — lid close will still sleep the Mac."
                // Don't leave the toggle claiming something that isn't true.
                if disabled { keepGoingWithLidClosed = false }
            } else {
                lastError = (errorInfo["NSAppleScriptErrorMessage"] as? String)
                    ?? "Couldn't change the lid-sleep setting."
            }
            return false
        }

        lastError = nil
        lidSleepDisabled = disabled
        needsLidSleepRevert = false
        UserDefaults.standard.set(disabled, forKey: Keys.didDisable)
        return true
    }

    /// Read the live system setting. `pmset -g` only prints the key when
    /// it's been set, so absence means "normal sleep behavior".
    nonisolated static func systemLidSleepDisabled() -> Bool {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        proc.arguments = ["-g"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch { return false }
        // Read to EOF and stop there. waitUntilExit() spins a runloop,
        // which is safe on this background thread but not worth keeping
        // in a function anyone might later call from main.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let out = String(data: data, encoding: .utf8) else { return false }
        for line in out.split(separator: "\n") where line.contains("SleepDisabled") {
            return line.contains("1")
        }
        return false
    }

    static func onACPower() -> Bool {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(blob)?.takeRetainedValue() as String?
        else { return false }
        return type == kIOPMACPowerKey
    }
}
