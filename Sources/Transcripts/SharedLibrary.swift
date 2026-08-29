import Foundation

/// A finished transcript sitting in the shared folder.
///
/// These are written by the Mac, into the same iCloud folder the phone syncs
/// into — so once the destination is shared, every device is reading one
/// library rather than each keeping a private list of what it happened to
/// record. The phone never writes here; the Mac owns this side.
struct TranscriptEntry: Identifiable, Equatable {
    var id: URL { url }
    let url: URL
    let title: String
    let recordedAt: Date?
    let summary: String?
    /// Folder it was filed into, relative to the root — the Mac's routing
    /// decision, worth showing because it says which case or client it belongs
    /// to.
    let folder: String
    /// Name of the sibling audio file the Mac archived next to the markdown —
    /// the `audio_file` frontmatter key. nil for text-only notes and for
    /// transcripts written before the Mac kept audio.
    let audioFile: String?

    /// Where that audio lives: same folder, the name the frontmatter says.
    var audioURL: URL? {
        audioFile.map { url.deletingLastPathComponent().appendingPathComponent($0) }
    }
}

enum TranscriptFrontmatter {
    /// Minimal YAML-ish reader for the handful of keys the Mac writes. A real
    /// YAML parser would be a dependency for four fields in a file this app
    /// only ever reads.
    static func parse(_ raw: String) -> [String: String] {
        guard raw.hasPrefix("---") else { return [:] }
        var fields: [String: String] = [:]
        for line in raw.components(separatedBy: "\n").dropFirst() {
            if line.hasPrefix("---") { break }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[line.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
            var value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            value = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            if !key.isEmpty { fields[key] = value }
        }
        return fields
    }

    static func stripFrontmatter(_ raw: String) -> String {
        guard raw.hasPrefix("---") else { return raw }
        let lines = raw.components(separatedBy: "\n")
        guard let end = lines.dropFirst().firstIndex(where: { $0.hasPrefix("---") }) else { return raw }
        return lines[(end + 1)...].joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum SharedLibrary {
    /// Finds every transcript under the shared root.
    ///
    /// Scans for `transcripts/` folders the way the Mac's routing does, so a
    /// library organised into per-client folders lists completely rather than
    /// only what sits at the top level. `Inbox`/`Processed` are skipped: those
    /// are the handoff mechanism, not content.
    static func scan(root: URL, limit: Int = 300) -> [TranscriptEntry] {
        let fm = FileManager.default
        let skip: Set<String> = [DeviceInbox.folderName, DeviceInbox.processedFolderName]
        guard let walker = fm.enumerator(at: root,
                                         includingPropertiesForKeys: [.isDirectoryKey],
                                         options: [.skipsHiddenFiles]) else { return [] }

        var found: [TranscriptEntry] = []
        for case let url as URL in walker {
            if skip.contains(url.lastPathComponent) {
                walker.skipDescendants()
                continue
            }
            guard url.pathExtension.lowercased() == "md" else { continue }
            // Only read the head: frontmatter is the first few hundred bytes
            // and the body can be enormous. A `FileHandle` actually honours
            // that — `String(contentsOf:)` was paging whole meetings into
            // memory on every foreground refresh just to learn their titles.
            // Empty counts as unreadable, not as a file with no frontmatter.
            // `String(contentsOf:)` used to throw on a transcript iCloud hadn't
            // materialised; opening the same placeholder by file handle can
            // instead succeed and hand back nothing, which would list the file
            // under its own filename, with no date and no audio, and never ask
            // for the download that would fix it.
            guard let head = Self.head(of: url), !head.isEmpty else {
                // A transcript the Mac has written but this device hasn't pulled
                // down yet is a placeholder, not a missing file. Silently
                // skipping it made a freshly-shared library look half-empty, so
                // ask for it and let the next scan find it materialised.
                try? fm.startDownloadingUbiquitousItem(at: url)
                continue
            }
            let fields = TranscriptFrontmatter.parse(head)
            let folder = url.deletingLastPathComponent().lastPathComponent
            found.append(TranscriptEntry(
                url: url,
                title: fields["title"] ?? url.deletingPathExtension().lastPathComponent,
                recordedAt: fields["recorded_at"].flatMap(Self.date),
                summary: fields["description"],
                folder: folder,
                audioFile: fields["audio_file"]))
            if found.count >= limit { break }
        }
        return found.sorted {
            ($0.recordedAt ?? .distantPast) > ($1.recordedAt ?? .distantPast)
        }
    }

    /// First ~2 KB of the file as text, or nil if it can't be opened. Lossy
    /// decoding, because 2048 bytes can land mid-character — the tail is
    /// garbage past the frontmatter either way.
    private static func head(of url: URL) -> String? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        guard let data = try? fh.read(upToCount: 2048) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Opening an entry

    /// Markdown below the frontmatter, or nil if the file can't be read yet.
    ///
    /// The scan borrows the workspace's security scope for its walk and closes
    /// it again, so a read that happens later — a transcript actually opened —
    /// must bring its own. Reading without it fails silently on any picked
    /// folder, which on the iPad looked like a library of transcripts with
    /// titles and no text. iCloud adds the second failure mode: a file can be
    /// listed but not yet local, so a failed read asks for the download and
    /// retries briefly rather than giving up on the first attempt.
    nonisolated static func body(of entry: TranscriptEntry, bookmark: Data) async -> String? {
        await retrying(bookmark: bookmark) { () -> String? in
            if let raw = try? String(contentsOf: entry.url, encoding: .utf8) {
                return TranscriptFrontmatter.stripFrontmatter(raw)
            }
            try? FileManager.default.startDownloadingUbiquitousItem(at: entry.url)
            return nil
        }
    }

    /// A locally playable copy of the entry's archived audio, or nil when
    /// there is none or it hasn't synced to this device yet.
    ///
    /// `AVAudioPlayer` holds the file for the whole listen, and the security
    /// scope would have to stay open just as long. Copying into our own tmp
    /// keeps the scope discipline in one place: open, copy, close, then play
    /// the copy with no strings attached. Keyed by size so replaying a
    /// transcript doesn't copy the meeting twice, and tmp means the system
    /// reclaims the space instead of us bookkeeping it.
    nonisolated static func localAudio(for entry: TranscriptEntry, bookmark: Data) async -> URL? {
        guard let source = entry.audioURL else { return nil }
        let fm = FileManager.default
        let cacheDir = fm.temporaryDirectory.appendingPathComponent("shared-audio", isDirectory: true)
        try? fm.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        return await retrying(bookmark: bookmark) { () -> URL? in
            guard let size = try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
                try? fm.startDownloadingUbiquitousItem(at: source)
                return nil
            }
            let target = cacheDir.appendingPathComponent("\(size)-\(source.lastPathComponent)")
            if fm.fileExists(atPath: target.path) { return target }
            // Copy to a staging name and rename into place, rather than copying
            // straight to the final one. A copy that dies partway — the sync
            // folder going away mid-read, the app suspended on a long meeting —
            // leaves the bytes it managed behind, and a truncated file sitting
            // at the final name is indistinguishable from a finished one: every
            // later play would take it as a cache hit and stop half way. The
            // rename is atomic within the volume, so the final name only ever
            // appears complete.
            let staging = cacheDir.appendingPathComponent("partial-\(UUID().uuidString)")
            do {
                try fm.copyItem(at: source, to: staging)
                try fm.moveItem(at: staging, to: target)
                return target
            } catch {
                try? fm.removeItem(at: staging)
                // Another pass may have finished the same copy while this one
                // ran; its file is complete, so use it.
                if fm.fileExists(atPath: target.path) { return target }
                // A placeholder reports its size but can't be copied until the
                // bytes arrive — same recovery as an unreadable file.
                try? fm.startDownloadingUbiquitousItem(at: source)
                return nil
            }
        }
    }

    /// Runs `attempt` under the workspace scope until it produces a value,
    /// giving iCloud a bounded few seconds to materialise the file in between.
    private nonisolated static func retrying<T>(bookmark: Data, _ attempt: () -> T?) async -> T? {
        for round in 0..<10 {
            if let value = Destination.withScope(bookmark: bookmark, attempt) { return value }
            guard round < 9 else { break }
            try? await Task.sleep(nanoseconds: 700_000_000)
        }
        return nil
    }

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func date(_ s: String) -> Date? { iso.date(from: s) }
}
