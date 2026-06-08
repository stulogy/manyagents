import Foundation
import AppKit
import UserNotifications

/// Posts a system banner + plays a sound when an agent finishes working.
/// All behaviour is user-configurable from the Settings window; this service
/// reads those preferences straight out of UserDefaults so there's no extra
/// plumbing between the SwiftUI toggles and the firing site.
///
/// Sound is played via `NSSound` (not the notification's own sound) so the
/// user can pick any macOS system sound and hear it even if notification
/// authorization was declined — the banner needs permission, an audible cue
/// shouldn't.
final class NotificationService: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationService()

    /// UserDefaults keys, shared with the `@AppStorage` bindings in Settings.
    enum Keys {
        static let enabled = "manyagents.notify.enabled"
        static let sound = "manyagents.notify.sound"
        static let soundName = "manyagents.notify.soundName"
        static let onlyWhenInactive = "manyagents.notify.onlyWhenInactive"
        static let notifyOnError = "manyagents.notify.onError"
    }

    /// The macOS system sounds (in /System/Library/Sounds). Exposed so the
    /// Settings picker and this service agree on the valid set.
    static let systemSounds = [
        "Basso", "Blow", "Bottle", "Frog", "Funk", "Glass", "Hero",
        "Morse", "Ping", "Pop", "Purr", "Sosumi", "Submarine", "Tink"
    ]

    private override init() {
        super.init()
        UserDefaults.standard.register(defaults: [
            Keys.enabled: true,
            Keys.sound: true,
            Keys.soundName: "Glass",
            Keys.onlyWhenInactive: true,
            Keys.notifyOnError: true
        ])
    }

    /// Call once at launch: become the delegate (so banners can show while
    /// the app is frontmost) and request authorization for alerts + sound.
    func bootstrap() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// An agent just stopped working. Decides — per the user's settings —
    /// whether to surface a banner and/or play a sound.
    func agentFinished(sessionId: UUID, projectName: String, title: String, status: AgentStatus) {
        let d = UserDefaults.standard
        guard d.bool(forKey: Keys.enabled) else { return }

        let body: String
        switch status {
        case .waiting: body = "Waiting on you"
        case .idle:    body = "Finished"
        case .error:
            guard d.bool(forKey: Keys.notifyOnError) else { return }
            body = "Stopped on an error"
        case .running:
            return   // not a finished state
        }

        // The signal can fire off the main thread; NSApp / NSSound / the
        // notification center all want main. Hop once, here.
        DispatchQueue.main.async {
            // Skip while the user is actively in the app, if they asked us to.
            if d.bool(forKey: Keys.onlyWhenInactive) && NSApp.isActive { return }

            if d.bool(forKey: Keys.sound) {
                let name = d.string(forKey: Keys.soundName) ?? "Glass"
                NSSound(named: NSSound.Name(name))?.play()
            }

            let content = UNMutableNotificationContent()
            content.title = "\(projectName) · \(title)"
            content.body = body
            // Carry the session id so clicking the banner can jump straight
            // to that agent's conversation.
            content.userInfo = ["sessionId": sessionId.uuidString]
            // Sound is handled by NSSound above; leave the banner silent so
            // we don't double up.
            let request = UNNotificationRequest(
                identifier: UUID().uuidString,
                content: content,
                trigger: nil
            )
            UNUserNotificationCenter.current().add(request)
        }
    }

    /// Preview helper for the Settings sound picker.
    func previewSound(_ name: String) {
        NSSound(named: NSSound.Name(name))?.play()
    }

    // Show the banner (no sound — NSSound already fired) even when the app is
    // frontmost, for the case where the user disabled the inactive-only filter.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner])
    }

    /// User clicked the banner — bring the app forward and focus the agent it
    /// was about. AgentManager listens for `.maFocusSession`.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let info = response.notification.request.content.userInfo
        if let raw = info["sessionId"] as? String, let id = UUID(uuidString: raw) {
            DispatchQueue.main.async {
                NSApp.activate(ignoringOtherApps: true)
                NotificationCenter.default.post(
                    name: .maFocusSession, object: nil, userInfo: ["sessionId": id]
                )
            }
        }
        completionHandler()
    }
}
