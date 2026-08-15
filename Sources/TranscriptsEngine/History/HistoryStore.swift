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

    private let url = HistoryStore.dir.appendingPathComponent("history.json")
    public private(set) var records: [RecordingRecord] = []

    public init() { load() }

    public func load() {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder.iso.decode([RecordingRecord].self, from: data) else {
            records = []
            return
        }
        records = decoded.sorted { $0.recordedAt > $1.recordedAt }
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
