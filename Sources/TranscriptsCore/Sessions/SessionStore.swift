import Foundation

/// Reads and writes the running session's marker.
///
/// One file, rewritten whole. A session accumulates a handful of recording ids
/// over an evening — there is nothing here worth the complexity of appending,
/// and a whole-file write cannot leave a half-updated record behind.
public struct SessionStore: Sendable {
    public let url: URL

    /// Beside the app's other durable state rather than in the vault: a session
    /// marker is machine state, not something the user wants synced between
    /// devices or committed alongside their notes.
    public init(directory: URL) {
        self.url = directory.appendingPathComponent("session.json")
    }

    public func load() -> ActiveSession? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return try? d.decode(ActiveSession.self, from: data)
    }

    public func save(_ session: ActiveSession) throws {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try e.encode(session).write(to: url, options: .atomic)
    }

    public func clear() {
        try? FileManager.default.removeItem(at: url)
    }
}
