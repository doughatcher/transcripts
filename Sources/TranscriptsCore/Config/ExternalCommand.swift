import Foundation

/// A shell command / external script invocation. Arguments and environment values
/// support `${...}` template substitution against the current `PipelineContext`
/// (see `TemplateEngine`).
public struct ExternalCommand: Codable, Equatable, Sendable {
    public var executable: String
    public var arguments: [String]
    public var workingDirectory: String?
    public var environment: [String: String]
    public var timeoutSeconds: Int

    public init(
        executable: String,
        arguments: [String] = [],
        workingDirectory: String? = nil,
        environment: [String: String] = [:],
        timeoutSeconds: Int = 600
    ) {
        self.executable = executable
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.environment = environment
        self.timeoutSeconds = timeoutSeconds
    }

    enum CodingKeys: String, CodingKey {
        case executable, arguments, workingDirectory, environment, timeoutSeconds
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        executable = try c.decode(String.self, forKey: .executable)
        arguments = try c.decodeIfPresent([String].self, forKey: .arguments) ?? []
        workingDirectory = try c.decodeIfPresent(String.self, forKey: .workingDirectory)
        environment = try c.decodeIfPresent([String: String].self, forKey: .environment) ?? [:]
        timeoutSeconds = try c.decodeIfPresent(Int.self, forKey: .timeoutSeconds) ?? 600
    }
}

/// How a single stage is fulfilled. Encodes to clean JSON:
/// `"native"`, `"disabled"`, or `{"externalCommand": { ... }}`.
public enum StageProvider: Codable, Equatable, Sendable {
    case native
    case externalCommand(ExternalCommand)
    case disabled

    enum CodingKeys: String, CodingKey {
        case externalCommand
    }

    public init(from decoder: Decoder) throws {
        // Try a bare string first: "native" / "disabled".
        let single = try decoder.singleValueContainer()
        if let raw = try? single.decode(String.self) {
            switch raw {
            case "native": self = .native; return
            case "disabled": self = .disabled; return
            default:
                throw DecodingError.dataCorruptedError(
                    in: single,
                    debugDescription: "Unknown stage provider '\(raw)'"
                )
            }
        }
        // Otherwise expect `{"externalCommand": {...}}`.
        let keyed = try decoder.container(keyedBy: CodingKeys.self)
        self = .externalCommand(try keyed.decode(ExternalCommand.self, forKey: .externalCommand))
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .native:
            var c = encoder.singleValueContainer()
            try c.encode("native")
        case .disabled:
            var c = encoder.singleValueContainer()
            try c.encode("disabled")
        case .externalCommand(let cmd):
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(cmd, forKey: .externalCommand)
        }
    }
}
