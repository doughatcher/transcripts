import Foundation

/// A minimal text-generation interface shared by every LLM backend. The Summarize
/// and Classify stages depend only on this, so the actual engine — Apple's
/// on-device `FoundationModels`, a local Ollama server, or a future cloud model —
/// is a swappable, injected detail.
///
/// The default/preferred implementation is `FoundationModelsChatModel` (in the app
/// target): fully on-device, no daemon, no external process. `OllamaClient` remains
/// as a fallback for machines where Apple Intelligence isn't available.
public protocol ChatModel: Sendable {
    /// One system+user turn. `jsonFormat` asks the backend to emit strict JSON;
    /// `maxTokens` caps the response length. Returns the assistant text.
    func chat(system: String, user: String, jsonFormat: Bool, maxTokens: Int) async throws -> String
}

public extension ChatModel {
    /// Convenience with a sensible default cap.
    func chat(system: String, user: String, jsonFormat: Bool) async throws -> String {
        try await chat(system: system, user: user, jsonFormat: jsonFormat, maxTokens: 1024)
    }
}
