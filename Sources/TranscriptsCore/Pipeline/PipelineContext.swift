import Foundation

/// The typed payload that flows through every pipeline stage. Each stage reads
/// what it needs and enriches the context for downstream stages. It is `Codable`
/// so the engine can hand the whole thing to an external command (via stdin /
/// `SCRIBE_CONTEXT_JSON`) and merge back a result.
public struct PipelineContext: Codable, Sendable {
    public var recording: Recording

    /// Set by the Encode stage — archive-quality audio.
    public var archivedAudioURL: URL?
    /// Set by the Transcribe stage.
    public var transcriptURL: URL?
    /// Set by the Summarize stage (may be merged into the transcript instead).
    public var summaryURL: URL?
    /// Set by the Classify stage.
    public var routing: RoutingDecision?
    /// Set by the Persist stage — the files' final resting paths.
    public var finalPaths: [URL]
    /// Per-run scratch workspace; safe for stages to write intermediates into.
    public var scratchDir: URL
    /// Free-form key/value bag that survives across stages and round-trips
    /// through external commands.
    public var userInfo: [String: String]

    public init(
        recording: Recording,
        scratchDir: URL,
        archivedAudioURL: URL? = nil,
        transcriptURL: URL? = nil,
        summaryURL: URL? = nil,
        routing: RoutingDecision? = nil,
        finalPaths: [URL] = [],
        userInfo: [String: String] = [:]
    ) {
        self.recording = recording
        self.scratchDir = scratchDir
        self.archivedAudioURL = archivedAudioURL
        self.transcriptURL = transcriptURL
        self.summaryURL = summaryURL
        self.routing = routing
        self.finalPaths = finalPaths
        self.userInfo = userInfo
    }
}
