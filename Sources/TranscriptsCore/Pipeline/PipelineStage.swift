import Foundation

/// Identifies the well-known stages in the default baked-in pipeline. The order
/// of cases here is the default execution order.
public enum StageID: String, Codable, CaseIterable, Sendable {
    case encode
    case transcribe
    case summarize
    case classify
    case persist
}

/// A unit of work in the pipeline. Native stages conform directly; external
/// commands are run by the engine and don't need a conformer.
///
/// `run` takes the context `inout` so a stage enriches it in place.
public protocol PipelineStage: Sendable {
    var id: StageID { get }
    func run(_ context: inout PipelineContext) async throws
}

public enum PipelineError: Error, CustomStringConvertible {
    case missingNativeStage(StageID)
    case missingHandoffCommand
    case stageFailed(StageID, underlying: Error)
    case externalCommandFailed(stage: StageID?, exitCode: Int32, stderr: String)
    case stageTimedOut(StageID, seconds: TimeInterval)

    public var description: String {
        switch self {
        case .missingNativeStage(let id):
            return "No native implementation registered for stage '\(id.rawValue)'"
        case .missingHandoffCommand:
            return "Pipeline is in handoff mode but no handoff command is configured"
        case .stageFailed(let id, let underlying):
            return "Stage '\(id.rawValue)' failed: \(underlying)"
        case .externalCommandFailed(let stage, let code, let stderr):
            let where_ = stage.map { "stage '\($0.rawValue)'" } ?? "handoff command"
            return "External command for \(where_) exited \(code): \(stderr)"
        case .stageTimedOut(let id, let seconds):
            return "Stage '\(id.rawValue)' did not finish within \(Int(seconds))s — the recording is kept and can be retried"
        }
    }
}
