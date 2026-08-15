import Foundation

/// Builds the `${...}` variable table from a context and substitutes it into
/// command arguments / environment values. These variable names are the public
/// contract for external scripts (documented in DESIGN.md §4).
public enum TemplateEngine {
    public static func variables(for ctx: PipelineContext) -> [String: String] {
        var v: [String: String] = [:]
        v["audioURL"] = ctx.recording.audioURL.path
        v["archivedAudioURL"] = ctx.archivedAudioURL?.path ?? ctx.recording.audioURL.path
        v["transcriptURL"] = ctx.transcriptURL?.path ?? ""
        v["summaryURL"] = ctx.summaryURL?.path ?? ""
        v["activeApp"] = ctx.recording.activeApp?.appName ?? ""
        v["activeAppBundleID"] = ctx.recording.activeApp?.bundleID ?? ""
        v["startedAt"] = ISO8601DateFormatter().string(from: ctx.recording.startedAt)
        if let dur = ctx.recording.durationSeconds {
            v["durationSeconds"] = String(Int(dur.rounded()))
        } else {
            v["durationSeconds"] = ""
        }
        v["scratchDir"] = ctx.scratchDir.path
        if let routing = ctx.routing,
           let data = try? JSONEncoder().encode(routing),
           let json = String(data: data, encoding: .utf8) {
            v["routingJSON"] = json
        } else {
            v["routingJSON"] = ""
        }
        return v
    }

    /// Replaces every `${name}` occurrence with its value (unknown names left as-is).
    public static func substitute(_ template: String, with vars: [String: String]) -> String {
        var result = template
        for (key, value) in vars {
            result = result.replacingOccurrences(of: "${\(key)}", with: value)
        }
        return result
    }

    /// Returns a copy of `command` with all arguments and environment values
    /// template-substituted.
    public static func resolve(_ command: ExternalCommand, with vars: [String: String]) -> ExternalCommand {
        var resolved = command
        resolved.executable = substitute(command.executable, with: vars)
        resolved.arguments = command.arguments.map { substitute($0, with: vars) }
        resolved.environment = command.environment.mapValues { substitute($0, with: vars) }
        if let wd = command.workingDirectory {
            resolved.workingDirectory = substitute(wd, with: vars)
        }
        return resolved
    }
}
