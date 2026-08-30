import Foundation

/// A finished transcript sitting in the shared folder.
///
/// These are written by the Mac, into the same iCloud folder the phone syncs
/// into — so once the destination is shared, every device is reading one
/// library rather than each keeping a private list of what it happened to
/// record. The Mac owns *producing* these files; the phone only ever reads
/// them, plus the three tidying changes in `Changing an entry` below.
struct TranscriptEntry: Identifiable, Equatable {
    var id: URL { url }
    let url: URL
    var title: String
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

    /// Splits a document into its frontmatter block and the rest. nil when the
    /// `---` fence isn't there — a caller about to stamp a key needs to know
    /// that rather than invent a header the Mac never wrote.
    static func split(_ raw: String) -> (frontmatter: String, body: String)? {
        guard raw.hasPrefix("---\n"),
              let end = raw.range(of: "\n---\n",
                                  range: raw.index(raw.startIndex, offsetBy: 4)..<raw.endIndex)
        else { return nil }
        return (String(raw[raw.index(raw.startIndex, offsetBy: 4)..<end.lowerBound]),
                String(raw[end.upperBound...]).trimmingCharacters(in: .newlines))
    }

    /// Replaces one frontmatter key — or appends it — and returns the whole
    /// document, quoted and escaped the way the Mac quotes and escapes it.
    ///
    /// The Mac has this function already, in `SummarizeStage`. That file is one
    /// of the ones the iOS target excludes, because it builds the Ollama client
    /// and with it the only `URLSession` in the app — so these few lines live
    /// here rather than dragging a network stack onto a phone that makes no
    /// requests.
    static func setting(_ raw: String, key: String, to value: String) -> String? {
        guard let (frontmatter, body) = split(raw) else { return nil }
        var lines = frontmatter.components(separatedBy: "\n")
        let quoted = "\"\(escape(value))\""
        if let i = lines.firstIndex(where: { $0.hasPrefix("\(key):") }) {
            lines[i] = "\(key): \(quoted)"
        } else {
            lines.append("\(key): \(quoted)")
        }
        return "---\n\(lines.joined(separator: "\n"))\n---\n\n\(body)\n"
    }

