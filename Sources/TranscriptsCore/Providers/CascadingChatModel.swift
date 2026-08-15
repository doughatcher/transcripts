import Foundation

/// Tries a list of `ChatModel`s in order and returns the first non-empty result,
/// falling through on error. With `[FoundationModels?, Ollama, Extractive]` this
/// gives "best available, always works": on-device Apple intelligence when present,
/// a local Ollama if one happens to be running, and finally the built-in extractive
/// summarizer that never fails — so the app is self-contained but uses better models
/// opportunistically. Ollama being unreachable fails fast (connection refused).
public struct CascadingChatModel: ChatModel {
    public let models: [any ChatModel]

    public init(_ models: [any ChatModel]) {
        self.models = models
    }

    public func chat(system: String, user: String, jsonFormat: Bool, maxTokens: Int) async throws -> String {
        var lastError: Error?
        for model in models {
            do {
                let result = try await model.chat(system: system, user: user, jsonFormat: jsonFormat, maxTokens: maxTokens)
                if !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return result
                }
            } catch {
                lastError = error
            }
        }
        if let lastError { throw lastError }
        // Should be unreachable when Extractive is last, but keep a safe default.
        return jsonFormat ? #"{"destination":"","confidence":0}"# : ""
    }
}
