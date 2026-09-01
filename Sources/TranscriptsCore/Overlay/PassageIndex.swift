import Foundation

/// One retrievable piece of text with the provenance to show under it.
public struct Passage: Equatable, Sendable {
    public var text: String
    public var source: OverlaySource

    public init(text: String, source: OverlaySource) {
        self.text = text
        self.source = source
    }
}

/// A passage plus how well it matched.
public struct ScoredPassage: Equatable, Sendable {
    public var passage: Passage
    public var score: Double
}

/// A small BM25 index over short passages, with no dependencies.
///
/// It serves both halves of an overlay answer from one scorer: the notes under
/// the knowledge root (built once when a call starts) and the call's own earlier
/// turns (added as they are spoken). Both are "text with a source", and having
/// one ranking function means an answer from a note and an answer from twenty
/// minutes ago are scored comparably rather than by two hand-tuned heuristics.
///
/// Deliberately not a vector store: embeddings would mean a model download and a
/// per-turn inference budget on a machine already running two speech analyzers
/// and a recording. Keyword retrieval over a personal vault is weaker at
/// paraphrase and enormously cheaper, and every result is checked by a person
/// glancing at a HUD.
public final class PassageIndex: @unchecked Sendable {
    /// Caps that keep a large vault from turning a call into a memory problem.
    /// Exceeding one stops indexing rather than failing: a partial index answers
    /// some questions, a crashed recorder answers none.
    public struct Limits: Sendable {
        public var maxFiles: Int
        public var maxFileBytes: Int
        public var maxPassages: Int
        /// Below this a paragraph is a heading or a stub, not an answer.
        public var minPassageChars: Int

        public init(maxFiles: Int = 5_000, maxFileBytes: Int = 1_000_000,
                    maxPassages: Int = 20_000, minPassageChars: Int = 40) {
            self.maxFiles = maxFiles
            self.maxFileBytes = maxFileBytes
            self.maxPassages = maxPassages
            self.minPassageChars = minPassageChars
        }

        public static let `default` = Limits()
    }

    private struct Entry {
        let passage: Passage
        let counts: [String: Int]
        let length: Int
    }

    private var entries: [Entry] = []
    /// term → number of passages containing it.
    private var documentFrequency: [String: Int] = [:]
    private var totalLength = 0
    private let lock = NSLock()

    // Standard BM25 constants; nothing here is tuned to this corpus.
    private static let k1 = 1.5
    private static let b = 0.75

    public init() {}

    public init(passages: [Passage]) {
        for p in passages { add(p) }
    }

    public var count: Int {
        lock.lock(); defer { lock.unlock() }
        return entries.count
    }

    /// Adds one passage. `extraTerms` are indexed but not displayed — used to
    /// fold a note's heading and title into its paragraphs, so "the March
    /// rollout" finds a paragraph under a "March rollout" heading that never
    /// repeats the phrase.
    public func add(_ passage: Passage, extraTerms: String = "") {
        let terms = ExtractiveChatModel.tokenize(passage.text + " " + extraTerms)
        guard !terms.isEmpty else { return }
        var counts: [String: Int] = [:]
        for t in terms { counts[t, default: 0] += 1 }

        lock.lock(); defer { lock.unlock() }
        for t in counts.keys { documentFrequency[t, default: 0] += 1 }
        totalLength += terms.count
        entries.append(Entry(passage: passage, counts: counts, length: terms.count))
    }

