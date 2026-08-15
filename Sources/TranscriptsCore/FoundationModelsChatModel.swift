import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// On-device text generation via Apple's `FoundationModels` framework
/// (Apple Intelligence, iOS/macOS 26). This is the preferred `ChatModel`:
/// fully local on the Neural Engine, no external process, no network.
///
/// A fresh `LanguageModelSession` is created per call — the Summarize/Classify
/// turns are one-shot and independent, so we don't carry conversation state.
public enum FoundationModelsChatModel {

    /// Whether the on-device model is usable right now (device eligible, Apple
    /// Intelligence enabled, assets downloaded).
    public static var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26, iOS 26, *) {
            if case .available = SystemLanguageModel.default.availability { return true }
        }
        #endif
        return false
    }

    /// A short human-readable reason when unavailable (for logging / settings UI).
    public static var unavailableReason: String? {
        #if canImport(FoundationModels)
        if #available(macOS 26, iOS 26, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return nil
            case .unavailable(let reason):
                switch reason {
                case .deviceNotEligible: return "This Mac isn't eligible for Apple Intelligence."
                case .appleIntelligenceNotEnabled: return "Apple Intelligence is turned off in System Settings."
                case .modelNotReady: return "The on-device model is still downloading."
                @unknown default: return "The on-device model is unavailable."
                }
            }
        }
        #endif
        return "FoundationModels requires macOS 26 or later."
    }
}

#if canImport(FoundationModels)
@available(macOS 26, iOS 26, *)
public struct AppleFoundationModel: ChatModel {
    public init() {}

    public func chat(system: String, user: String, jsonFormat: Bool, maxTokens: Int) async throws -> String {
        // Guardrails default; instructions carry the system prompt.
        let session = LanguageModelSession(instructions: system)

        // FoundationModels has no explicit JSON mode here; nudge via the prompt.
        let prompt = jsonFormat
            ? "\(user)\n\nRespond with a single valid JSON object and nothing else."
            : user

        let options = GenerationOptions(temperature: 0.1, maximumResponseTokens: maxTokens)
        let response = try await session.respond(to: prompt, options: options)
        var text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)

        // Models sometimes fence JSON in ```json … ``` — unwrap for the parser.
        if jsonFormat { text = Self.unwrapCodeFence(text) }
        return text
    }

    private static func unwrapCodeFence(_ s: String) -> String {
        guard s.hasPrefix("```") else { return s }
        var lines = s.components(separatedBy: "\n")
        if lines.first?.hasPrefix("```") == true { lines.removeFirst() }
        if lines.last?.trimmingCharacters(in: .whitespaces) == "```" { lines.removeLast() }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
#endif
