import Foundation

public struct StageConfig: Codable, Equatable, Sendable {
    public var id: StageID
    public var provider: StageProvider

    public init(id: StageID, provider: StageProvider) {
        self.id = id
        self.provider = provider
    }
}

public enum PipelineMode: String, Codable, Sendable {
    /// Run the ordered list of native/external stages.
    case bakedIn
    /// Skip all stages and hand the raw recording to one external command.
    case handoff
}

public struct PipelineConfig: Codable, Equatable, Sendable {
    public var mode: PipelineMode
    public var handoffCommand: ExternalCommand?
    public var stages: [StageConfig]

    public init(mode: PipelineMode, handoffCommand: ExternalCommand? = nil, stages: [StageConfig]) {
        self.mode = mode
        self.handoffCommand = handoffCommand
        self.stages = stages
    }
}

/// Menu-bar icon style.
public enum MenuBarIconStyle: String, Codable, Sendable, CaseIterable {
    case waveform
    case microphone
}

/// How Transcripts handles consent when a call is detected.
public enum ConsentMode: String, Codable, Sendable {
    /// Auto-record as soon as a call is detected (one-party-consent jurisdictions).
    case oneParty
    /// Don't auto-record — announce first: Transcripts notifies you to tell participants,
    /// and only starts when you confirm (all-party / two-party consent).
    case twoParty
}

/// Which text-generation backend the Summarize/Classify stages use.
public enum LLMProvider: String, Codable, Sendable {
    /// Apple's on-device model via the `FoundationModels` framework (preferred:
    /// no daemon, no external process). Falls back to Ollama if unavailable.
    case appleOnDevice
    /// A local Ollama server (`OllamaConfig`).
    case ollama
}

public struct OllamaConfig: Codable, Equatable, Sendable {
    public var url: String
    public var model: String

    public init(url: String = "http://localhost:11434", model: String = "gemma4:12b") {
        self.url = url
        self.model = model
    }
}

public struct WhisperConfig: Codable, Equatable, Sendable {
    public var model: String
    public init(model: String = "base.en") { self.model = model }
}

public struct DestinationsConfig: Codable, Equatable, Sendable {
    /// Root of the vault the Persist/Classify stages route into.
    public var knowledgeRoot: String

    /// Folder the iPhone/iPad recorder drops captures into, watched for new
    /// audio to run through the pipeline. Empty/nil = device ingest is off.
    ///
    /// A path rather than a provider integration on purpose: iCloud Drive and
    /// OneDrive both surface as ordinary directories on macOS
    /// (`~/Library/Mobile Documents/…`, `~/Library/CloudStorage/…`), so the Mac
    /// needs no API, no auth, and no per-provider code — it just watches a
    /// folder the user points it at.
    public var deviceInbox: String?

    // Neutral per-user default so a fresh install files into the user's own folder
    // (an existing pinned root in a saved config is untouched).
    public init(knowledgeRoot: String = "~/Documents/Transcripts", deviceInbox: String? = nil) {
        self.knowledgeRoot = knowledgeRoot
        self.deviceInbox = deviceInbox
    }

    /// Expanded device-inbox root, or nil when ingest is switched off.
    public var resolvedDeviceInbox: URL? {
        guard let p = deviceInbox?.trimmingCharacters(in: .whitespaces), !p.isEmpty else { return nil }
        return URL(fileURLWithPath: (p as NSString).expandingTildeInPath)
    }

    /// Expands a leading `~` to the user's home directory.
    public var resolvedRoot: URL {
        URL(fileURLWithPath: (knowledgeRoot as NSString).expandingTildeInPath)
    }
}

