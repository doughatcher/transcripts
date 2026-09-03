import Foundation

/// The last library scan, kept on this device so the sidebar has something to
/// draw before iCloud answers.
///
/// The scan itself is not slow because there is much to do — it reads two
/// kilobytes of each transcript and sorts the result. It is slow because every
/// one of those reads goes through a File Provider that may have to fetch the
/// file first, and until the whole walk finished the list was empty. On a
/// library of any size that is five to ten seconds of a blank sidebar on every
/// cold launch, which reads as the app having lost everything.
///
/// So the rows are written down as they were last seen and drawn immediately on
/// the next launch. Nothing here is authoritative: the live scan replaces the
/// list wholesale the moment it lands, so the worst a stale cache can do is show
/// a row a second longer than it deserved.
///
/// Paths are stored relative to the workspace root, never absolute. A File
/// Provider is entitled to move its container out from under us — a reinstall,
/// an iCloud account change, the user re-picking the folder — and absolute URLs
/// written before the move would resolve to files that are not there, turning
/// the whole cache into rows that fail to open. Relative paths are rebuilt
/// against whatever root the bookmark resolves to today.
enum LibraryCache {
    /// One row, flattened. Deliberately its own type rather than making
    /// `TranscriptEntry` Codable: the entry is keyed by an absolute URL and
    /// storing that is the thing this is avoiding.
    private struct Record: Codable {
        let path: String
        let title: String
        let recordedAt: Date?
        let summary: String?
        let folder: String
        let audioFile: String?

        /// nil when the entry somehow sits outside the root it was scanned
        /// under — there is no relative path to write, and an absolute one is
        /// the thing being avoided.
        init?(_ entry: TranscriptEntry, under root: URL) {
            let path = entry.url.standardizedFileURL.path
            let base = root.standardizedFileURL.path
            guard path.hasPrefix(base + "/") else { return nil }
            self.path = String(path.dropFirst(base.count + 1))
            self.title = entry.title
            self.recordedAt = entry.recordedAt
            self.summary = entry.summary
            self.folder = entry.folder
            self.audioFile = entry.audioFile
        }

        func entry(under root: URL) -> TranscriptEntry {
            TranscriptEntry(url: root.appendingPathComponent(path),
                            title: title,
                            recordedAt: recordedAt,
                            summary: summary,
                            folder: folder,
                            audioFile: audioFile)
        }
    }

    private struct Payload: Codable {
        let live: [Record]
        let archived: [Record]
    }

    /// Rows from the last scan of this workspace, or nil if there has not been
    /// one — or if the file is from an older shape and no longer decodes, which
    /// is a cache miss and nothing worse.
    static func load(workspace: UUID, root: URL) -> (live: [TranscriptEntry], archived: [TranscriptEntry])? {
        guard let data = try? Data(contentsOf: file(for: workspace)),
              let payload = try? JSONDecoder().decode(Payload.self, from: data)
        else { return nil }
        return (payload.live.map { $0.entry(under: root) },
                payload.archived.map { $0.entry(under: root) })
    }

    /// Writes what the scan just found. Called off the main actor, from the same
    /// task that did the walk.
    static func save(live: [TranscriptEntry], archived: [TranscriptEntry],
                     workspace: UUID, root: URL) {
        // A scan that found nothing is not proof that there is nothing. iCloud
        // evicts local copies under storage pressure and can have evicted all of
        // them, and the walk skips what it cannot read yet — so an empty result
        // is as likely to mean "not downloaded" as "not there". Overwriting a
        // good list with that would make the next launch blank, which is the
        // failure this file exists to prevent. Keep the last list that had
        // something in it; the live scan still corrects the screen either way.
        guard !(live.isEmpty && archived.isEmpty) else { return }
        let payload = Payload(live: live.compactMap { Record($0, under: root) },
                              archived: archived.compactMap { Record($0, under: root) })
        guard let data = try? JSONEncoder().encode(payload) else { return }
        let url = file(for: workspace)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    /// Application Support rather than Caches: the system may empty Caches
    /// whenever it likes, and a cache the OS is free to drop between launches is
    /// one that helps on the launches that were already going to be fine.
    /// Per workspace, because "Personal" and "Work" are different libraries and
    /// showing one's rows under the other's name would be worse than showing
    /// none.
    private static func file(for workspace: UUID) -> URL {
        URL.applicationSupportDirectory
            .appendingPathComponent("LibraryCache", isDirectory: true)
            .appendingPathComponent("\(workspace.uuidString).json")
    }
}
