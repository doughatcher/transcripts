import Foundation

/// Minimal client for a local Ollama server's `/api/chat` endpoint. Mirrors the
/// request shape used by the existing `plaud-sorter` (`classify-sort.py`):
/// `stream:false`, `think:false`, optional `format:"json"`, low temperature.
public struct OllamaClient: Sendable {
    public let baseURL: URL
    public let model: String
    private let session: URLSession

    public init(config: OllamaConfig, session: URLSession = .shared) {
        self.baseURL = URL(string: config.url) ?? URL(string: "http://localhost:11434")!
        self.model = config.model
        self.session = session
    }

    public enum OllamaError: Error, CustomStringConvertible {
        case badResponse(Int)
        case malformed

        public var description: String {
            switch self {
            case .badResponse(let c): return "Ollama returned HTTP \(c)"
            case .malformed: return "Ollama response was not in the expected shape"
            }
        }
    }

    /// Sends a system+user chat turn and returns the assistant's message content.
    /// When `jsonFormat` is true, asks Ollama to constrain output to JSON.
    public func chat(system: String, user: String, jsonFormat: Bool, numPredict: Int = 512) async throws -> String {
        var payload: [String: Any] = [
            "model": model,
            "stream": false,
            "think": false,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
            "options": ["temperature": 0.1, "num_predict": numPredict],
        ]
        if jsonFormat { payload["format"] = "json" }

        var request = URLRequest(url: baseURL.appendingPathComponent("api/chat"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        request.timeoutInterval = 300

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw OllamaError.badResponse(http.statusCode)
        }
        guard
            let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let message = obj["message"] as? [String: Any],
            let content = message["content"] as? String
        else {
            throw OllamaError.malformed
        }
        return content
    }
}

extension OllamaClient: ChatModel {
    /// `ChatModel` conformance — maps `maxTokens` onto Ollama's `num_predict`.
    public func chat(system: String, user: String, jsonFormat: Bool, maxTokens: Int) async throws -> String {
        try await chat(system: system, user: user, jsonFormat: jsonFormat, numPredict: maxTokens)
    }
}