/// Top-level app configuration. Persisted as readable JSON via `ConfigStore` so it
/// can be hand-edited.
public struct AppConfig: Codable, Equatable, Sendable {
    public var autoRecordOnMicActivation: Bool
    public var captureSystemAudio: Bool
    /// One-party (auto-record) vs two-party (announce & confirm first). Default one-party.
    public var consentMode: ConsentMode
    /// Menu-bar icon style.
    public var menuBarIcon: MenuBarIconStyle
    /// Color of the recording indicator (the pulsing menu-bar icon and the
    /// popover's "Recording" marks), as `#RRGGBB`. Defaults to Blue Acorn blue;
    /// the classic red is a one-click preset in Settings.
    public var recordingColorHex: String
    public var archiveCodec: String
    /// CoreAudio UID of the preferred microphone input. `nil` = auto-pick (prefer a
    /// good external mic like the Logitech Brio over the built-in one, which is dead
    /// in a clamshell/docked setup). Persisted by UID so it survives reconnects.
    /// Favorite mics in priority order (by CoreAudio UID). Transcripts records from the
    /// highest-priority favorite that's currently connected, else the smart default.
    /// Works across machines: keep each desk's mic as a favorite; only one is present.
    public var favoriteInputUIDs: [String]
    /// Cached labels for favorite mics so Settings can still show and reorder them
    /// while they're unplugged.
    public var favoriteInputNamesByUID: [String: String]
    /// Explicit "use this mic" override (by UID). When set and connected it beats
    /// favorites; `nil` = follow favorites. Cleared with "Use favorites".
    public var overrideInputUID: String?
    /// Deprecated — migrated into `favoriteInputUIDs`. Kept for decoding old configs.
    public var preferredInputUID: String?
    /// Deprecated — migrated into `favoriteInputUIDs`.
    public var dockedInputUID: String?
    /// How many recent recordings to show in the menu (the full history is always
    /// browsable in the Recordings window).
    public var recentsLimit: Int
    /// Days to retain the local backup of each recording (audio + transcript) under
    /// Application Support. Older backups are pruned on launch. 0 = keep forever.
    public var backupRetentionDays: Int
    /// Whether the user has been asked (once) about launching Transcripts at login.
    public var promptedLaunchAtLogin: Bool
    /// Bundle IDs that arm auto-record. Empty = arm for any app.
    public var autoRecordAppAllowlist: [String]
    public var pipeline: PipelineConfig
    /// Voice profiles (#6): remember confirmed voices locally so future
    /// recordings name known speakers automatically. Individual voices are only
    /// stored after an explicit per-person confirm (except the operator's own).
    public var rememberVoices: Bool
    /// The operator's own organization — the default affiliation for colleagues,
    /// and the fallback for any voice not tied to a client/case by routing.
    public var homeOrganization: String
    /// Minimum confidence (cosine similarity, 0…1) to put an enrolled name on a
    /// voice. Below it the speaker stays Me/Others rather than risk a wrong name.
    /// Deliberately conservative by default — name only when sure.
    public var nameMatchConfidence: Double
    /// Beta train: update checks also consider GitHub pre-releases.
    public var includePrereleases: Bool
    /// Preferred text-generation backend for Summarize/Classify.
    public var llmProvider: LLMProvider
    public var ollama: OllamaConfig
    public var whisper: WhisperConfig
    public var destinations: DestinationsConfig
    /// Optional "open with" command for a recording's document. `{path}` is replaced
    /// with the raw document path (e.g. `open -a "MarkText" "{path}"`); `{path_encoded}`
    /// with a URL-encoded path for URIs (e.g. `open "obsidian://open?path={path_encoded}"`).
    /// With no placeholder, the quoted path is appended. Empty/nil = Transcripts's built-in
    /// viewer. Lets the vault open in Obsidian or any app of choice.
    public var openCommand: String?

    public init(
        autoRecordOnMicActivation: Bool = true,
        captureSystemAudio: Bool = true,
        consentMode: ConsentMode = .oneParty,
        menuBarIcon: MenuBarIconStyle = AppConfig.defaultMenuBarIcon,
        recordingColorHex: String = AppConfig.defaultRecordingColorHex,
        archiveCodec: String = "m4a-aac-256",
        favoriteInputUIDs: [String] = [],
        favoriteInputNamesByUID: [String: String] = [:],
        overrideInputUID: String? = nil,
        preferredInputUID: String? = nil,
        dockedInputUID: String? = nil,
        recentsLimit: Int = 10,
        backupRetentionDays: Int = 30,
        promptedLaunchAtLogin: Bool = false,
        autoRecordAppAllowlist: [String] = [],
        pipeline: PipelineConfig,
        rememberVoices: Bool = false,
        homeOrganization: String = "Blue Acorn iCi",
        nameMatchConfidence: Double = 0.65,
        includePrereleases: Bool = false,
        llmProvider: LLMProvider = .appleOnDevice,
        ollama: OllamaConfig = .init(),
        whisper: WhisperConfig = .init(),
        destinations: DestinationsConfig = .init(),
        openCommand: String? = nil
    ) {
        self.autoRecordOnMicActivation = autoRecordOnMicActivation
        self.captureSystemAudio = captureSystemAudio
        self.consentMode = consentMode
        self.menuBarIcon = menuBarIcon
        self.recordingColorHex = recordingColorHex
        self.archiveCodec = archiveCodec
        self.favoriteInputUIDs = favoriteInputUIDs
        self.favoriteInputNamesByUID = favoriteInputNamesByUID
        self.overrideInputUID = overrideInputUID
        self.preferredInputUID = preferredInputUID
        self.dockedInputUID = dockedInputUID
        self.recentsLimit = recentsLimit
        self.backupRetentionDays = backupRetentionDays
        self.promptedLaunchAtLogin = promptedLaunchAtLogin
        self.autoRecordAppAllowlist = autoRecordAppAllowlist
        self.pipeline = pipeline
        self.rememberVoices = rememberVoices
        self.homeOrganization = homeOrganization
        self.nameMatchConfidence = nameMatchConfidence
        self.includePrereleases = includePrereleases
        self.llmProvider = llmProvider
        self.ollama = ollama
        self.whisper = whisper
        self.destinations = destinations
        self.openCommand = openCommand
    }

