import Foundation
import TranscriptsCore
#if arch(arm64)
import MLXLLM
import MLXLMCommon
#endif

#if arch(arm64)
/// In-process LLM via Apple's MLX — "Ollama as a library". This is the built-in
/// tier between Apple Intelligence and the extractive floor: a fit-for-purpose
/// quantized ~3B model running inside Transcripts, no daemon, nothing to install.
///
/// The model downloads once from Hugging Face (~1.5 GB) and caches locally; on
/// networks that block HF the load fails fast, the failure is remembered for
/// the session (no per-call retry storms), and the chain degrades as before.
/// Apple Silicon only — the type doesn't exist on Intel builds.
public struct MLXChatModel: ChatModel {
    public static let defaultModelID = "mlx-community/Llama-3.2-3B-Instruct-4bit"

    private let modelID: String

    public init(modelID: String = MLXChatModel.defaultModelID) {
        self.modelID = modelID
    }

    /// True when MLX's compiled Metal shaders shipped with this build.
    ///
    /// MLX does not *throw* when the metallib is missing — it calls its fatal
    /// error handler and takes the whole process down (exit 255, no crash
    /// report), so `CascadingChatModel` never gets to fall through to the next
    /// tier: the app simply vanishes mid-summarize. The shaders go missing when
    /// the build host lacks Xcode's Metal Toolchain component, which SwiftPM
    /// skips silently rather than failing the build (2026-08-03).
    ///
    /// Mirrors mlx-swift's own lookup (`Cmlx/mlx/backend/metal/device.cpp`):
    /// `default.metallib` colocated with the executable, else inside an
    /// `mlx-swift_Cmlx.bundle` reachable from the main bundle or any loaded one.
    public static let isAvailable: Bool = metallibURL() != nil

    public static func metallibURL() -> URL? {
        let fm = FileManager.default
        let colocated = Bundle.main.executableURL?
            .deletingLastPathComponent()
            .appendingPathComponent("default.metallib")
        if let colocated, fm.fileExists(atPath: colocated.path) { return colocated }

        var roots = [Bundle.main.bundleURL]
        roots.append(contentsOf: Bundle.allBundles.compactMap(\.resourceURL))
        for root in roots {
            let bundle = root.appendingPathComponent("mlx-swift_Cmlx.bundle")
            guard let resources = Bundle(url: bundle)?.resourceURL else { continue }
            let lib = resources.appendingPathComponent("default.metallib")
            if fm.fileExists(atPath: lib.path) { return lib }
        }
        return nil
    }

    public func chat(system: String, user: String, jsonFormat: Bool, maxTokens: Int) async throws -> String {
        guard Self.isAvailable else { throw MLXUnavailable.noMetalLibrary }
        let container = try await MLXModelCache.shared.container(id: modelID)
        let prompt = jsonFormat
            ? "\(user)\n\nRespond with a single valid JSON object and nothing else."
            : user
        let session = ChatSession(
            container,
            instructions: system,
            generateParameters: GenerateParameters(maxTokens: maxTokens, temperature: 0.1))
        var text = try await session.respond(to: prompt)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if jsonFormat { text = Self.unwrapCodeFence(text) }
        return text
    }

    public static func unwrapCodeFence(_ s: String) -> String {
        guard s.hasPrefix("```") else { return s }
        var lines = s.components(separatedBy: "\n")
        if lines.first?.hasPrefix("```") == true { lines.removeFirst() }
        if lines.last?.trimmingCharacters(in: .whitespaces) == "```" { lines.removeLast() }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public enum MLXUnavailable: Error, CustomStringConvertible {
    case noMetalLibrary

    public var description: String {
        switch self {
        case .noMetalLibrary:
            return "MLX Metal shaders missing from this build "
                + "(build host needs: xcodebuild -downloadComponent MetalToolchain)"
        }
    }
}

/// Loads the MLX model once per app session and hands out the shared container.
/// A failed load (e.g. Hugging Face unreachable) is remembered so later calls
/// fail fast instead of re-attempting a doomed download mid-pipeline.
public actor MLXModelCache {
    public static let shared = MLXModelCache()

    private var loadTask: Task<ModelContext, Error>?

    public func container(id: String) async throws -> ModelContext {
        if let loadTask {
            return try await loadTask.value
        }
        let task = Task<ModelContext, Error> {
            Log.write("mlx: loading '\(id)' (first use downloads ~1.5 GB from Hugging Face)")
            let context = try await loadModel(id: id)
            Log.write("mlx: model ready")
            return context
        }
        loadTask = task
        do {
            return try await task.value
        } catch {
            Log.write("mlx: load failed (\(error)) — built-in model unavailable this session")
            throw error
        }
    }
}
#endif
