import Foundation
import CoreGraphics
import AppKit
import TranscriptsCore

/// Reads on-screen window titles for running meeting apps (Teams/Zoom/etc.), e.g.
/// "Contoso Rollout Standup | Microsoft Teams". Meeting titles usually name the
/// client, so they're a strong routing signal.
///
/// Uses `CGWindowListCopyWindowInfo` — the window title (`kCGWindowName`) requires
/// **Screen Recording** (which Transcripts already uses for call capture), NOT the
/// Accessibility API. If Screen Recording isn't granted the titles are simply empty.
enum WindowTitleProvider {
    static func meetingWindowTitles() -> [String] {
        let meetingPIDs = Set(NSWorkspace.shared.runningApplications.filter { app in
            guard let bid = app.bundleIdentifier?.lowercased() else { return false }
            return MeetingDetector.meetingApps.contains { bid.hasPrefix($0.idFragment.lowercased()) }
        }.map { $0.processIdentifier })

        guard !meetingPIDs.isEmpty,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return [] }

        var titles: [String] = []
        for window in list {
            guard let pid = window[kCGWindowOwnerPID as String] as? pid_t, meetingPIDs.contains(pid),
                  let name = window[kCGWindowName as String] as? String else { continue }
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            // Skip empties and generic app-chrome titles.
            guard trimmed.count > 2, !titles.contains(trimmed) else { continue }
            let lower = trimmed.lowercased()
            if ["microsoft teams", "zoom", "meet", "webex", "slack"].contains(lower) { continue }
            titles.append(trimmed)
        }
        return titles
    }

    /// Convenience: the best meeting name from the current on-screen windows.
    static func currentMeetingName() -> String? { meetingName(from: meetingWindowTitles()) }

    /// Picks the most human meeting name out of captured window titles. The
    /// selection rules live in `TranscriptsCore.MeetingName` (pure and unit-tested);
    /// this wrapper only supplies the live window titles.
    static func meetingName(from titles: [String]) -> String? {
        MeetingName.pick(from: titles)
    }
}
