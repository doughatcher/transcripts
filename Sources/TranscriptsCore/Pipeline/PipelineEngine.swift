import Foundation

/// Runs a recording through the configured pipeline.
///
/// - In `.handoff` mode it skips all stages and hands the raw recording to a
///   single external command (the simplest integration — exactly how the current
///   Plaud follow-up script consumes a file).
/// - In `.bakedIn` mode it walks the ordered stage list, running each stage's
///   provider: a registered native implementation, an external command, or skip.
public final class PipelineEngine {
    private let config: AppConfig
    private let runner: CommandRunner
    private let nativeStages: [StageID: PipelineStage]
    private let log: @Sendable (String) -> Void
    private let fileManager = FileManager.default

    public init(
        config: AppConfig,
        runner: CommandRunner,
        nativeStages: [PipelineStage],
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.config = config
        self.runner = runner
        self.nativeStages = Dictionary(uniqueKeysWithValues: nativeStages.map { ($0.id, $0) })
        self.log = log
    }

    /// How long any one stage may run before the pipeline gives up on it.
    ///
    /// A stage with no ceiling doesn't fail, it *hangs* — and a hung pipeline is
    /// invisible: the recording sits in `.processing` forever, no note appears, and
    /// nothing says why. That happened on 2026-07-22, where two calls whose mic had
    /// been silenced entered `transcribe` and never emitted another line; they only
    /// produced notes 19 hours later when a relaunch triggered crash recovery.
    /// Timing out marks the record failed instead, which is retryable and visible.
    ///
    /// Scaled by audio length so a two-hour recording isn't cut off mid-transcribe,
    /// with a floor generous enough for model loading on a cold start.
    static func timeout(for stage: StageID, duration: TimeInterval?) -> TimeInterval {
        switch stage {
        case .encode, .transcribe:
            return max(900, (duration ?? 0) * 3)
        case .summarize, .classify, .persist:
            return 600
        }
    }

    /// Process a recording end to end, returning the final enriched context.
    /// `forcedDestination` bypasses classification — used when the recording
    /// belongs to a session that names its own folder.
    public func process(_ recording: Recording, scratchRoot: URL? = nil,
                        forcedDestination: String? = nil) async throws -> PipelineContext {
        let scratch = try makeScratchDir(root: scratchRoot, recording: recording)
        var ctx = PipelineContext(recording: recording, scratchDir: scratch)
        ctx.forcedDestination = forcedDestination

        switch config.pipeline.mode {
        case .handoff:
            guard let cmd = config.pipeline.handoffCommand else {
                throw PipelineError.missingHandoffCommand
            }
            log("handoff: \(cmd.executable)")
            try await runExternal(cmd, stage: nil, into: &ctx)

        case .bakedIn:
            for stageConfig in config.pipeline.stages {
                // A text-only note skips audio stages.
                if recording.isNote, stageConfig.id == .encode || stageConfig.id == .transcribe {
                    continue
                }
                try await runStage(stageConfig, into: &ctx)
            }
        }
        return ctx
    }

    private func runStage(_ stageConfig: StageConfig, into ctx: inout PipelineContext) async throws {
        switch stageConfig.provider {
        case .disabled:
            log("stage \(stageConfig.id.rawValue): disabled, skipping")

        case .native:
            guard let stage = nativeStages[stageConfig.id] else {
                throw PipelineError.missingNativeStage(stageConfig.id)
            }
            log("stage \(stageConfig.id.rawValue): native")
            let limit = Self.timeout(for: stageConfig.id, duration: ctx.recording.durationSeconds)
            let snapshot = ctx
            do {
                ctx = try await Self.withTimeout(limit, stage: stageConfig.id) {
                    var local = snapshot
                    try await stage.run(&local)
                    return local
                }
            } catch let error as PipelineError {
                throw error
            } catch {
                throw PipelineError.stageFailed(stageConfig.id, underlying: error)
            }

        case .externalCommand(let cmd):
            log("stage \(stageConfig.id.rawValue): external \(cmd.executable)")
            try await runExternal(cmd, stage: stageConfig.id, into: &ctx)
        }
    }

    /// Runs an external command: substitutes template vars, writes the full
    /// context JSON to a temp file (exposed as `TRANSCRIPTS_CONTEXT_JSON`) and
    /// to stdin, then merges any `ExternalStageResult` it prints back into
    /// context.
    ///
    /// The prefix is part of the public contract — every stage script reads
    /// these — so it names this app rather than the one this code grew out of.
    private func runExternal(_ command: ExternalCommand, stage: StageID?, into ctx: inout PipelineContext) async throws {
        let vars = TemplateEngine.variables(for: ctx)
        var resolved = TemplateEngine.resolve(command, with: vars)

        let contextData = try JSONEncoder().encode(ctx)
        let contextFile = ctx.scratchDir.appendingPathComponent("context.json")
        try? contextData.write(to: contextFile)
        resolved.environment["TRANSCRIPTS_CONTEXT_JSON"] = contextFile.path
        for (k, v) in vars where resolved.environment["TRANSCRIPTS_\(k.uppercased())"] == nil {
            resolved.environment["TRANSCRIPTS_\(k.uppercased())"] = v
        }

        let result = try await runner.run(resolved, stdin: contextData)
        if !result.stderrString.isEmpty {
            log("  stderr: \(result.stderrString.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        guard result.exitCode == 0 else {
            throw PipelineError.externalCommandFailed(
                stage: stage,
                exitCode: result.exitCode,
                stderr: result.stderrString
            )
        }
        if let parsed = ExternalStageResult.parse(result.stdoutString) {
            parsed.merge(into: &ctx)
            log("  merged external result")
        }
    }

    /// Runs `op`, or throws `stageTimedOut` if it outlives `seconds`.
    ///
    /// Cancellation is cooperative, so a stage stuck inside a blocking framework
    /// call may keep running in the background — but the pipeline is freed either
    /// way, which is the point: the recording gets marked failed and stays
    /// retryable instead of sitting in `.processing` forever.
    static func withTimeout<T: Sendable>(_ seconds: TimeInterval, stage: StageID,
                                         _ op: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await op() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw PipelineError.stageTimedOut(stage, seconds: seconds)
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else {
                throw PipelineError.stageTimedOut(stage, seconds: seconds)
            }
            return first
        }
    }

    private func makeScratchDir(root: URL?, recording: Recording) throws -> URL {
        let base = root ?? fileManager.temporaryDirectory.appendingPathComponent("Transcripts", isDirectory: true)
        let stamp = Self.slugFormatter.string(from: recording.startedAt)
        let dir = base.appendingPathComponent("\(stamp)-\(recording.id.uuidString.prefix(8))", isDirectory: true)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static let slugFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
}
