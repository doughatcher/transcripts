import Foundation

/// The handoff contract between a recording device (iPhone, iPad, later Watch)
/// and the Mac that processes the audio.
///
/// Deliberately a *folder*, not an API. The destination is whatever the user
/// points at — a OneDrive or iCloud folder via the iOS document picker, a
/// SharePoint library synced into `~/Library/CloudStorage/…`, or a plain local
/// directory. Every one of those is a File Provider on iOS and an ordinary path
/// on macOS, so neither side needs OAuth, a tenant app registration, or admin
/// consent. Swapping providers is a settings change, not a code change.
///
/// Layout under the chosen root:
/// ```
///   Inbox/
///     3F2B….m4a     ← audio, written first
///     3F2B….json    ← this sidecar, written last (see isComplete)
/// ```
public struct DeviceCapture: Codable, Equatable, Sendable {
    /// Bumped when the on-disk shape changes so an older Mac can refuse a
    /// sidecar it would misread rather than silently dropping fields.
    /// 2 — added `draftTranscript`.
    public static let currentSchema = 2

    public var schema: Int
    public var id: UUID
    /// Human label for where this came from — "Doug's iPhone". Surfaces in the
    /// transcript so a device recording is never mistaken for a Mac capture.
    public var deviceName: String
    public var deviceModel: String
    public var startedAt: Date
    public var duration: TimeInterval
    /// Filename (not path) of the audio beside this sidecar.
    public var audioFilename: String
    /// What the user called it, if they bothered. The pipeline still runs its
    /// own naming pass; this only seeds it.
    public var titleHint: String?
    /// Recording app version, for triaging a bad batch after the fact.
    public var appVersion: String
    /// What the device heard live, if it could. Deliberately *draft*: it comes
    /// from the phone's streaming recognizer with no diarization and no second
    /// pass, so the Mac always re-transcribes from the audio. Its value is that
    /// a capture is readable the moment it lands rather than after the pipeline
    /// runs — never treat it as the transcript of record.
    public var draftTranscript: String?

    public init(
        schema: Int = DeviceCapture.currentSchema,
        id: UUID = UUID(),
        deviceName: String,
        deviceModel: String,
        startedAt: Date,
        duration: TimeInterval,
        audioFilename: String,
        titleHint: String? = nil,
        appVersion: String,
        draftTranscript: String? = nil
    ) {
        self.schema = schema
        self.id = id
        self.deviceName = deviceName
        self.deviceModel = deviceModel
        self.startedAt = startedAt
        self.duration = duration
        self.audioFilename = audioFilename
        self.titleHint = titleHint
        self.appVersion = appVersion
        self.draftTranscript = draftTranscript
    }
}

public enum DeviceInbox {
    public static let folderName = "Inbox"
    public static let processedFolderName = "Processed"

    public static func inbox(under root: URL) -> URL {
        root.appendingPathComponent(folderName, isDirectory: true)
    }

    public static func processed(under root: URL) -> URL {
        root.appendingPathComponent(processedFolderName, isDirectory: true)
    }

    /// A capture ready to import: audio plus its sidecar, both fully on disk.
    public struct Pending: Equatable, Sendable {
        public let capture: DeviceCapture
        public let audio: URL
        public let sidecar: URL
    }

    public enum ScanError: Error, CustomStringConvertible {
        case unreadableRoot(String)

        public var description: String {
            switch self {
            case .unreadableRoot(let p): return "can't read the device inbox at \(p)"
            }
        }
    }

    /// Lists captures that are safe to import.
    ///
    /// Cloud providers materialize a file progressively, so "the .m4a exists" is
    /// not "the .m4a is complete" — importing early yields a truncated recording.
    /// The recorder therefore writes audio first and the sidecar last, and this
    /// scan keys off the sidecar: no sidecar, not ready. A sidecar whose audio is
    /// missing or still a cloud placeholder is skipped this pass, not failed —
    /// it'll be picked up once the download lands.
    public static func pending(under root: URL, fileManager: FileManager = .default) throws -> [Pending] {
        let dir = inbox(under: root)
        guard let entries = try? fileManager.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles])
        else {
            // A missing inbox is an empty inbox — the device may not have synced
            // anything yet. Only an existing-but-unreadable folder is an error.
            if fileManager.fileExists(atPath: dir.path) { throw ScanError.unreadableRoot(dir.path) }
            return []
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var out: [Pending] = []
        for sidecar in entries where sidecar.pathExtension.lowercased() == "json" {
            guard let data = try? Data(contentsOf: sidecar),
                  let capture = try? decoder.decode(DeviceCapture.self, from: data),
                  capture.schema <= DeviceCapture.currentSchema
            else { continue }
            let audio = dir.appendingPathComponent(capture.audioFilename)
            guard isMaterialized(audio, fileManager: fileManager) else { continue }
            out.append(Pending(capture: capture, audio: audio, sidecar: sidecar))
        }
        return out.sorted { $0.capture.startedAt < $1.capture.startedAt }
    }

    /// True when the file exists locally with real bytes. A OneDrive/iCloud
    /// placeholder that hasn't downloaded yet reports zero size (or shows up only
    /// as a `.icloud` stub), and reading it would block or truncate.
    static func isMaterialized(_ url: URL, fileManager: FileManager = .default) -> Bool {
        guard fileManager.fileExists(atPath: url.path) else { return false }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return size > 0
    }

    /// Encoder/decoder pair the recorder and the Mac must agree on.
    public static func makeEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }
}
