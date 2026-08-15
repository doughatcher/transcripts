import AppKit
import Foundation
import UserNotifications
import TranscriptsEngine

/// Posts the "you're on a call — announce & record" notification used by two-party
/// consent mode, and routes its action button back to the app.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    /// Called when the user taps "Start recording" on the notification.
    var onStartRecording: (() -> Void)?

    private let center = UNUserNotificationCenter.current()
    private let startAction = "TRANSCRIPTS_START_RECORDING"
    private let category = "TRANSCRIPTS_CALL"

    /// Registers the notification category/action and requests permission. Safe to
    /// call once at launch; no-ops gracefully if notifications aren't available.
    func configure() {
        center.delegate = self
        let start = UNNotificationAction(identifier: startAction, title: "Start recording", options: [.foreground])
        let cat = UNNotificationCategory(identifier: category, actions: [start], intentIdentifiers: [])
        center.setNotificationCategories([cat])
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            Log.write("notifications: \(granted ? "authorized" : "not authorized")")
        }
    }

    /// Announces a detected call so the user can tell participants before recording.
    func announceCall(app: String) {
        let content = UNMutableNotificationContent()
        content.title = "On a \(app) call"
        content.body = "Two-party consent: tell everyone you're recording, then start."
        content.categoryIdentifier = category
        content.sound = .default
        center.add(UNNotificationRequest(identifier: "transcripts-call-\(UUID().uuidString)",
                                         content: content, trigger: nil))
    }

    /// Current authorization, for the Settings surface (#8): consent
    /// announcements and dead-mic banners silently vanish when denied.
    func authorizationStatus() async -> UNAuthorizationStatus {
        await center.notificationSettings().authorizationStatus
    }

    /// Re-requests permission (no-ops if already decided; then the user must
    /// flip it in System Settings, which `openSystemSettings` deep-links).
    func requestAuthorization() {
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            Log.write("notifications: \(granted ? "authorized" : "not authorized")")
        }
    }

    static func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Alerts that the recording mic is producing silence — and whether Transcripts
    /// switched to another input or needs the user to pick one.
    func alertDeadMic(device: String, switchedTo: String?) {
        let content = UNMutableNotificationContent()
        if let switchedTo {
            content.title = "Mic is silent"
            content.body = "'\(device)' captured nothing — switched to '\(switchedTo)' and kept recording."
        } else {
            // No switch happened — on a call this is almost always a mute, so say so
            // rather than implying the mic is broken.
            content.title = "Not hearing your mic"
            content.body = "If you're muted, that's expected. Otherwise '\(device)' isn't picking up sound — change it in Settings ▸ General."
        }
        content.sound = .default
        center.add(UNNotificationRequest(identifier: "transcripts-deadmic-\(UUID().uuidString)",
                                         content: content, trigger: nil))
    }

    // Show the banner even though we're the foreground (menu-bar) app.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if response.actionIdentifier == startAction || response.actionIdentifier == UNNotificationDefaultActionIdentifier {
            DispatchQueue.main.async { self.onStartRecording?() }
        }
        completionHandler()
    }
}
