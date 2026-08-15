import Foundation

/// A named, long-running container for several recordings that belong to one
/// occasion — a D&D night, a workshop, a day of interviews.
///
/// A recording is the wrong unit for these. An evening at the table is four or
/// five takes with breaks between them, and the thing you want to happen
/// afterwards — publish the journal, kick off a build — must happen once, when
/// the *evening* is over, not five times.
///
/// Configured in `routing.json` under `sessions`. That file rather than a new
/// one because it is already the hand-editable place where "what happens to a
/// finished recording" lives; a separate top-level key rather than an extension
/// of `destinations` because a destination is a folder and this is a lifecycle.
public struct SessionProfile: Codable, Equatable, Sendable, Identifiable {
    /// Stable, referenced by the App Intent and by the persisted active session.
    /// Renaming `name` is safe; changing this orphans a running session.
    public var id: String
    public var name: String

    /// Where this session's recordings are filed, overriding normal routing.
    /// Nil leaves them to the usual rules.
    public var destination: String?

    /// End the session after this long with no recording. Zero disables it.
    ///
    /// The default is deliberately generous. The competing failure modes are
    /// not symmetrical: ending too late costs a delayed hook, while ending too
    /// early splits one evening into two sessions and fires the completion
    /// action on half a game. A long dinner break must not look like the end.
    public var idleTimeout: TimeInterval

    /// Local wall-clock backstop, `"HH:mm"`. The first occurrence at or after
    /// the session's start — so a 22:00 session with a 01:00 stop ends in the
    /// small hours rather than immediately.
    public var hardStop: String?

    /// Run once, when the session is genuinely over. Receives the session's
    /// files via `${...}` substitution — see `SessionVariables`.
    public var onComplete: ExternalCommand?

    public init(
        id: String,
        name: String,
        destination: String? = nil,
        idleTimeout: TimeInterval = 3600,
        hardStop: String? = nil,
        onComplete: ExternalCommand? = nil
    ) {
        self.id = id
        self.name = name
        self.destination = destination
        self.idleTimeout = idleTimeout
        self.hardStop = hardStop
        self.onComplete = onComplete
    }

    enum CodingKeys: String, CodingKey {
        case id, name, destination, idleTimeout, hardStop, onComplete
    }

    /// Tolerant of missing keys, like the rest of this file's schema: a
    /// hand-edited config should degrade to defaults rather than fail to load
    /// and silently take routing with it.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = (try? c.decode(String.self, forKey: .name)) ?? id
        destination = try? c.decode(String.self, forKey: .destination)
        idleTimeout = (try? c.decode(TimeInterval.self, forKey: .idleTimeout)) ?? 3600
        hardStop = try? c.decode(String.self, forKey: .hardStop)
        onComplete = try? c.decode(ExternalCommand.self, forKey: .onComplete)
    }

    /// `hardStop` as (hour, minute), or nil when unset or malformed. Malformed
    /// is treated as unset rather than as an error — a typo in a time should
    /// cost you the backstop, not the session.
    public var hardStopComponents: (hour: Int, minute: Int)? {
        guard let hardStop else { return nil }
        let parts = hardStop.split(separator: ":")
        guard parts.count == 2,
              let h = Int(parts[0]), let m = Int(parts[1]),
              (0...23).contains(h), (0...59).contains(m) else { return nil }
        return (h, m)
    }
}
