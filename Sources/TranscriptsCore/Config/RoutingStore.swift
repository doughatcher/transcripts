import Foundation

/// Loads/saves the routing config from `<knowledgeRoot>/.transcripts/routing.json`,
/// seeding it on first use by discovering `*/transcripts/` folders in the vault.
public final class RoutingStore {
    private let knowledgeRoot: URL
    private let url: URL

    public init(knowledgeRoot: URL) {
        self.knowledgeRoot = knowledgeRoot
        self.url = knowledgeRoot.appendingPathComponent(".transcripts/routing.json")
    }

    public var fileURL: URL { url }

    /// Returns the config, creating a seeded file if none exists.
    public func loadOrSeed() -> RoutingConfig {
        if let data = try? Data(contentsOf: url),
           let cfg = try? JSONDecoder().decode(RoutingConfig.self, from: data) {
            return cfg
        }
        var seeded = RoutingConfig.default
        seeded.destinations = Self.discover(in: knowledgeRoot)
        try? save(seeded)
        return seeded
    }

    public func save(_ config: RoutingConfig) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(config).write(to: url, options: .atomic)
    }

    /// The set of destinations to consider: the configured ones unioned with freshly
    /// discovered `*/transcripts/` folders (so new cases become eligible without
    /// editing the file). Configured keywords win.
    public func effectiveDestinations(_ config: RoutingConfig) -> [RoutingConfig.Destination] {
        var byPath: [String: RoutingConfig.Destination] = [:]
        for d in Self.discover(in: knowledgeRoot) { byPath[d.path] = d }
        for d in config.destinations { byPath[d.path] = d }   // curated overrides discovered
        return byPath.values.sorted { $0.path < $1.path }
    }

    // MARK: - Discovery

    /// Finds folders named `transcripts` up to a few levels deep and turns each into
    /// a destination whose keywords are tokens of its parent folder name.
    /// Folders never scanned for destinations (archived cases, build/dev noise).
    static let excluded: Set<String> = [
        "archive", ".git", ".build", ".transcripts", "node_modules", "templates",
        "deck transfers", "dist", "justfiles", "scripts",
    ]

    static func discover(in root: URL) -> [RoutingConfig.Destination] {
        let fm = FileManager.default
        var results: [RoutingConfig.Destination] = []

        func scan(_ dir: URL, depth: Int) {
            guard depth <= 3 else { return }
            guard let entries = try? fm.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
            ) else { return }
            for entry in entries {
                let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                guard isDir else { continue }
                let name = entry.lastPathComponent
                if Self.excluded.contains(name.lowercased()) { continue }
                if name.lowercased() == "transcripts" {   // match Transcripts/transcripts alike
                    let rel = relativePath(entry, to: root)
                    let parent = entry.deletingLastPathComponent().lastPathComponent
                    results.append(.init(path: rel, keywords: keywords(for: parent)))
                } else {
                    scan(entry, depth: depth + 1)
                }
            }
        }
        scan(root, depth: 0)
        return results.sorted { $0.path < $1.path }
    }

    static func relativePath(_ url: URL, to root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        var p = url.standardizedFileURL.path
        if p.hasPrefix(rootPath) { p.removeFirst(rootPath.count) }
        p = p.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return p.isEmpty ? "transcripts/" : p + "/"
    }

    /// "Contoso Rollout" → ["contoso rollout", "contoso", "rollout"]. Skips the
    /// generic parent for a top-level transcripts/ (parent == root name).
    static func keywords(for folderName: String) -> [String] {
        let lower = folderName.lowercased()
        guard lower != "transcripts", !lower.isEmpty else { return [] }
        var set: [String] = [lower]
        for token in lower.split(whereSeparator: { !$0.isLetter && !$0.isNumber }) where token.count > 2 {
            let t = String(token)
            if !set.contains(t) { set.append(t) }
        }
        return set
    }
}
