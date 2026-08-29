import Foundation

/// Native Persist stage. Writes the produced artifacts to the routed destination
/// under the knowledge root and stamps the transcript's YAML frontmatter with the
/// `plaud-sorter` contract (`sorted: true`, `sorted_to`, `sorted_at`, `sorted_by`).
public struct PersistStage: PipelineStage {
    public let id: StageID = .persist
    private let knowledgeRoot: URL
    private let stampModel: String
    private let copyAudio: Bool
    /// Optional Obsidian vault to mirror the markdown into. See
    /// `DestinationsConfig.vaultMirror`.
    private let vaultMirror: URL?

    public init(config: AppConfig, copyAudio: Bool = true) {
        self.knowledgeRoot = config.destinations.resolvedRoot
        self.stampModel = config.ollama.model
        self.copyAudio = copyAudio
        self.vaultMirror = config.destinations.resolvedVaultMirror
    }

    public init(knowledgeRoot: URL, stampModel: String = "transcripts", copyAudio: Bool = true,
                vaultMirror: URL? = nil) {
        self.knowledgeRoot = knowledgeRoot
        self.stampModel = stampModel
        self.copyAudio = copyAudio
        self.vaultMirror = vaultMirror
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

            // Mirror into the vault, same routed subfolder. Deliberately not
            // fatal: a vault on a disconnected sync folder must not fail the
            // run that already filed the real copy.
            if let vaultMirror {
                do {
                    let mirrorDir = vaultMirror.appendingPathComponent(destRel, isDirectory: true)
                    let mirrorTarget = mirrorDir.appendingPathComponent(name)
                    // A mirror pointed at the knowledge root would write over the
                    // copy just filed — blanking the `audio_file` that copy needs
                    // and leaving the canonical transcript pointing nowhere. The
                    // comparison is deliberately not `==` on URLs: these paths
                    // reach the same file through different spellings, and on a
                    // case-insensitive volume through different capitalisation.
                    guard !Self.sameFile(mirrorTarget, target) else {
                        context.userInfo["vaultMirrorError"] =
                            "vault resolves to the knowledge root — skipped so the filed copy stays intact"
                        throw MirrorSkipped.sameAsKnowledgeRoot
                    }
                    try FileManager.default.createDirectory(at: mirrorDir, withIntermediateDirectories: true)
                    // `audio_file` names a sibling, and in the vault there is no
                    // sibling — the audio stays in the knowledge root. Point at
                    // where it actually is instead of leaving a dangling name.
                    var forVault = stamped
                    if copyAudio {
                        forVault = Self.setFrontmatterKey(forVault, key: "audio_file", value: "")
                        forVault = Self.setFrontmatterKey(
                            forVault, key: "audio_path",
                            value: destDir.appendingPathComponent(audioName).path)
                    }
                    try forVault.write(to: mirrorTarget, atomically: true, encoding: .utf8)
                } catch MirrorSkipped.sameAsKnowledgeRoot {
                    // Already recorded above; not a failure worth a second note.
                } catch {
                    // Core has no logger (it depends on nothing); the Mac reads
                    // this back and writes it to the log.
                    context.userInfo["vaultMirrorError"] = error.localizedDescription
                }
            }
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

    private enum MirrorSkipped: Error { case sameAsKnowledgeRoot }

    /// Whether two URLs name the same file. Compares resource identity when both
    /// exist (which catches symlinks and the two spellings of a synced folder),
    /// and falls back to a case-insensitive path match for the target that has
    /// not been written yet.
    static func sameFile(_ a: URL, _ b: URL) -> Bool {
        let fm = FileManager.default
        if fm.fileExists(atPath: a.path), fm.fileExists(atPath: b.path),
           let ia = try? a.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier,
           let ib = try? b.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier {
            return ia.isEqual(ib)
        }
        return a.standardizedFileURL.path.compare(b.standardizedFileURL.path,
                                                  options: .caseInsensitive) == .orderedSame
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