    /// Tolerant decoding: missing keys keep their defaults instead of failing (and
    /// wiping the user's saved settings) when a new field is added.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func v<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T { (try? c.decode(T.self, forKey: key)) ?? fallback }
        autoRecordOnMicActivation = v(.autoRecordOnMicActivation, true)
        captureSystemAudio = v(.captureSystemAudio, true)
        consentMode = v(.consentMode, .oneParty)
        menuBarIcon = v(.menuBarIcon, Self.defaultMenuBarIcon)
        recordingColorHex = HexColor.normalize(v(.recordingColorHex, Self.defaultRecordingColorHex),
                                               fallback: Self.defaultRecordingColorHex)
        archiveCodec = v(.archiveCodec, "m4a-aac-256")
        favoriteInputUIDs = v(.favoriteInputUIDs, [])
        favoriteInputNamesByUID = v(.favoriteInputNamesByUID, [:])
        overrideInputUID = try? c.decode(String.self, forKey: .overrideInputUID)
        preferredInputUID = try? c.decode(String.self, forKey: .preferredInputUID)
        dockedInputUID = try? c.decode(String.self, forKey: .dockedInputUID)
        recentsLimit = v(.recentsLimit, 10)
        backupRetentionDays = v(.backupRetentionDays, 30)
        promptedLaunchAtLogin = v(.promptedLaunchAtLogin, false)
        autoRecordAppAllowlist = v(.autoRecordAppAllowlist, [])
        pipeline = v(.pipeline, Self.defaultPipeline)
        rememberVoices = v(.rememberVoices, false)
        homeOrganization = v(.homeOrganization, "Blue Acorn iCi")
        nameMatchConfidence = v(.nameMatchConfidence, 0.65)
        includePrereleases = v(.includePrereleases, false)
        llmProvider = v(.llmProvider, .appleOnDevice)
        ollama = v(.ollama, .init())
        whisper = v(.whisper, .init())
        destinations = v(.destinations, .init())
        openCommand = try? c.decode(String.self, forKey: .openCommand)
    }

    /// The menu-bar icon a fresh install starts on.
    ///
    /// The ancestor of this code sniffed the Mac's MDM enrollment to decide
    /// whether to show an agency's mark by default. That is gone: guessing whose
    /// laptop this is in order to brand it is exactly the sort of thing an app
    /// on a stranger's machine should not do, and every style here is one click
    /// apart in Settings anyway.
    public static var defaultMenuBarIcon: MenuBarIconStyle { .waveform }

    /// Recording-indicator color for a fresh install. Both presets stay one click
    /// apart in Settings.
    public static var defaultRecordingColorHex: String { HexColor.recordingRed }

    static var defaultPipeline: PipelineConfig {
        PipelineConfig(
            mode: .bakedIn,
            handoffCommand: ExternalCommand(executable: "/bin/bash",
                                            arguments: ["-c", "echo handoff received: ${audioURL}"]),
            stages: StageID.allCases.map { StageConfig(id: $0, provider: .native) })
    }

    /// The default config: baked-in mode, all native stages in canonical order.
    ///
    /// Folder defaults are resolved at first run rather than baked in, so a Mac
    /// with iCloud Drive lands on the folder its phone and iPad can also reach.
    /// Only ever used when no config file exists — see `ConfigStore.load`.
    public static var `default`: AppConfig {
        var cfg = AppConfig(pipeline: defaultPipeline)
        cfg.destinations = DestinationsConfig(
            knowledgeRoot: Locations.defaultKnowledgeRoot(),
            deviceInbox: Locations.defaultDeviceInbox())
        return cfg
    }
}
