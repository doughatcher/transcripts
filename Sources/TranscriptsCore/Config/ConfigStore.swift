import Foundation

/// Loads/saves `AppConfig` as pretty-printed JSON at
/// `~/Library/Application Support/Transcripts/config.json` (by default). The file is
/// intentionally human-readable so it can be hand-edited.
public struct ConfigStore {
    public let url: URL

    public init(url: URL? = nil) {
        if let url {
            self.url = url
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
        return try JSONDecoder().decode(AppConfig.self, from: data)
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
