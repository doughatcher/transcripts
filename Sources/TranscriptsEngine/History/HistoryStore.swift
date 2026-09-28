import Foundation

/// One durable record of a recording and what happened to it. Persisted so the
/// menu's "Recent" list survives relaunches and so interrupted/failed work can be
/// recovered — this is a business tool, it must not silently lose a recording.
public struct RecordingRecord: Codable, Identifiable, Equatable {
    public enum Status: String, Codable {
        case recording   // capture in progress (interrupted if seen at launch)
        case processing  // captured, pipeline running (interrupted if seen at launch)
        case completed   // filed successfully
        case failed      // pipeline errored; retryable if audio still exists
    }

    public var id: UUID
    public var title: String
    public var recordedAt: Date
    public var endedAt: Date?
    public var activeApp: String?
    public var isCall: Bool
    public var status: Status
    /// Durable directory holding the captured audio (under Application Support).
    public var captureDir: String?
    /// The audio actually used/produced (mixed for calls).
    public var audioPath: String?
    /// The persisted `.md` document.
    public var documentPath: String?
    public var destination: String?
    public var errorText: String?
    /// Stable identity for the call this belongs to (meeting name + day), so
    /// fragments of one call group together. Nil for notes and one-off recordings.
    /// Optional so older `history.json` (without the field) still decodes.
    public var callKey: String?
    /// The title came from the meeting window — a good provisional name, but the
    /// summary's content-derived title supersedes it once available.
    public var namedFromWindow: Bool?
    /// The user explicitly renamed this recording — never overwrite automatically.
    public var renamedByUser: Bool?
    /// The recorder captured effectively no audio (dead/muted mic). Such a record is
    /// shown greyed as "No audio captured" rather than with a hallucinated title.
    public var silent: Bool?

    public init(id: UUID, title: String, recordedAt: Date, endedAt: Date? = nil,
                activeApp: String? = nil, isCall: Bool, status: Status,
                captureDir: String? = nil, audioPath: String? = nil,
                documentPath: String? = nil, destination: String? = nil,
                errorText: String? = nil, callKey: String? = nil,
                namedFromWindow: Bool? = nil, renamedByUser: Bool? = nil,
                silent: Bool? = nil) {
        self.id = id; self.title = title; self.recordedAt = recordedAt
        self.endedAt = endedAt; self.activeApp = activeApp; self.isCall = isCall
        self.status = status; self.captureDir = captureDir; self.audioPath = audioPath
        self.documentPath = documentPath; self.destination = destination
        self.errorText = errorText; self.callKey = callKey
        self.namedFromWindow = namedFromWindow; self.renamedByUser = renamedByUser
        self.silent = silent
    }

    public var documentURL: URL? { documentPath.map { URL(fileURLWithPath: $0) } }
    public var audioURL: URL? { audioPath.map { URL(fileURLWithPath: $0) } }

    /// Nothing usable was captured (silent mic). Drives the greyed "empty" display.
    public var isEmpty: Bool { silent == true }
}

/// Persists `[RecordingRecord]` to `~/Library/Application Support/Transcripts/history.json`
/// and owns the durable capture directory. Small JSON, written atomically.
public final class HistoryStore {
    /// `~/Library/Application Support/Transcripts`
    public static let dir: URL = {
        // An explicit override rather than relying on $HOME: Foundation resolves
        // the Application Support directory from the process owner, not the
        // environment, so relocating HOME leaves this pointing at the real
        // history. The screenshot harness needs a second copy of the app to read
        // a generated history without seeing anyone's actual recordings.
        if let override = ProcessInfo.processInfo.environment["TRANSCRIPTS_SUPPORT_DIR"],
           !override.isEmpty {
            let base = URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
            try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            return base
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Transcripts", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    /// Durable location for in-flight captures — survives crashes and OS temp cleanup.
    public static var capturesDir: URL {
        let d = dir.appendingPathComponent("captures", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private let url: URL
    public private(set) var records: [RecordingRecord] = []

    public convenience init() { self.init(directory: HistoryStore.dir) }

    /// An explicit directory, for tests and for tools that operate on another
    /// edition's history without adopting its support directory.
    public init(directory: URL) {
        url = directory.appendingPathComponent("history.json")
        load()
    }

    public func load() {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else {
            records = []
            return
        }
        // Not one decode of the whole array: a single record this build cannot
        // read — a status case added later, a hand-edit, a truncated write —
        // must cost that record, not all of them. The store edition once opened
        // a migrated history this way, kept none of its 22 records, and then
        // saved over the file, which is why the failures below also preserve
        // the original before any save can happen.
        let (decoded, dropped) = Self.decodeRecords(from: data)
        if dropped > 0 {
            preserveUnreadable(data)
            Log.write("history: loaded \(decoded.count) record(s), " +
                      "could not decode \(dropped) — original preserved")
        }
        records = decoded.sorted { $0.recordedAt > $1.recordedAt }
    }

    /// Decodes as many records as the data yields: the whole-array fast path
    /// first, then record by record. `dropped` counts what didn't decode.
    public static func decodeRecords(from data: Data) -> (records: [RecordingRecord], dropped: Int) {
        if let decoded = try? JSONDecoder.iso.decode([RecordingRecord].self, from: data) {
            return (decoded, 0)
        }
        guard let array = (try? JSONSerialization.jsonObject(with: data)) as? [Any] else {
            // Not even an array: nothing salvageable, but very much a failure.
            return ([], 1)
        }
        var out: [RecordingRecord] = []
        var dropped = 0
        for element in array {
            guard element is [String: Any],
                  let fragment = try? JSONSerialization.data(withJSONObject: element),
                  let record = try? JSONDecoder.iso.decode(RecordingRecord.self, from: fragment) else {
                dropped += 1
                continue
            }
            out.append(record)
        }
        return (out, dropped)
    }

    /// Keeps the bytes a load couldn't fully read beside the file, once — the
    /// first failure is the interesting one, and the next save would otherwise
    /// be the last anyone saw of them.
    private func preserveUnreadable(_ data: Data) {
        let keep = url.appendingPathExtension("rejected")
        guard !FileManager.default.fileExists(atPath: keep.path) else { return }
        try? data.write(to: keep, options: .atomic)
    }

    public func record(_ id: UUID) -> RecordingRecord? { records.first { $0.id == id } }

    public func remove(_ id: UUID) {
        records.removeAll { $0.id == id }
        save()
    }

    public func upsert(_ r: RecordingRecord) {
        if let i = records.firstIndex(where: { $0.id == r.id }) {
            records[i] = r
        } else {
            records.append(r)
        }
        records.sort { $0.recordedAt > $1.recordedAt }
        // Keep the file bounded but generous.
        if records.count > 500 { records = Array(records.prefix(500)) }
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder.isoPretty.encode(records) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

private extension JSONDecoder {
    static let iso: JSONDecoder = {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d
    }()
}
private extension JSONEncoder {
    static let isoPretty: JSONEncoder = {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.prettyPrinted, .sortedKeys]; return e
    }()
}
