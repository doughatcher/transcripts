import Foundation

/// The JSON contract an external command may print on stdout to declare which
/// artifacts it produced. Every field is optional — a script that produces
/// nothing parseable simply leaves the context unchanged (the engine then falls
/// back to conventional output paths). Example a script might print:
///
/// ```json
/// {"transcriptURL": "/path/out.md", "userInfo": {"engine": "deepgram"}}
/// ```
public struct ExternalStageResult: Codable, Sendable {
    public var archivedAudioURL: URL?
    public var transcriptURL: URL?
    public var summaryURL: URL?
    public var routing: RoutingDecision?
    public var finalPaths: [URL]?
    public var userInfo: [String: String]?

    /// Best-effort parse: tolerates extra text around the JSON by scanning for the
    /// outermost `{ ... }`. Returns nil if no JSON object is present.
    public static func parse(_ stdout: String) -> ExternalStageResult? {
        guard let start = stdout.firstIndex(of: "{"),
              let end = stdout.lastIndex(of: "}"),
              start < end else { return nil }
        let slice = String(stdout[start...end])
        guard let data = slice.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(ExternalStageResult.self, from: data)
    }

    /// Merges this result's non-nil fields into a context.
    public func merge(into ctx: inout PipelineContext) {
        if let v = archivedAudioURL { ctx.archivedAudioURL = v }
        if let v = transcriptURL { ctx.transcriptURL = v }
        if let v = summaryURL { ctx.summaryURL = v }
        if let v = routing { ctx.routing = v }
        if let v = finalPaths { ctx.finalPaths = v }
        if let v = userInfo { ctx.userInfo.merge(v) { _, new in new } }
    }
}
