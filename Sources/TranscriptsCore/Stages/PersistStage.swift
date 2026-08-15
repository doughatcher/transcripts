import Foundation

/// Native Persist stage. Writes the produced artifacts to the routed destination
/// under the knowledge root and stamps the transcript's YAML frontmatter with the
/// `plaud-sorter` contract (`sorted: true`, `sorted_to`, `sorted_at`, `sorted_by`).
public struct PersistStage: PipelineStage {
    public let id: StageID = .persist
    private let knowledgeRoot: URL
    private let stampModel: String
    private let copyAudio: Bool

    public init(config: AppConfig, copyAudio: Bool = true) {
        self.knowledgeRoot = config.destinations.resolvedRoot
        self.stampModel = config.ollama.model
        self.copyAudio = copyAudio
    }

    public init(knowledgeRoot: URL, stampModel: String = "transcripts", copyAudio: Bool = true) {
        self.knowledgeRoot = knowledgeRoot
        self.stampModel = stampModel
        self.copyAudio = copyAudio
    }

    public func run(_ context: inout PipelineContext) async throws {
        let destRel = context.routing?.destination ?? "transcripts/"
        let destDir = knowledgeRoot.appendingPathComponent(destRel, isDirectory: true)
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)

        var written: [URL] = []

        // Standard base name: `<stamp>-<title-slug>` once the summary produced a
        // content-derived title, else the record-time slug (`<stamp>-<app-tag>`).
        // Notes and summarizer-down runs have no summaryTitle and keep their names.
        let titledBase = context.userInfo["summaryTitle"].map { context.recording.slug(titled: $0) }

        let audioURL = context.archivedAudioURL ?? context.recording.audioURL
        let audioExt = audioURL.pathExtension.isEmpty ? "m4a" : audioURL.pathExtension
        let audioName = (titledBase ?? context.userInfo["slug"]).map { "\($0).\(audioExt)" }
            ?? audioURL.lastPathComponent

        // Transcript (with frontmatter stamp).
        if let transcriptURL = context.transcriptURL {
            let name = titledBase.map { "\($0).md" } ?? transcriptURL.lastPathComponent
            let target = destDir.appendingPathComponent(name)
            let original = try String(contentsOf: transcriptURL, encoding: .utf8)
            var stamped = stampFrontmatter(original, destination: destRel, note: context.routing?.note)
            if copyAudio {
                // Keep the pointer to the sibling audio in sync with the rename.
                stamped = Self.setFrontmatterKey(stamped, key: "audio_file", value: audioName)
            }
            try stamped.write(to: target, atomically: true, encoding: .utf8)
            written.append(target)
        }

        // Summary (if separate from the transcript).
        if let summaryURL = context.summaryURL {
            let target = destDir.appendingPathComponent(summaryURL.lastPathComponent)
            try copyReplacing(from: summaryURL, to: target)
            written.append(target)
        }

        // Archive audio under the same unique base name as the transcript, so
        // parallel recordings never clobber each other's `audio.m4a`.
        if copyAudio {
            let target = destDir.appendingPathComponent(audioName)
            try copyReplacing(from: audioURL, to: target)
            written.append(target)
        }

        context.finalPaths = written
    }

    /// Replaces (or inserts) a single frontmatter key in a full `---`-fenced doc.
    static func setFrontmatterKey(_ doc: String, key: String, value: String) -> String {
        guard doc.hasPrefix("---\n") else { return doc }
        let (fm, body) = SummarizeStage.splitFrontmatter(doc)
        return "---\n\(SummarizeStage.upsert(fm, key: key, value: value))\n---\n\n\(body)\n"
    }

    private func copyReplacing(from: URL, to: URL) throws {
        if FileManager.default.fileExists(atPath: to.path) {
            try FileManager.default.removeItem(at: to)
        }
        try FileManager.default.copyItem(at: from, to: to)
    }

    /// Appends the sorter stamp keys to existing frontmatter, or wraps the body in
    /// fresh frontmatter. Never reorders the user's existing keys (matches
    /// classify-sort.py's append-only behavior).
    private func stampFrontmatter(_ text: String, destination: String, note: String?) -> String {
        let now = ISO8601DateFormatter().string(from: Date())
        var stamp = [
            "sorted: true",
            "sorted_to: \(destination)",
            "sorted_at: \(now)",
            "sorted_by: \(stampModel)",
        ]
        if let note, !note.isEmpty {
            let escaped = note.replacingOccurrences(of: "\n", with: " ")
            stamp.append("sorted_note: \"\(escaped)\"")
        }

        if text.hasPrefix("---\n"),
           let end = text.range(of: "\n---\n", range: text.index(text.startIndex, offsetBy: 4)..<text.endIndex) {
            let fm = String(text[text.index(text.startIndex, offsetBy: 4)..<end.lowerBound])
            let body = String(text[end.upperBound...])
            return "---\n\(fm)\n\(stamp.joined(separator: "\n"))\n---\n\(body)"
        }
        return "---\n\(stamp.joined(separator: "\n"))\n---\n\(text)"
    }
}
