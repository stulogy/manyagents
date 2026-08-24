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
            // Flipping this switch is the ONLY thing that asks for a
            // password. Earlier versions reconciled the system setting on
            // launch, on quit, and on every re-evaluation, which meant
            // three prompts in one session for a setting the user had
            // already agreed to once.
            if keepGoingWithLidClosed != lidSleepDisabled {
                setSystemLidSleepDisabled(keepGoingWithLidClosed)
            }
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
    /// Live power source, polled while we're holding. The indicator needs
    /// it to say whether the Mac is burning battery to stay up.
    @Published private(set) var onBattery: Bool = false

    private var powerPoll: AnyCancellable?
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

    /// Read the live lid-sleep setting off the main thread, then make our
    /// state agree with the system's. Never changes the system setting —
    /// that only happens when the user flips the switch.
    private func refreshSystemLidState() {
        Task.detached(priority: .utility) {
            let systemDisabled = Self.systemLidSleepDisabled()
            await MainActor.run { [weak self] in
                guard let self else { return }
                let defaults = UserDefaults.standard
                self.lidSleepDisabled = systemDisabled
                let weSetIt = defaults.bool(forKey: Keys.didDisable)

                if systemDisabled {
                    // Still in effect. If the switch is on, that's exactly
                    // what the user asked for — adopt it silently. If it's
                    // off and we're the ones who set it, offer the "Put it
                    // back" button rather than reverting unasked.
                    self.needsLidSleepRevert = weSetIt && !self.keepGoingWithLidClosed
                } else {
                    // Not in effect. Anything we recorded is stale.
                    if weSetIt { defaults.set(false, forKey: Keys.didDisable) }
                    self.needsLidSleepRevert = false
                    // The switch claiming a lid-close guarantee we don't
                    // have is worse than it reading off, so tell the truth.
                    // Costs no prompt: both sides already agree it's off.
                    if self.keepGoingWithLidClosed { self.keepGoingWithLidClosed = false }
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

    /// Tooltip for the menu-bar-ish indicator in the sidebar.
    var indicatorHelp: String {
        let why = mode == .always
            ? "Set to stay awake always"
            : "An agent is working"
        return onBattery
            ? "\(why) — this Mac won't sleep, and it's on battery. Click to change."
            : "\(why) — this Mac won't sleep. Click to change."
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

        // Deliberately does NOT touch the pmset override. That is a
        // system-wide, password-gated setting: it changes when the user
        // flips the switch, and at no other time.
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
        onBattery = !Self.onACPower()
        if powerPoll == nil {
            // Cheap, and only runs while we're actually holding.
            powerPoll = Timer.publish(every: 30, on: .main, in: .common)
                .autoconnect()
                .sink { [weak self] _ in
                    guard let self else { return }
                    self.onBattery = !Self.onACPower()
                }
        }
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
        powerPoll?.cancel()
        powerPoll = nil
    }

    /// Quit path. Assertions die with the process anyway; release them
    /// tidily and leave the pmset override exactly as the user left it.
    /// Reverting here meant a password prompt every time the app closed —
    /// and prompting during termination is a good way to get force-quit
    /// halfway through. The override stays until the switch goes off, and
    /// `needsLidSleepRevert` offers to put it back if it was left on.
    private func releaseEverything() {
        release()
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
