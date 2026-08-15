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

    /// Markdown below the frontmatter. Read lazily: a library of long meetings
    /// is megabytes of text nobody has asked to see yet.
    func body() -> String {
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return TranscriptFrontmatter.stripFrontmatter(raw)
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
            // Only read the head: frontmatter is the first few hundred bytes and
            // the body can be enormous.
            guard let raw = try? String(contentsOf: url, encoding: .utf8) else {
                // A transcript the Mac has written but this device hasn't pulled
                // down yet is a placeholder, not a missing file. Silently
                // skipping it made a freshly-shared library look half-empty, so
                // ask for it and let the next scan find it materialised.
                try? fm.startDownloadingUbiquitousItem(at: url)
                continue
            }
            let fields = parseHead(raw)
            let folder = url.deletingLastPathComponent().lastPathComponent
            found.append(TranscriptEntry(
                url: url,
                title: fields["title"] ?? url.deletingPathExtension().lastPathComponent,
                recordedAt: fields["recorded_at"].flatMap(Self.date),
                summary: fields["description"],
                folder: folder))
            if found.count >= limit { break }
        }
        return found.sorted {
            ($0.recordedAt ?? .distantPast) > ($1.recordedAt ?? .distantPast)
        }
    }

    private static func parseHead(_ raw: String) -> [String: String] {
        TranscriptFrontmatter.parse(String(raw.prefix(2000)))
    }

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func date(_ s: String) -> Date? { iso.date(from: s) }
}
