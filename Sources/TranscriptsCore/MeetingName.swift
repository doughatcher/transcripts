import Foundation

/// Picks the most human meeting name out of captured meeting-app window titles
/// — e.g. "Rollout Weekly Leadership Status" out of Teams/Zoom/Slack window
/// chrome. Pure logic (no CGWindowList) so every hard-won rule stays testable:
///
/// - Teams packs several `|`-separated segments and the real name can sit in
///   ANY of them ("Meeting join | Tracy / Doug | doug@corp.com | Microsoft
///   Teams") — every segment is scored.
/// - Chrome glued onto the name in one segment is stripped by prefix
///   ("Meeting join - Sprint Review" → "Sprint Review").
/// - Slack chat windows ("bryan (DM) - Workspace - Slack [Main]") are never
///   meeting names; Slack huddle-style titles keep only their left side.
/// - Emails, bare domains, unread markers, and pure chrome are rejected.
public enum MeetingName {

    static let chrome: Set<String> = [
        "microsoft teams", "teams", "zoom", "zoom meeting", "meet", "google meet",
        "webex", "slack", "meeting", "meeting join", "join", "meeting compact view",
        "compact view", "chat", "calendar", "activity", "call", "home",
        "notifications", "thread", "huddle", "unreads", "drafts", "later",
        // Screen-share/presentation chrome (stole a live title on 2026-07-13:
        // "Doug / Rick" → "Sharing control bar").
        "sharing control bar", "presenter view", "screen sharing", "you're sharing",
        "meeting controls", "meeting now", "stop sharing",
    ]

    /// Leading chrome fused to a real name in the same segment.
    static let chromePrefix =
        #"^(?i)(?:meeting join|zoom meeting|meeting|join|huddle|call)\b[\s:|–—-]*"#

    public static func pick(from titles: [String]) -> String? {
        var best: String?
        var bestScore = -1
        for raw in titles {
            // Chat-window chrome is never a meeting name: Slack DM/channel
            // windows and unread badges.
            let lowerRaw = raw.lowercased()
            if lowerRaw.contains("(dm)") || lowerRaw.contains("(channel)")
                || lowerRaw.contains("new item") || lowerRaw.contains("[main]") { continue }

            for part in raw.components(separatedBy: " | ") {
                var candidate = part.trimmingCharacters(in: .whitespacesAndNewlines)
                // Slack packs "Name - Workspace - Slack …" — keep the left side.
                if candidate.lowercased().contains("slack") {
                    let parts = candidate.components(separatedBy: " - ")
                    if parts.count >= 2 {
                        candidate = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                }
                // Unread markers ("! Sprint Review") aren't part of the name.
                while candidate.hasPrefix("!") {
                    candidate = String(candidate.dropFirst()).trimmingCharacters(in: .whitespaces)
                }
                // "Meeting join - Sprint Review" → "Sprint Review".
                candidate = candidate
                    .replacingOccurrences(of: chromePrefix, with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                let lower = candidate.lowercased()
                guard candidate.count >= 4 else { continue }
                guard !chrome.contains(lower) else { continue }
                guard !candidate.contains("@") else { continue }          // email
                // A bare domain/URL (no spaces, has a dot) isn't a meeting name.
                if !candidate.contains(" "), candidate.contains(".") { continue }
                // Prefer the most descriptive: more words wins, longer breaks ties.
                let score = candidate.split(separator: " ").count * 100 + candidate.count
                if score > bestScore { bestScore = score; best = candidate }
            }
        }
        return best
    }
}