    /// Top `limit` passages for a natural-language query, best first. Passages
    /// that share no query term score zero and are never returned, so an
    /// unanswerable question yields an empty array rather than a bad match.
    public func search(_ query: String, limit: Int = 3) -> [ScoredPassage] {
        let queryTerms = Set(ExtractiveChatModel.tokenize(query))
        guard !queryTerms.isEmpty else { return [] }

        lock.lock(); defer { lock.unlock() }
        guard !entries.isEmpty else { return [] }
        let n = Double(entries.count)
        let avgLength = Double(totalLength) / n

        var scored: [ScoredPassage] = []
        for entry in entries {
            var score = 0.0
            for term in queryTerms {
                guard let f = entry.counts[term] else { continue }
                let df = Double(documentFrequency[term] ?? 0)
                let idf = log(1 + (n - df + 0.5) / (df + 0.5))
                let tf = Double(f)
                let norm = tf + Self.k1 * (1 - Self.b + Self.b * Double(entry.length) / max(avgLength, 1))
                score += idf * (tf * (Self.k1 + 1)) / max(norm, .leastNonzeroMagnitude)
            }
            if score > 0 { scored.append(ScoredPassage(passage: entry.passage, score: score)) }
        }
        return Array(scored.sorted { $0.score > $1.score }.prefix(limit))
    }

    // MARK: - Building from the vault

    /// Folder names never indexed. `Inbox`/`Processed` are the device-capture
    /// staging areas — the same recordings that are already filed properly
    /// elsewhere, so indexing them would double-count. Dot-directories cover
    /// `.transcripts/`, where the live transcript of *this* call lives: without
    /// this the overlay could "answer" a question by quoting the question back
    /// out of the file it is itself writing.
    static let skippedDirectories: Set<String> = ["Inbox", "Processed"]
    /// The human-visible live transcript, for the same reason.
    static let skippedFiles: Set<String> = ["Transcripts Live.md", "live.md"]

    /// Indexes every Markdown note under `root`, one passage per paragraph.
    /// Never throws: an unreadable vault yields an empty index, and the overlay
    /// falls back to answering from the call alone.
    public static func vault(root: URL, limits: Limits = .default) -> PassageIndex {
        let index = PassageIndex()
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: root,
                                         includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                                         options: [.skipsHiddenFiles, .skipsPackageDescendants]) else {
            return index
        }

        var files = 0
        for case let url as URL in walker {
            if index.count >= limits.maxPassages { break }
            if url.hasDirectoryPath {
                if skippedDirectories.contains(url.lastPathComponent) { walker.skipDescendants() }
                continue
            }
            guard url.pathExtension.lowercased() == "md",
                  !skippedFiles.contains(url.lastPathComponent) else { continue }
            let values = try? url.resourceValues(forKeys: [.fileSizeKey])
            guard (values?.fileSize ?? 0) <= limits.maxFileBytes else { continue }
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }

            files += 1
            if files > limits.maxFiles { break }
            index.ingest(markdown: text, url: url, limits: limits)
        }
        return index
    }

    /// Splits one note into paragraph passages, carrying its title and the
    /// nearest heading as hidden index terms.
    private func ingest(markdown: String, url: URL, limits: Limits) {
        let (frontmatter, body) = splitFrontmatter(markdown)
        let title = frontmatterTitle(frontmatter) ?? url.deletingPathExtension().lastPathComponent
        let source = OverlaySource.note(title: title, path: url.path)

        var heading = ""
        for block in body.components(separatedBy: "\n\n") {
            if count >= limits.maxPassages { return }
            let trimmed = block.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if trimmed.hasPrefix("#") {
                heading = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
                continue
            }
            guard trimmed.count >= limits.minPassageChars else { continue }
            add(Passage(text: trimmed, source: source), extraTerms: title + " " + heading)
        }
    }

    /// Returns (frontmatter, body). Frontmatter is empty when the file has none.
    private func splitFrontmatter(_ text: String) -> (String, String) {
        guard text.hasPrefix("---\n") else { return ("", text) }
        let rest = String(text.dropFirst(4))
        guard let end = rest.range(of: "\n---\n") else { return ("", text) }
        return (String(rest[..<end.lowerBound]), String(rest[end.upperBound...]))
    }

    private func frontmatterTitle(_ frontmatter: String) -> String? {
        for line in frontmatter.components(separatedBy: "\n") where line.hasPrefix("title:") {
            let value = line.dropFirst("title:".count)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            if !value.isEmpty { return value }
        }
        return nil
    }
}
