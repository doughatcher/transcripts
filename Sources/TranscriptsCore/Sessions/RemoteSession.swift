import Foundation

/// Reconstructs a session from recordings that were tagged on another device.
///
/// The phone knows which occasion a recording belonged to; only it can, because
/// by the time a Mac sees the file the evening is long over. So the phone stamps
/// the tag and this works backwards from it.
///
/// The crucial difference from `SessionLifecycle`: **nothing here asks what time
/// it is now.** A Mac that wakes on Tuesday morning and finds five captures from
/// Monday's game cannot ask "has this been idle for an hour" — it has been idle
/// for twelve, and the answer would be the same whether the game ended at nine
/// or was abandoned at seven. The end is a property of the recordings
/// themselves, so it is derived from their timestamps and gives the same answer
/// whether the Mac wakes ten minutes later or ten days.
public enum RemoteSession {
    /// One tagged recording, reduced to what the grouping actually needs.
    public struct Item: Equatable, Sendable {
        public let id: UUID
        public let sessionID: String
        public let label: String?
        public let startedAt: Date
        public let duration: TimeInterval

        public init(id: UUID, sessionID: String, label: String? = nil,
                    startedAt: Date, duration: TimeInterval) {
            self.id = id
            self.sessionID = sessionID
            self.label = label
            self.startedAt = startedAt
            self.duration = duration
        }

        /// When this recording stopped — the point the idle gap is measured from.
        var endedAt: Date { startedAt.addingTimeInterval(duration) }
    }

    /// A run of recordings that together make one occasion.
    public struct Run: Equatable, Sendable {
        public let sessionID: String
        public let label: String?
        public let items: [Item]
        public let startedAt: Date
        public let endedAt: Date
        public let reason: ActiveSession.EndReason
        /// False while the run may still gain recordings — the last one is
        /// recent enough that the evening might still be going.
        public let isClosed: Bool
    }

    /// Groups tagged recordings into runs and decides which are finished.
    ///
    /// `now` is passed rather than read so the caller can be tested, and it is
    /// used for exactly one thing: deciding whether the *most recent* run might
    /// still be open. Every other boundary comes from the recordings.
    public static func runs(
        from items: [Item],
        profile: SessionProfile,
        now: Date,
        calendar: Calendar = .current
    ) -> [Run] {
        let mine = items.filter { $0.sessionID == profile.id }
            .sorted { $0.startedAt < $1.startedAt }
        guard !mine.isEmpty else { return [] }

        var runs: [Run] = []
        var current: [Item] = [mine[0]]

        func close(_ group: [Item], reason: ActiveSession.EndReason, at end: Date) {
            runs.append(Run(
                sessionID: profile.id,
                // The label of the first recording in the run names it: later
                // ones in the same evening carry the same tag, and a nil from a
                // stray capture should not erase it.
                label: group.compactMap(\.label).first,
                items: group,
                startedAt: group[0].startedAt,
                endedAt: end,
                reason: reason,
                isClosed: true))
        }

        for item in mine.dropFirst() {
            let previousEnd = current.map(\.endedAt).max() ?? current[0].endedAt

            // The wall-clock backstop, evaluated against the run's own start —
            // a recording made after it belongs to the next evening, not this one.
            if let stop = SessionLifecycle.hardStopDate(
                for: profile, startedAt: current[0].startedAt, calendar: calendar),
               item.startedAt >= stop {
                close(current, reason: .hardStop, at: min(previousEnd, stop))
                current = [item]
                continue
            }
            // A gap longer than the timeout means the evening ended and another
            // began. Measured end-to-start, so a three-hour recording is not
            // mistaken for three hours of silence.
            if profile.idleTimeout > 0,
               item.startedAt.timeIntervalSince(previousEnd) >= profile.idleTimeout {
                close(current, reason: .idle, at: previousEnd)
                current = [item]
                continue
            }
            current.append(item)
        }

        // The final run is the only one whose closure depends on the present:
        // everything before it was closed by a later recording existing.
        let lastEnd = current.map(\.endedAt).max() ?? current[0].endedAt
        var closed = false
        var reason = ActiveSession.EndReason.idle
        if let stop = SessionLifecycle.hardStopDate(
            for: profile, startedAt: current[0].startedAt, calendar: calendar),
           now >= stop {
            closed = true
            reason = .hardStop
        } else if profile.idleTimeout > 0,
                  now.timeIntervalSince(lastEnd) >= profile.idleTimeout {
            closed = true
            reason = .idle
        }
        runs.append(Run(
            sessionID: profile.id,
            label: current.compactMap(\.label).first,
            items: current,
            startedAt: current[0].startedAt,
            endedAt: lastEnd,
            reason: reason,
            isClosed: closed))

        return runs
    }

    /// A stable identity for a run, so completion can be recorded and never
    /// repeated. Derived from the tag and the run's start rather than from a
    /// counter, so it is the same value however many times it is recomputed.
    public static func key(for run: Run) -> String {
        "\(run.sessionID)@\(Int(run.startedAt.timeIntervalSince1970))"
    }
}
