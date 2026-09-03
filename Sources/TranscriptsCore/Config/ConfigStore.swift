import Foundation

/// Loads/saves `AppConfig` as pretty-printed JSON at
/// `~/Library/Application Support/Transcripts/config.json` (by default). The file is
/// intentionally human-readable so it can be hand-edited.
public struct ConfigStore {
    public let url: URL

    /// True when `TRANSCRIPTS_CONFIG` chose this path. See `load()`: a config
    /// that was asked for explicitly must never silently fall back.
    public private(set) var isOverridden = false

    public init(url: URL? = nil) {
        if let url {
            self.url = url
        } else if let override = ProcessInfo.processInfo.environment["TRANSCRIPTS_CONFIG"],
                  !override.isEmpty {
            // Lets a second copy run against its own library without disturbing
            // the one already running: the screenshot harness points a demo
            // instance at a generated library while the real app keeps watching
            // for meetings, holding its own config, untouched.
            self.url = URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
            self.isOverridden = true
        } else {
            let support = FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)
                .first ?? URL(fileURLWithPath: NSTemporaryDirectory())
            self.url = support
                .appendingPathComponent("Transcripts", isDirectory: true)
                .appendingPathComponent("config.json")
        }
    }

    private static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return e
    }

    /// Loads the config, falling back to `.default` (and writing it) if absent.
    public func load() throws -> AppConfig {
        guard FileManager.default.fileExists(atPath: url.path) else {
            let fresh = AppConfig.default
            try? save(fresh)
            return fresh
        }
        let data = try Data(contentsOf: url)
        do {
            return try JSONDecoder().decode(AppConfig.self, from: data)
        } catch {
            // Every caller reads this as `(try? load()) ?? .default`, and
            // `.default` points at iCloud Drive — a real library with real
            // recordings in it. That is a sane fallback for a config that got
            // corrupted on someone's Mac, and completely wrong for one named on
            // purpose: the screenshot harness asking for a demo library and
            // quietly getting the real one is how private material ends up in a
            // public repository. An override that cannot be read is fatal.
            guard isOverridden else { throw error }
            fatalError("TRANSCRIPTS_CONFIG names \(url.path), which could not "
                       + "be read as an AppConfig (\(error)). Refusing to fall "
                       + "back to the default library.")
        }
    }

    public func save(_ config: AppConfig) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try Self.encoder.encode(config)
        try data.write(to: url, options: .atomic)
    }
}
