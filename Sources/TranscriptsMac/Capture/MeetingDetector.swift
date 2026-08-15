import Foundation
import AppKit

/// Detects whether a meeting/conferencing app is running, so auto-record can fire
/// specifically for calls (mic goes live + a meeting app is running) rather than
/// for any incidental mic use.
///
/// We can't read Teams/Zoom private call state, but these apps only open the
/// microphone during an active call — so "meeting app running + mic live" is a
/// reliable proxy for "in a call," and mic-idle marks the call ending.
enum MeetingDetector {

    /// Known conferencing apps by bundle-id prefix and a friendly name.
    static let meetingApps: [(idFragment: String, name: String)] = [
        ("com.microsoft.teams", "Microsoft Teams"),   // teams2 (new) and classic
        ("us.zoom.xos", "Zoom"),
        ("com.zoom", "Zoom"),
        ("com.webex", "Webex"),
        ("com.cisco.webex", "Webex"),
        ("com.google.Chrome", "Google Meet (Chrome)"), // Meet runs in a browser
        ("com.apple.FaceTime", "FaceTime"),
        ("com.hnc.Discord", "Discord"),
        ("com.tinyspeck.slackmacgap", "Slack Huddle"),
        ("com.microsoft.SkypeForBusiness", "Skype for Business"),
    ]

    /// The friendly name of a running meeting app, if any (first match wins).
    /// Browser matches are lower priority since a browser is usually running.
    static func runningMeetingApp() -> String? {
        let running = NSWorkspace.shared.runningApplications
        let ids = running.compactMap { $0.bundleIdentifier?.lowercased() }

        // Prefer dedicated conferencing clients over browsers.
        for entry in meetingApps where !entry.idFragment.contains("Chrome") {
            if ids.contains(where: { $0.hasPrefix(entry.idFragment.lowercased()) }) {
                return entry.name
            }
        }
        for entry in meetingApps where entry.idFragment.contains("Chrome") {
            if ids.contains(where: { $0.hasPrefix(entry.idFragment.lowercased()) }) {
                return entry.name
            }
        }
        return nil
    }

    static var isMeetingAppRunning: Bool { runningMeetingApp() != nil }
}
