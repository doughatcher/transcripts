import Foundation

/// How finished recordings are filed. Deliberately unopinionated about your folder
/// layout: `automatic` discovers any `*/transcripts/` folder in the vault, `script`
/// hands off to your own sorter, and `off` always files to one folder.
///
/// Persisted as `<knowledgeRoot>/.transcripts/routing.json` so it's editable by hand and
/// versioned with the vault; the common knobs are also exposed in Settings.
public struct RoutingConfig: Codable, Equatable, Sendable {
    public enum Mode: String, Codable, Sendable {
        case automatic   // rails (keyword match) → on-device model → fallback
        case script      // run a user command that returns a destination
        case off         // always file to `fallback`
    }

    /// A candidate destination and the words that should route to it.
    public struct Destination: Codable, Equatable, Sendable {
        public var path: String           // vault-relative, e.g. "Cases/Contoso Rollout/transcripts/"
        public var keywords: [String]     // aliases for rails + hints for the model
        public init(path: String, keywords: [String] = []) {
            self.path = path
            self.keywords = keywords
        }
    }

    public var mode: Mode
    /// Where anything unmatched goes.
    public var fallback: String
    /// Minimum model confidence (0…1) to accept a case match; below it → fallback.
    public var confidenceThreshold: Double
    /// Extra/curated destinations with keywords. Merged with auto-discovered ones.
    public var destinations: [Destination]
    /// The sorter command for `.script` mode. Receives the file paths + context and
    /// prints a vault-relative destination (or JSON `{"destination": "..."}`), or
    /// prints nothing / "handled" if it filed the recording itself.
    public var script: ExternalCommand?
    /// Named multi-recording occasions — see `SessionProfile`. Lives here rather
    /// than in its own file because this is already the hand-edited place where
    /// "what happens to a finished recording" is described.
    public var sessions: [SessionProfile]

    public init(
        mode: Mode = .automatic,
        fallback: String = "transcripts/",
        confidenceThreshold: Double = 0.55,
        destinations: [Destination] = [],
        script: ExternalCommand? = nil,
        sessions: [SessionProfile] = []
    ) {
        self.mode = mode
        self.fallback = fallback
        self.confidenceThreshold = confidenceThreshold
        self.destinations = destinations
        self.script = script
        self.sessions = sessions
    }

    public static var `default`: RoutingConfig { .init() }

    // Tolerate older/newer files: missing keys use defaults.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mode = (try? c.decode(Mode.self, forKey: .mode)) ?? .automatic
        fallback = (try? c.decode(String.self, forKey: .fallback)) ?? "transcripts/"
        confidenceThreshold = (try? c.decode(Double.self, forKey: .confidenceThreshold)) ?? 0.55
        destinations = (try? c.decode([Destination].self, forKey: .destinations)) ?? []
        script = try? c.decode(ExternalCommand.self, forKey: .script)
        sessions = (try? c.decode([SessionProfile].self, forKey: .sessions)) ?? []
    }
}
