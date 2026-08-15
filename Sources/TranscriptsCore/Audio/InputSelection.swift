import Foundation

/// A microphone as seen by the selection logic — just the facts that matter for
/// choosing, with the CoreAudio plumbing stripped away so the decision rules can
/// be unit-tested without audio hardware. The app layer (`AudioInputDevices`)
/// maps real devices into these, asks `InputSelection` to decide, and maps back.
public struct AudioInputCandidate: Equatable, Sendable {
    public let uid: String
    public let name: String
    /// True when this device is the current macOS default input.
    public let isSystemDefault: Bool

    public init(uid: String, name: String, isSystemDefault: Bool = false) {
        self.uid = uid
        self.name = name
        self.isSystemDefault = isSystemDefault
    }
}

/// The pure decision rules for which microphone to record from, and how to label
/// a remembered device that isn't connected. No CoreAudio — everything here is
/// deterministic on its inputs, which is what makes the critical path testable.
public enum InputSelection {

    /// Heuristic for the Mac's built-in microphone (the automatic fallback, never
    /// preferred over an external mic — on a docked/clamshell Mac it's silent).
    public static func isBuiltInName(_ name: String) -> Bool {
        let n = name.lowercased()
        return n.contains("macbook") || n.contains("built-in") || n.contains("built in")
    }

    /// Resolves which device to record from:
    /// 1. the explicit **override**, when connected — set by clicking a mic in
    ///    Settings; beats everything,
    /// 2. else the **call's own device** — the input the meeting app is actively
    ///    capturing from (`callDeviceUIDs`). During a call this is ground truth:
    ///    if Teams is talking through the AirPods, favorites don't matter, that's
    ///    where the conversation is,
    /// 3. else the highest-priority connected **favorite**, top to bottom, with
    ///    external favorites beating built-in ones (the built-in is the fallback),
    /// 4. else the system default — unless that's the built-in mic and an external
    ///    mic is available (docked/clamshell, where the built-in is silent),
    /// 5. else any external mic, else the default/first.
    ///
    /// `excluding` removes devices known to be dead this session (the dead-mic
    /// alarm feeds it) from every tier, so a recovery restart can't re-pick the
    /// mic that just produced silence.
    ///
    /// Favorites make this work across machines: keep each desk's mic as a
    /// favorite; only one is present at a time, so the right one is chosen
    /// automatically. When several favorites are connected at once, the user's
    /// priority order decides — that's the contract the Settings UI promises
    /// ("top = highest priority"), so the macOS default deliberately does NOT
    /// outrank a higher-priority favorite here.
    public static func resolve(devices allDevices: [AudioInputCandidate],
                               favorites: [String],
                               override: String? = nil,
                               callDeviceUIDs: [String] = [],
                               excluding: Set<String> = []) -> AudioInputCandidate? {
        let devices = allDevices.filter { !excluding.contains($0.uid) }

        // Explicit override wins outright, when it's connected.
        if let override, let forced = devices.first(where: { $0.uid == override }) {
            return forced
        }

        // The device the meeting app is capturing from is where the call actually
        // is — follow it even when it isn't a favorite (e.g. AirPods joined ad hoc).
        for uid in callDeviceUIDs {
            if let live = devices.first(where: { $0.uid == uid }) { return live }
        }

        // Favorites present right now, in the user's priority order.
        let present = favorites.compactMap { uid in devices.first { $0.uid == uid } }
        if !present.isEmpty {
            // Prefer an external favorite over a built-in one (the built-in is the
            // fallback, and is often the macOS default even when docked).
            let externals = present.filter { !isBuiltInName($0.name) }
            let pool = externals.isEmpty ? present : externals
            return pool.first
        }

        // No favorite connected → system default, preferring external over built-in.
        let systemDefault = devices.first { $0.isSystemDefault }
        if let systemDefault, !isBuiltInName(systemDefault.name) {
            return systemDefault
        }
        if let external = devices.first(where: { !isBuiltInName($0.name) }) {
            return external
        }
        return systemDefault ?? devices.first
    }

    /// A currently-live input aggregate device, reduced to the facts the switch
    /// decision needs: its UID and the UIDs of the sub-devices it aggregates.
    public struct AggregateFacts: Equatable, Sendable {
        public let uid: String
        public let subDeviceUIDs: [String]
        public init(uid: String, subDeviceUIDs: [String]) {
            self.uid = uid
            self.subDeviceUIDs = subDeviceUIDs
        }
    }

