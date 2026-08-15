import Foundation

/// Marker for a recording that is currently running.
///
/// Written when capture starts and deleted on a clean stop, so its presence at
/// launch means exactly one thing: the app went away while recording. That
/// happens for ordinary reasons — a new build installed over the top, a crash,
/// the system reclaiming memory — and in every one of them the user's intent was
/// "keep recording", not "stop".
///
/// A take can therefore span several audio files. Each interruption closes the
/// current segment and the next launch opens another under the same id; they are
/// concatenated into one recording at stop, so the seam is invisible downstream.
struct RecordingSession: Codable, Equatable {
    var id: UUID
    var startedAt: Date
    /// Segment filenames in order, relative to the captures directory.
    var segments: [String]
    /// Heartbeat: last time the running app touched this marker.
    ///
    /// Resume is gated on *this*, not on `startedAt`. The question worth asking
    /// is "how long has the app been gone", and a three-hour meeting interrupted
    /// one second ago must resume while a two-minute one abandoned yesterday
    /// must not. Keying off the start time answered the wrong question and made
    /// resume stop working after 15 minutes of recording — on exactly the long
    /// sessions it exists for (2026-08-10).
    ///
    /// Optional so markers written by earlier builds still decode.
    var lastSeen: Date?

    /// How long the app can have been gone and still pick the recording back up.
    /// A new build installing, a crash relaunching, the system reclaiming memory
    /// — all measured in seconds. Minutes of slack covers them without ever
    /// reopening a microphone the user has mentally moved on from.
    static let resumeWindow: TimeInterval = 5 * 60

    var isFresh: Bool {
        Date().timeIntervalSince(lastSeen ?? startedAt) < Self.resumeWindow
    }

    static func url(in directory: URL) -> URL {
        directory.appendingPathComponent("in-progress.json")
    }

    static func load(from directory: URL) -> RecordingSession? {
        guard let data = try? Data(contentsOf: url(in: directory)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(RecordingSession.self, from: data)
    }

    func save(to directory: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try? encoder.encode(self).write(to: Self.url(in: directory), options: .atomic)
    }

    static func clear(in directory: URL) {
        try? FileManager.default.removeItem(at: url(in: directory))
    }
}