    /// A double quote would close the scalar and a newline would end the line.
    /// Same substitutions the Mac makes, so a title typed on the phone and one
    /// written by the Mac survive the same characters.
    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\"", with: "'").replacingOccurrences(of: "\n", with: " ")
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
    /// are the handoff mechanism, not content. So is `Archive`: content the
    /// user has said they are done with, which `scanArchived` lists instead.
    static func scan(root: URL, limit: Int = 300) -> [TranscriptEntry] {
        let fm = FileManager.default
        let skip: Set<String> = [DeviceInbox.folderName, DeviceInbox.processedFolderName,
                                 Self.archiveFolderName]
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
                // Blank means "there is no sibling audio", which is exactly what
                // the vault mirror writes. Kept as Optional("") it would resolve
                // to the containing directory: the pane would offer a player for
                // a file that cannot exist and sit through the whole download
                // retry before admitting it.
                audioFile: fields["audio_file"].flatMap { $0.isEmpty ? nil : $0 }))
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
            // Checked rather than left to `Task.sleep` to report: a swallowed
            // cancellation turns the remaining rounds into a tight loop with no
            // delay between them, each one copying the audio again for a pane
            // the user already navigated away from.
            if Task.isCancelled { return nil }
            if let value = Destination.withScope(bookmark: bookmark, attempt) { return value }
            guard round < 9 else { break }
            do { try await Task.sleep(nanoseconds: 700_000_000) } catch { return nil }
        }
        return nil
    }

    // MARK: - Changing an entry

    /// Renaming, archiving and deleting: the phone writing into the folder the
    /// Mac owns.
    ///
    /// It deliberately did not, for a long time, and the reason it now does has
    /// nothing to do with the Mac's side being wrong. It is that the device in
    /// your hand when a transcript turns out to be mistitled, or private, or not
    /// worth keeping is almost always the phone, and "wait until you are next at
    /// the Mac" is not an answer to any of those.
    ///
    /// What the phone may do is deliberately bounded to changes one device can
    /// make safely to a folder several devices are syncing: a rename touches one
    /// frontmatter key, archiving is a move, deleting is a move to the Trash.
    /// None of it rewrites a transcript's text and none of it is unrecoverable.

    /// Folder archived transcripts move into, at the top of the shared root.
    ///
    /// Capitalised to sit beside `Inbox` and `Processed` rather than looking
    /// like a case folder. The Mac's routing already refuses to treat a folder
    /// called "archive" as a destination, so nothing in here is ever filed into
    /// again.
    static let archiveFolderName = "Archive"

    static func archiveRoot(under root: URL) -> URL {
        root.appendingPathComponent(archiveFolderName, isDirectory: true)
    }

    /// What is in the archive, listed exactly the way the live library is.
    static func scanArchived(root: URL, limit: Int = 300) -> [TranscriptEntry] {
        let dir = archiveRoot(under: root)
        guard FileManager.default.fileExists(atPath: dir.path) else { return [] }
        return scan(root: dir, limit: limit)
    }

    /// Rewrites the `title:` key, leaving the filename alone.
    ///
    /// The same split the Mac makes when you rename there. Titles are written by
    /// a model from what it heard and are wrong often enough to need a way out;
    /// filenames carry the timestamp everything else sorts and links by, and a
    /// note that renames itself under Obsidian's feet takes its backlinks with
    /// it.
    ///
    /// One limit worth being honest about: if the Mac ever reprocesses this
    /// recording it writes a fresh document and the model's title comes back.
    /// Renaming *on* the Mac sets a flag that stops that, and the flag lives in
    /// the Mac's own store rather than in the file, so there is nothing the
    /// phone can write here to claim it.
    nonisolated static func rename(_ entry: TranscriptEntry, to title: String, bookmark: Data) throws {
        try editing(bookmark: bookmark) {
            guard let raw = try? String(contentsOf: entry.url, encoding: .utf8) else {
                // Same placeholder case the reads handle: ask for the file, and
                // say so, rather than reporting a failure the user can't act on.
                try? FileManager.default.startDownloadingUbiquitousItem(at: entry.url)
                throw LibraryEditError.notDownloaded
            }
            guard let updated = TranscriptFrontmatter.setting(raw, key: "title", to: title) else {
                throw LibraryEditError.noFrontmatter
            }
            try updated.write(to: entry.url, atomically: true, encoding: .utf8)
        }
    }

    /// Moves a transcript and its audio into `Archive/`, keeping the folder they
    /// were filed into.
    ///
    /// A move rather than a flag in the file, because the folder *is* the state.
    /// Every device sees it at once with no new key for either app to learn, the
    /// Mac needs no changes to respect it, and if this app vanished tomorrow the
    /// files would still be sitting somewhere a person would look. The routed
    /// subfolder is preserved underneath — `Archive/Acme/transcripts/…` — so
    /// unarchiving lands back where it started and an archived row still says
    /// which client it belonged to.
    nonisolated static func archive(_ entry: TranscriptEntry, root: URL, bookmark: Data) throws {
        try move(entry, from: root, to: archiveRoot(under: root), bookmark: bookmark)
    }

    /// Puts one back where it came from.
    nonisolated static func unarchive(_ entry: TranscriptEntry, root: URL, bookmark: Data) throws {
        try move(entry, from: archiveRoot(under: root), to: root, bookmark: bookmark)
    }

    /// Sends a transcript and its audio to the Trash.
    ///
    /// `trashItem`, never `removeItem` — the line the Mac drew and there is no
    /// reason for the phone to draw it anywhere else. What a recording was worth
    /// is not always clear at the moment you decide it is worth nothing, and on
    /// iOS the Trash is a folder in Files you can walk back into.
    nonisolated static func trash(_ entry: TranscriptEntry, bookmark: Data) throws {
        let fm = FileManager.default
        try editing(bookmark: bookmark) {
            // The audio first, and forgivingly: a transcript whose sibling has
            // already gone must still be removable, and the markdown is the row.
            if let audio = entry.audioURL, fm.fileExists(atPath: audio.path) {
                try? fm.trashItem(at: audio, resultingItemURL: nil)
            }
            try fm.trashItem(at: entry.url, resultingItemURL: nil)
        }
    }

    /// Moves an entry's markdown and its sibling audio together, preserving the
    /// path they held under `from`.
    private nonisolated static func move(_ entry: TranscriptEntry, from base: URL,
                                         to destination: URL, bookmark: Data) throws {
        let fm = FileManager.default
        let folder = destination.appendingPathComponent(
            relativePath(of: entry.url.deletingLastPathComponent(), under: base),
            isDirectory: true)
        try editing(bookmark: bookmark) {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            // Audio first: if it fails the markdown hasn't moved, so the row is
            // still where the user left it rather than half-archived.
            var renamedAudio: String?
            if let audio = entry.audioURL, fm.fileExists(atPath: audio.path) {
                let name = free(audio.lastPathComponent, in: folder)
                try fm.moveItem(at: audio, to: folder.appendingPathComponent(name))
                if name != audio.lastPathComponent { renamedAudio = name }
            }
            let markdown = folder.appendingPathComponent(free(entry.url.lastPathComponent, in: folder))
            try fm.moveItem(at: entry.url, to: markdown)
            // Only when a collision forced a new name: `audio_file` names a
            // sibling, and the pointer has to follow the file it points at.
            if let renamedAudio,
               let raw = try? String(contentsOf: markdown, encoding: .utf8),
               let updated = TranscriptFrontmatter.setting(raw, key: "audio_file", to: renamedAudio) {
                try? updated.write(to: markdown, atomically: true, encoding: .utf8)
            }
        }
    }

    /// `name`, or `name-2`, `name-3` … — the first that isn't taken in `dir`.
    ///
    /// A name already in use means a different transcript filed under the same
    /// one, which the Mac's stamped filenames make rare and don't make
    /// impossible. Overwriting it would lose it, so the arrival takes a new name
    /// and the resident keeps its own.
    private nonisolated static func free(_ name: String, in dir: URL) -> String {
        let fm = FileManager.default
        guard fm.fileExists(atPath: dir.appendingPathComponent(name).path) else { return name }
        let parsed = URL(fileURLWithPath: name)
        let stem = parsed.deletingPathExtension().lastPathComponent
        let ext = parsed.pathExtension.isEmpty ? "" : ".\(parsed.pathExtension)"
        var n = 2
        while fm.fileExists(atPath: dir.appendingPathComponent("\(stem)-\(n)\(ext)").path) { n += 1 }
        return "\(stem)-\(n)\(ext)"
    }

    /// The path of `url` beneath `base`, or "" when it isn't beneath it.
    ///
    /// Standardized first, because the same folder reaches us spelled two ways:
    /// once by resolving the bookmark, once from the enumerator that walked it.
    /// The boundary check is what stops `…/Transcripts` matching the prefix of
    /// `…/TranscriptsOld` and filing an archive one directory too high.
    private nonisolated static func relativePath(of url: URL, under base: URL) -> String {
        let path = url.standardizedFileURL.path
        let root = base.standardizedFileURL.path
        guard path == root || path.hasPrefix(root + "/") else { return "" }
        return String(path.dropFirst(root.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    /// Runs a change with the workspace's security scope open and the write
    /// coordinated.
    ///
    /// The reads above tolerate a File Provider being slow; a write has to
    /// tolerate it being opinionated. An uncoordinated write races the sync
    /// daemon, which is entitled to ignore or undo it — the failure that looks
    /// like a rename working, surviving a relaunch out of a local shadow copy,
    /// and being gone the next morning.
    private nonisolated static func editing(bookmark: Data, _ body: () throws -> Void) throws {
        guard let granted = Destination.resolve(bookmark) else { throw LibraryEditError.noWorkspace }
        let opened = granted.startAccessingSecurityScopedResource()
        defer { if opened { granted.stopAccessingSecurityScopedResource() } }
        try Destination.coordinatedWrite(at: granted) { _ in try body() }
    }

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func date(_ s: String) -> Date? { iso.date(from: s) }
}

/// Why a tidy-up couldn't happen. Every case is something the user can do
/// something about, which is the bar for surfacing an error at all.
enum LibraryEditError: Error, LocalizedError {
    case notDownloaded
    case noFrontmatter
    case noWorkspace

    var errorDescription: String? {
        switch self {
        case .notDownloaded:
            return "That transcript hasn't finished syncing to this device. Open it once to fetch it, then try again."
        case .noFrontmatter:
            return "That transcript has no frontmatter, so there is no title to change."
        case .noWorkspace:
            return "The folder this library lives in is no longer available. Pick it again from the bar at the bottom of the list."
        }
    }
}