    /// When a call app (Teams/Zoom/FaceTime) engages echo cancellation on a mic,
    /// macOS builds a Voice-Processing **aggregate** device that takes over that
    /// mic's hardware stream. A second, plain HAL client (us) then reads the raw
    /// device as pure digital silence — the live signal now lives *inside* the
    /// aggregate. Given the silent device's UID and the live input aggregates,
    /// returns the aggregate to record from instead: the first one whose
    /// sub-devices include the silent device. nil when none qualifies — which is
    /// the common case (an ordinary dead/muted mic, not a stolen one).
    ///
    /// This is the one situation where switching away from a *forced* device is
    /// still right: a forced built-in mic that an aggregate has swallowed cannot
    /// physically produce signal, and the aggregate carries the same mic.
    public static func aggregateOwning(deadUID: String,
                                       aggregates: [AggregateFacts]) -> String? {
        aggregates.first { $0.uid != deadUID && $0.subDeviceUIDs.contains(deadUID) }?.uid
    }

    /// How a device is physically attached, as far as the steal heuristic cares.
    /// Bluetooth is called out because headsets legitimately run at voice rates —
    /// the whole point of the distinction below.
    public enum Transport: Equatable, Sendable {
        case builtIn, usb, bluetooth, other
    }

    /// Highest sample rate that means "something has put this device into
    /// voice-processing mode". Wired mics idle at 44.1/48 kHz; macOS drops them to
    /// 24 kHz (or 16) when a call app engages echo cancellation.
    public static let voiceProcessingSampleRate: Double = 24_000

    /// True when a *silent* device looks like it has been taken over by a call
    /// app's echo cancellation rather than being genuinely dead.
    ///
    /// Field evidence (2026-07-22, GH #12): an MX Brio recorded pure digital zero
    /// for 75 and 22 minutes across two Teams calls, and the recorder log shows
    /// `format=24000Hz` on exactly those two — every healthy session on the same
    /// mic was 48 kHz. The published-aggregate lookup found nothing, because macOS
    /// only publishes a `CADefaultDeviceAggregate` for some devices; the rate drop
    /// is visible either way.
    ///
    /// Bluetooth is excluded deliberately: AirPods run at 24 kHz natively in
    /// headset mode and record perfectly well there (peak 1.787 the same
    /// afternoon), so rate alone would condemn them. A wired mic sitting at a
    /// voice rate has had that rate imposed on it by another process.
    public static func looksVoiceProcessed(transport: Transport, sampleRate: Double) -> Bool {
        switch transport {
        case .builtIn, .usb: return sampleRate > 0 && sampleRate <= voiceProcessingSampleRate
        case .bluetooth, .other: return false
        }
    }

    /// Best-effort label for a persisted CoreAudio UID when the device is not
    /// currently connected and no cached display name exists yet. USB UIDs carry
    /// "AppleUSBAudioEngine:<manufacturer>:<model>:<serial>:<interface>", which
    /// yields a decent human name; anything else falls back to the UID's last
    /// path-ish component, or nil when there's nothing presentable.
    public static func rememberedName(forUID uid: String) -> String? {
        if uid == "BuiltInMicrophoneDevice" {
            return "MacBook Pro Microphone"
        }

        let parts = uid.split(separator: ":").map(String.init)
        guard !parts.isEmpty else { return nil }

        if parts.first == "AppleUSBAudioEngine", parts.count >= 4 {
            let manufacturer = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            let model = parts[2].trimmingCharacters(in: .whitespacesAndNewlines)

            if manufacturer.caseInsensitiveCompare("Unknown Manufacturer") == .orderedSame {
                return model.isEmpty ? nil : model
            }
            if model.isEmpty { return manufacturer.isEmpty ? nil : manufacturer }
            if model.localizedCaseInsensitiveContains(manufacturer) { return model }
            if manufacturer.isEmpty { return model }
            return "\(manufacturer) \(model)"
        }

        if let tail = parts.last?.trimmingCharacters(in: .whitespacesAndNewlines), !tail.isEmpty {
            return tail
        }
        return nil
    }
}
