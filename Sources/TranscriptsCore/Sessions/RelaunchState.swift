import Foundation

/// What a recording needs to survive the app being restarted underneath it.
///
/// The audio itself was never the fragile part — captures are LPCM-in-CAF
/// precisely so they stay readable at any truncation point (see `Recorder.start`).
/// What was fragile is the app's *knowledge*: on relaunch the recording was
/// filed as a finished note, so restarting Transcripts in the middle of a long
/// evening chopped it into pieces.
///
/// These two files close that gap. Together they let a relaunch pick the meeting
/// back up rather than end it — which is what makes rebuilding the app during a
/// session a normal thing to do rather than something to schedule around.
public struct RelaunchState {
    let directory: URL

    /// Directory-scoped so the resume decision — which is what stands between an
    /// evening being picked back up and being filed in halves — can be tested
    /// without touching Application Support.
    public init(directory: URL) {
        self.directory = directory
    }

    /// Marker written while a recording is live, deleted when one is deliberately
    /// stopped. Its presence at launch means the app went away mid-recording —
    /// by quit, crash, or rebuild — and the meeting is meant to continue.
    public struct Marker: Codable, Equatable {
        public var startedAt: Date
        public var title: String
        public var isCall: Bool
        /// Last time the app confirmed the recording was live. Compared against
        /// the resume window so a marker left by a crash last Tuesday doesn't
        /// start recording when the Mac is opened on Thursday.
        public var heartbeatAt: Date

        public init(startedAt: Date, title: String, isCall: Bool, heartbeatAt: Date) {
            self.startedAt = startedAt
            self.title = title
            self.isCall = isCall
            self.heartbeatAt = heartbeatAt
        }
    }

    var markerURL: URL { directory.appendingPathComponent("relaunch.json") }
    var fragmentsURL: URL { directory.appendingPathComponent("fragments.json") }

    /// How stale a marker may be and still be resumed. Long enough to cover a
    /// rebuild, a crash-and-relaunch, or a hunt for the right window; far short
    /// of "the Mac was closed and reopened tomorrow".
    public static let resumeWindow: TimeInterval = 600

    // MARK: - Marker

    public func writeMarker(_ marker: Marker) {
        guard let data = try? encoder.encode(marker) else { return }
        try? data.write(to: markerURL, options: .atomic)
    }

    /// Stamps the marker so a long recording stays resumable. Cheap enough to
    /// call from the level timer.
    public func heartbeat() {
        guard var marker = loadMarker() else { return }
        marker.heartbeatAt = Date()
        writeMarker(marker)
    }

    public func loadMarker() -> Marker? {
        guard let data = try? Data(contentsOf: markerURL) else { return nil }
        return try? decoder.decode(Marker.self, from: data)
    }

    public func clearMarker() {
        try? FileManager.default.removeItem(at: markerURL)
    }

    /// A marker worth resuming: present, and stamped recently enough that the
    /// meeting is plausibly still going on.
    public func resumableMarker(now: Date = Date()) -> Marker? {
        guard let marker = loadMarker() else { return nil }
        guard now.timeIntervalSince(marker.heartbeatAt) <= Self.resumeWindow else {
            // Stale: the Mac was probably closed and reopened another day. Filing
            // is right here — resuming would start recording out of nowhere.
            clearMarker()
            return nil
        }
        return marker
    }

    // MARK: - Fragments

    /// The pieces of one meeting, held across restarts.
    ///
    /// In memory this list already existed for mic recovery; persisting it is
    /// what lets it span more than one run of the app, so a session can be
    /// rebuilt into four times and still come out as one recording.
    public struct Fragment: Codable, Equatable {
        public var startedAt: Date
        public var micAudioPath: String
        public var systemAudioPath: String?
        public var systemAudioStartOffset: Double?

        public init(startedAt: Date, micAudioPath: String,
                    systemAudioPath: String?, systemAudioStartOffset: Double?) {
            self.startedAt = startedAt
            self.micAudioPath = micAudioPath
            self.systemAudioPath = systemAudioPath
            self.systemAudioStartOffset = systemAudioStartOffset
        }
    }

    public func loadFragments() -> [Fragment] {
        guard let data = try? Data(contentsOf: fragmentsURL),
              let all = try? decoder.decode([Fragment].self, from: data) else { return [] }
        // A fragment whose audio has been pruned is worse than no fragment: it
        // would fail assembly and take the good pieces down with it.
        return all.filter { FileManager.default.fileExists(atPath: $0.micAudioPath) }
    }

    public func saveFragments(_ fragments: [Fragment]) {
        guard !fragments.isEmpty else {
            try? FileManager.default.removeItem(at: fragmentsURL)
            return
        }
        guard let data = try? encoder.encode(fragments) else { return }
        try? data.write(to: fragmentsURL, options: .atomic)
    }

    private var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }

    private var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}

public extension RelaunchState {
    /// The app's own store, in Application Support beside history and sessions.
    static func standard(directory: URL) -> RelaunchState { RelaunchState(directory: directory) }
}
