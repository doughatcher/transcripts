import Foundation

/// The session currently running, persisted so it survives the app going away.
///
/// Same reasoning as `RecordingSession`: a session spans hours, and in that time
/// a build gets installed, the machine sleeps, something crashes. None of those
/// mean "the game ended", so the state cannot live only in memory.
public struct ActiveSession: Codable, Equatable, Sendable {
    public var profileID: String
    public var startedAt: Date
    /// Last time a recording started or finished under this session. The idle
    /// clock runs from here, not from `startedAt`.
    public var lastActivityAt: Date
    /// Recordings captured so far, in order.
    public var recordingIDs: [UUID]

    /// Set the moment the session is judged over, before the hook is attempted.
    public var endedAt: Date?
    public var endReason: EndReason?

    /// Set only after the completion command has actually run.
    ///
    /// Two fields rather than one because the interesting failure is a crash
    /// *between* deciding the session ended and the hook finishing. Recording
    /// the decision separately from the outcome means a relaunch can tell the
    /// difference between "never fired" and "already fired", and neither
    /// double-publishes nor silently drops the evening.
    public var completedAt: Date?

    public enum EndReason: String, Codable, Sendable {
        case explicit    // the user said so
        case idle        // nothing recorded for long enough
        case hardStop    // wall-clock backstop
    }

    public init(profileID: String, startedAt: Date, lastActivityAt: Date? = nil,
                recordingIDs: [UUID] = [], endedAt: Date? = nil,
                endReason: EndReason? = nil, completedAt: Date? = nil) {
        self.profileID = profileID
        self.startedAt = startedAt
        self.lastActivityAt = lastActivityAt ?? startedAt
        self.recordingIDs = recordingIDs
        self.endedAt = endedAt
        self.endReason = endReason
        self.completedAt = completedAt
    }

    /// True while the session should still absorb new recordings.
    public var isRunning: Bool { endedAt == nil }

    /// Ended, but its completion action has not run. What a relaunch looks for.
    public var needsCompletion: Bool { endedAt != nil && completedAt == nil }
}

/// When a session is over. Pure, so the awkward cases are testable rather than
/// discovered on a Monday night.
public enum SessionLifecycle {
    /// Why this session should end now, or nil to keep it running.
    ///
    /// Order matters: the wall-clock backstop is checked before the idle timer,
    /// because a session that has run past its stop time should end at that
    /// time regardless of whether someone happened to be recording.
    public static func endReason(
        for session: ActiveSession,
        profile: SessionProfile,
        now: Date,
        calendar: Calendar = .current
    ) -> ActiveSession.EndReason? {
        guard session.isRunning else { return nil }

        if let stop = hardStopDate(for: profile, startedAt: session.startedAt, calendar: calendar),
           now >= stop {
            return .hardStop
        }
        if profile.idleTimeout > 0,
           now.timeIntervalSince(session.lastActivityAt) >= profile.idleTimeout {
            return .idle
        }
        return nil
    }

    /// The first occurrence of the profile's wall-clock stop at or after the
    /// session started.
    ///
    /// "At or after" is what makes an evening session work: a game beginning at
    /// 18:00 with a 23:30 stop ends tonight, while one beginning at 22:00 with a
    /// 01:00 stop ends tomorrow morning rather than three hours before it began.
    public static func hardStopDate(
        for profile: SessionProfile,
        startedAt: Date,
        calendar: Calendar = .current
    ) -> Date? {
        guard let (hour, minute) = profile.hardStopComponents else { return nil }
        var comps = calendar.dateComponents([.year, .month, .day], from: startedAt)
        comps.hour = hour
        comps.minute = minute
        comps.second = 0
        guard let sameDay = calendar.date(from: comps) else { return nil }
        if sameDay > startedAt { return sameDay }
        return calendar.date(byAdding: .day, value: 1, to: sameDay)
    }
}

/// Substitutions available to a profile's `onComplete` command.
///
/// Deliberately the same `${name}` convention the pipeline's external stages
/// use, so anyone who has written a stage script already knows the shape.
public enum SessionVariables {
    public static func variables(
        session: ActiveSession,
        profile: SessionProfile,
        sessionDirectory: URL?,
        transcripts: [URL],
        audio: [URL]
    ) -> [String: String] {
        let iso = ISO8601DateFormatter()
        var v: [String: String] = [
            "sessionID": profile.id,
            "sessionName": profile.name,
            "startedAt": iso.string(from: session.startedAt),
            "recordingCount": String(session.recordingIDs.count),
            "endReason": session.endReason?.rawValue ?? "",
        ]
        if let endedAt = session.endedAt { v["endedAt"] = iso.string(from: endedAt) }
        if let sessionDirectory { v["sessionDir"] = sessionDirectory.path }
        // Newline-separated so a shell can loop over them without quoting games.
        v["transcripts"] = transcripts.map(\.path).joined(separator: "\n")
        v["audio"] = audio.map(\.path).joined(separator: "\n")
        // A slug that is stable for the evening, for anyone building a folder
        // name out of it — the shape adventure-log's data/sessions/ already uses.
        let day = DateFormatter()
        day.dateFormat = "yyyy-MM-dd"
        v["slug"] = "\(day.string(from: session.startedAt))-\(profile.id)"
        return v
    }
}
