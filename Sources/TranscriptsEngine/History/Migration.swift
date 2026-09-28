import Foundation

/// One edition's user state, packaged to move to another copy of the app.
///
/// The two Mac editions keep their state in different places — the direct
/// download in `~/Library/Application Support/Transcripts`, the store build
/// inside its sandbox container — and nothing outside the app can bridge them
/// well: TCC blocks scripted copies into a container, Finder drops files that
/// carry `com.apple.macl` attributes, and the result can't even be listed to
/// check. So the app moves its own state. The bundle is plain JSON (voices are
/// base64), which lets `export` write it to stdout and `import` read it from
/// stdin — file handles the sandbox never restricts — so the two editions can
/// be piped together, by a person or by an agent.
///
/// The transcripts themselves are not in here. They are ordinary files in the
/// library folder, which both editions read in place; what moves is the state
/// around them — the recordings list and the remembered voices.
public struct MigrationBundle: Codable {
    public var version: Int
    public var exportedAt: Date
    public var history: [RecordingRecord]
    /// `speakers.json` verbatim: the schema is the diarizer's own, and an
    /// export must not fail because a future field is unknown to this build.
    public var speakers: Data?
    /// Voice samples by path relative to `voices/` (enrolled/…, meetings/…).
    public var voices: [String: Data]

    public static let currentVersion = 1
}

public enum Migration {

    public struct Summary {
        public var recordsImported = 0
        public var recordsKept = 0
        public var speakersImported = false
        public var speakersKept = false
        public var voiceFilesImported = 0

        public var description: String {
            var parts: [String] = []
            parts.append(recordsImported == 1 ? "1 recording imported"
                                              : "\(recordsImported) recordings imported")
            if recordsKept > 0 { parts.append("\(recordsKept) already here") }
            if speakersImported { parts.append("voice profiles imported") }
            if speakersKept { parts.append("kept this copy's voice profiles") }
            if voiceFilesImported > 0 { parts.append("\(voiceFilesImported) voice samples") }
            return parts.joined(separator: ", ") + "."
        }
    }

    /// Packages the state found in a support directory. Missing pieces are
    /// simply absent — an export from a fresh install is a valid, empty bundle.
    public static func exportBundle(from dir: URL = HistoryStore.dir) -> MigrationBundle {
        let fm = FileManager.default
        var voices: [String: Data] = [:]
        let voicesDir = dir.appendingPathComponent("voices", isDirectory: true)
        if let walk = fm.enumerator(at: voicesDir, includingPropertiesForKeys: [.isRegularFileKey]) {
            for case let file as URL in walk {
                guard (try? file.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
                      let data = try? Data(contentsOf: file) else { continue }
                let relative = file.path.dropFirst(voicesDir.path.count + 1)
                voices[String(relative)] = data
            }
        }
        return MigrationBundle(
            version: MigrationBundle.currentVersion,
            exportedAt: Date(),
            history: HistoryStore(directory: dir).records,
            speakers: try? Data(contentsOf: dir.appendingPathComponent("speakers.json")),
            voices: voices)
    }

    /// Merges a bundle into this copy's state. Additive only: a record already
    /// in the history, an existing `speakers.json`, a voice sample already on
    /// disk are all left alone — importing must be safe to run twice, and safe
    /// on a copy that has already recorded meetings of its own.
    public static func apply(_ bundle: MigrationBundle,
                             history: HistoryStore,
                             filesDir: URL = HistoryStore.dir) -> Summary {
        let fm = FileManager.default
        var summary = Summary()

        for record in bundle.history {
            if history.record(record.id) != nil {
                summary.recordsKept += 1
            } else {
                history.upsert(record)
                summary.recordsImported += 1
            }
        }

        if let speakers = bundle.speakers, !speakers.isEmpty {
            let target = filesDir.appendingPathComponent("speakers.json")
            if fm.fileExists(atPath: target.path) {
                summary.speakersKept = true
            } else if (try? speakers.write(to: target, options: .atomic)) != nil {
                summary.speakersImported = true
            }
        }

        let voicesDir = filesDir.appendingPathComponent("voices", isDirectory: true)
        for (relative, data) in bundle.voices.sorted(by: { $0.key < $1.key }) {
            // The keys name the files; harden against a crafted bundle walking out.
            let target = voicesDir.appendingPathComponent(relative).standardizedFileURL
            guard target.path.hasPrefix(voicesDir.path + "/"),
                  !fm.fileExists(atPath: target.path) else { continue }
            try? fm.createDirectory(at: target.deletingLastPathComponent(),
                                    withIntermediateDirectories: true)
            if (try? data.write(to: target, options: .atomic)) != nil {
                summary.voiceFilesImported += 1
            }
        }

        Log.write("migration: \(summary.description)")
        return summary
    }

    /// Reads another support directory as a bundle, for the Settings import —
    /// the open panel that picked the folder is also what lets a sandboxed
    /// build read it. History decodes record by record, same as `load()`.
    public static func read(supportDir dir: URL) -> MigrationBundle {
        exportBundle(from: dir)
    }

    // MARK: - Bundle encoding (the CLI's wire format)

    public static func encode(_ bundle: MigrationBundle) throws -> Data {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return try e.encode(bundle)
    }

    public static func decode(_ data: Data) throws -> MigrationBundle {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return try d.decode(MigrationBundle.self, from: data)
    }
}
