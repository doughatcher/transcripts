import Foundation
import CoreAudio

/// Detects an active call by asking CoreAudio which *processes* are currently
/// capturing microphone input, and matching them against known meeting apps
/// (`MeetingDetector.meetingApps`).
///
/// Why process-level and not "is any input device live": Transcripts itself holds the
/// mic while recording, so a device-level check would never see the call end. The
/// meeting app's *own* input usage is the true call signal, and it's independent of
/// Transcripts's capture. macOS 14.4+ exposes this via CoreAudio process objects.
///
/// Polls on a timer and fires `onCallStarted` / `onCallEnded` on transitions.
final class CallDetector {
    var onCallStarted: ((String) -> Void)?   // meeting app name
    var onCallEnded: (() -> Void)?

    private var timer: Timer?
    private var inCall = false
    private var offStreak = 0
    private let interval: TimeInterval

    init(interval: TimeInterval = 2) { self.interval = interval }

    func start() {
        timer?.invalidate()
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.evaluate() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        Task { @MainActor in self.evaluate() }
    }

    func stop() { timer?.invalidate(); timer = nil }

    private func evaluate() {
        let app = Self.meetingAppUsingInput()
        if let app {
            offStreak = 0
            if !inCall { inCall = true; onCallStarted?(app) }
        } else if inCall {
            // Require two consecutive "off" polls to ride out brief mute/route blips.
            offStreak += 1
            if offStreak >= 2 { inCall = false; offStreak = 0; onCallEnded?() }
        }
    }

    /// The friendly name of a meeting app currently capturing input, if any.
    static func meetingAppUsingInput() -> String? {
        for proc in processObjects() {
            guard isRunningInput(proc), let bid = bundleID(proc)?.lowercased() else { continue }
            if let match = MeetingDetector.meetingApps.first(where: { bid.hasPrefix($0.idFragment.lowercased()) }) {
                return match.name
            }
        }
        return nil
    }

    /// The UIDs of the devices the active meeting app is doing audio IO on —
    /// where the conversation actually is. The list may include the app's output
    /// device too; callers match it against known *input* devices, which filters
    /// that out. Empty when no call is active (or the OS doesn't expose it).
    static func meetingAppDeviceUIDs() -> [String] {
        var uids: [String] = []
        for proc in processObjects() {
            guard isRunningInput(proc), let bid = bundleID(proc)?.lowercased() else { continue }
            guard MeetingDetector.meetingApps.contains(where: { bid.hasPrefix($0.idFragment.lowercased()) }) else { continue }
            for dev in processDevices(proc) {
                if let uid = deviceUID(dev), !uids.contains(uid) { uids.append(uid) }
            }
        }
        return uids
    }

    /// True when any process other than Transcripts itself is capturing input.
    /// The device-level "is running somewhere" signal can't end a generic
    /// auto-recording — our own capture keeps it true forever — so the stop
    /// side has to ask process-by-process, the way call detection does.
    ///
    /// System capture daemons are not conversations: replayd (screen recording)
    /// has been observed holding an input stream open for hours, which would
    /// pin every generic recording on just like our own capture did.
    private static let ignoredCapturers = ["com.apple.replayd"]

    static func anyOtherProcessUsingInput() -> Bool {
        let me = ProcessInfo.processInfo.processIdentifier
        for proc in processObjects() where isRunningInput(proc) {
            if processPID(proc) == me { continue }
            if let bid = bundleID(proc), ignoredCapturers.contains(bid) { continue }
            return true
        }
        return false
    }

    private static func processPID(_ proc: AudioObjectID) -> pid_t? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: pid_t = -1
        var size = UInt32(MemoryLayout<pid_t>.size)
        guard AudioObjectGetPropertyData(proc, &addr, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    // MARK: - CoreAudio process objects

    private static func processObjects() -> [AudioObjectID] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var ids = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func isRunningInput(_ proc: AudioObjectID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunningInput,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(proc, &addr, 0, nil, &size, &value) == noErr else { return false }
        return value != 0
    }

    /// The device objects a process is currently doing IO on.
    private static func processDevices(_ proc: AudioObjectID) -> [AudioObjectID] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(proc, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var ids = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(proc, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func deviceUID(_ device: AudioObjectID) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var cf: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &cf) == noErr else { return nil }
        return cf?.takeRetainedValue() as String?
    }

    private static func bundleID(_ proc: AudioObjectID) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyBundleID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var cf: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(proc, &addr, 0, nil, &size, &cf) == noErr else { return nil }
        return cf?.takeRetainedValue() as String?
    }
}
