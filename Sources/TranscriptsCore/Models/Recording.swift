import Foundation

/// Metadata about the app that was frontmost when a recording began.
///
/// On macOS this is populated from `NSWorkspace.frontmostApplication`. On iOS it
/// is `nil` (there is no concept of "the other app using the mic").
public struct ActiveAppContext: Codable, Equatable, Sendable {
    public var appName: String?
    public var bundleID: String?
    public var capturedAt: Date

    public init(appName: String? = nil, bundleID: String? = nil, capturedAt: Date) {
        self.appName = appName
        self.bundleID = bundleID
        self.capturedAt = capturedAt
    }
}

/// A single captured recording (or a text-only personal note).
public struct Recording: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    /// The captured audio on disk. For a text-only note this points at the note
    /// markdown instead and `isNote` is true.
    public var audioURL: URL
    public var startedAt: Date
    public var endedAt: Date?
    public var activeApp: ActiveAppContext?
    public var title: String?
    /// Meeting-app window titles captured at record time (e.g. "Contoso Rollout
    /// Standup | Microsoft Teams") — a strong routing signal, often naming the client.
    public var windowTitles: [String]
    /// True when this is a typed personal note rather than an audio capture;
    /// the pipeline skips Encode/Transcribe for notes.
    public var isNote: Bool
    /// Peak input level seen while recording (0…1). Near-zero means the mic captured
    /// silence (e.g. a dead webcam mic) — used to flag empty recordings.
    public var peakLevel: Float?
    /// For calls: your side of the conversation (the raw mic track, pre-mix).
    /// Together with `systemAudioURL` this enables speaker attribution — the mic
    /// track is you by construction. `audioURL` holds the mixed archive.
    public var micAudioURL: URL?
    /// For calls: the other participants (system audio via ScreenCaptureKit).
    public var systemAudioURL: URL?
    /// Seconds the system-audio capture started after the mic capture — shifts the
    /// system track's timestamps onto the mic track's timeline.
    public var systemAudioStartOffset: Double?

    public init(
        id: UUID = UUID(),
        audioURL: URL,
        startedAt: Date,
        endedAt: Date? = nil,
        activeApp: ActiveAppContext? = nil,
        title: String? = nil,
        windowTitles: [String] = [],
        isNote: Bool = false,
        peakLevel: Float? = nil,
        micAudioURL: URL? = nil,
        systemAudioURL: URL? = nil,
        systemAudioStartOffset: Double? = nil
    ) {
        self.id = id
        self.audioURL = audioURL
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.activeApp = activeApp
        self.title = title
        self.windowTitles = windowTitles
        self.isNote = isNote
        self.peakLevel = peakLevel
        self.micAudioURL = micAudioURL
        self.systemAudioURL = systemAudioURL
        self.systemAudioStartOffset = systemAudioStartOffset
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        audioURL = try c.decode(URL.self, forKey: .audioURL)
        startedAt = try c.decode(Date.self, forKey: .startedAt)
        endedAt = try? c.decode(Date.self, forKey: .endedAt)
        activeApp = try? c.decode(ActiveAppContext.self, forKey: .activeApp)
        title = try? c.decode(String.self, forKey: .title)
        windowTitles = (try? c.decode([String].self, forKey: .windowTitles)) ?? []
        isNote = (try? c.decode(Bool.self, forKey: .isNote)) ?? false
        peakLevel = try? c.decode(Float.self, forKey: .peakLevel)
        micAudioURL = try? c.decode(URL.self, forKey: .micAudioURL)
        systemAudioURL = try? c.decode(URL.self, forKey: .systemAudioURL)
        systemAudioStartOffset = try? c.decode(Double.self, forKey: .systemAudioStartOffset)
    }

    /// Elapsed seconds, or nil while still recording.
    public var durationSeconds: Double? {
        guard let endedAt else { return nil }
        return endedAt.timeIntervalSince(startedAt)
    }

    /// A unique, filesystem-safe base name for this recording's artifacts, e.g.
    /// `2026-07-01-1508-xcode`. Combines the start timestamp (which makes it unique
    /// per recording) with a sanitized tag for the app that was frontmost, so the
    /// dropped files are self-describing and never overwrite an earlier recording.
    public var slug: String {
        let tag = Recording.sanitize(activeApp?.appName ?? (isNote ? "note" : "recording"))
        return tag.isEmpty ? stamp : "\(stamp)-\(tag)"
    }

    /// The timestamp prefix shared by all of this recording's artifact names,
    /// e.g. `2026-07-01-1508`.
    public var stamp: String {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = .current
        fmt.dateFormat = "yyyy-MM-dd-HHmm"
        return fmt.string(from: startedAt)
    }

    /// The standard artifact base name once a content-derived title exists, e.g.
    /// `2026-07-07-1545-strategy-for-lower-cost-discovery-option`. Falls back to
    /// `slug` when there is no title or it sanitizes to nothing.
    public func slug(titled title: String?) -> String {
        guard let title else { return slug }
        let t = Recording.titleSlug(title)
        return t.isEmpty ? slug : "\(stamp)-\(t)"
    }

    /// A title sanitized for a filename and clamped to 60 characters, cutting at
    /// a word boundary so names never end mid-word.
    public static func titleSlug(_ title: String) -> String {
        var t = sanitize(title)
        if t.count > 60 {
            t = String(t.prefix(60))
            if let cut = t.lastIndex(of: "-") { t = String(t[..<cut]) }
        }
        return t
    }

    /// Lowercases, replaces runs of non-alphanumerics with single hyphens, and trims
    /// hyphens — safe for a filename component on any platform.
    public static func sanitize(_ raw: String) -> String {
        let lowered = raw.lowercased()
        var out = ""
        var lastWasDash = false
        for scalar in lowered.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                out.unicodeScalars.append(scalar)
                lastWasDash = false
            } else if !lastWasDash {
                out.append("-")
                lastWasDash = true
            }
        }
        return out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}
