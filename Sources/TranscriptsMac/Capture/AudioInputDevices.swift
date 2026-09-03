import Foundation
import CoreAudio
import AudioToolbox
import TranscriptsCore
import TranscriptsEngine

/// A selectable microphone input device.
struct AudioInputDevice: Identifiable, Hashable {
    /// CoreAudio device UID — stable across reconnects; persisted as the preference.
    let uid: String
    let name: String
    let deviceID: AudioDeviceID
    var id: String { uid }
}

/// Enumerates CoreAudio input devices and resolves the one to record from. We use
/// CoreAudio directly (not AVCaptureDevice) because `AVAudioEngine` selects its
/// input by `AudioDeviceID`, which this gives us straight away.
enum AudioInputDevices {

    /// All devices that have at least one input channel.
    /// UID prefix of the aggregate `SystemAudioTap` builds to carry the system
    /// mix. It is an input device by construction, so without excluding it here
    /// it becomes a candidate *microphone* — and the dead-mic recovery, hunting
    /// for a device with signal when the real mic goes silent, picks the one
    /// device guaranteed to have some: our own tap. That fed a call's far side
    /// back in as the user's own voice and restarted capture in a loop.
    /// `kAudioAggregateDeviceIsPrivateKey` does not help: private hides the
    /// aggregate from *other* processes, never from the one that created it.
    static let systemAudioTapUIDPrefix = "ltd.hatcher.transcripts.systemaudio."

    static func all() -> [AudioInputDevice] {
        deviceIDs().compactMap { id in
            guard inputChannelCount(id) > 0 else { return nil }
            guard let uid = stringProperty(id, kAudioDevicePropertyDeviceUID),
                  let name = stringProperty(id, kAudioObjectPropertyName) else { return nil }
            guard !uid.hasPrefix(systemAudioTapUIDPrefix) else { return nil }
            return AudioInputDevice(uid: uid, name: name, deviceID: id)
        }
    }

    /// Resolves which device to record from. The decision rules (override →
    /// favorites by priority → smart default) are pure logic in
    /// `TranscriptsCore.InputSelection`, unit-tested against fixture device lists;
    /// this wrapper only supplies the live CoreAudio facts.
    static func resolve(favorites: [String], override: String? = nil,
                        callDeviceUIDs: [String] = [], excluding: Set<String> = []) -> AudioInputDevice? {
        let devices = all()
        let defID = defaultInput()
        let candidates = devices.map {
            AudioInputCandidate(uid: $0.uid, name: $0.name, isSystemDefault: $0.deviceID == defID)
        }
        guard let chosen = InputSelection.resolve(devices: candidates,
                                                  favorites: favorites,
                                                  override: override,
                                                  callDeviceUIDs: callDeviceUIDs,
                                                  excluding: excluding) else { return nil }
        return devices.first { $0.uid == chosen.uid }
    }

    static func isBuiltIn(_ device: AudioInputDevice) -> Bool {
        InputSelection.isBuiltInName(device.name)
    }

    /// The device's input mute state, when it exposes one (AirPods and many
    /// USB mics do — the macOS menu-bar / stem-press mic mute sets it). A muted
    /// mic reads digital zero in every app, which is indistinguishable from a
    /// dead device by signal alone. nil = the device doesn't report mute.
    static func isInputMuted(_ device: AudioInputDevice) -> Bool? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(device.deviceID, &addr) else { return nil }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device.deviceID, &addr, 0, nil, &size, &value) == noErr else {
            return nil
        }
        return value != 0
    }

    /// Best-effort label for a persisted CoreAudio UID when the device is not
    /// currently connected and no cached display name exists yet.
    static func rememberedName(forUID uid: String) -> String? {
        InputSelection.rememberedName(forUID: uid)
    }

    /// When a call app engages echo cancellation, macOS builds a Voice-Processing
    /// aggregate that owns the mic's hardware stream — and a second plain HAL
    /// client (our engine) reading the raw device gets digital silence. This finds
    /// a currently-running input aggregate that lists `device` among its
    /// sub-devices: that aggregate is where `device`'s live signal actually is, so
    /// recording it recovers our own side of the call. nil when no such aggregate
    /// exists (the ordinary "the mic is just dead/muted" case). Only *published*
    /// aggregates are visible here; a private VP aggregate can't be recovered, but
    /// then it wouldn't appear in the picker either.
    static func liveAggregate(owning device: AudioInputDevice) -> AudioInputDevice? {
        let devices = all()
        let liveAggregates: [InputSelection.AggregateFacts] = devices.compactMap { d in
            guard isAggregate(d.deviceID), isRunningSomewhere(d.deviceID) else { return nil }
            return InputSelection.AggregateFacts(uid: d.uid,
                                                 subDeviceUIDs: aggregateSubDeviceUIDs(d.deviceID))
        }
        guard let uid = InputSelection.aggregateOwning(deadUID: device.uid,
                                                       aggregates: liveAggregates) else {
            // Worth a line: when a mic is stolen but no aggregate is published, this
            // is the only record of what CoreAudio was showing at the time. Without
            // it a stand-down is indistinguishable from a genuinely dead mic.
            let seen = devices.filter { isAggregate($0.deviceID) }
                .map { "\($0.name)[running=\(isRunningSomewhere($0.deviceID)) subs=\(aggregateSubDeviceUIDs($0.deviceID).count)]" }
            Log.write("deadmic: no aggregate owns '\(device.name)' — aggregates present: \(seen.isEmpty ? "none" : seen.joined(separator: ", "))")
            return nil
        }
        return devices.first { $0.uid == uid }
    }

    /// True when this silent device looks like a call app's echo cancellation has
    /// taken it over (see `InputSelection.looksVoiceProcessed`). Supplies the live
    /// CoreAudio facts — transport type and current nominal sample rate — to the
    /// tested decision rule.
    static func looksVoiceProcessed(_ device: AudioInputDevice) -> Bool {
        InputSelection.looksVoiceProcessed(transport: transport(device.deviceID),
                                           sampleRate: nominalSampleRate(device.deviceID))
    }

    /// Transport + rate as a log-friendly string, so a dead-mic episode records what
    /// the device actually looked like.
    static func describeSignalPath(_ device: AudioInputDevice) -> String {
        "transport=\(transport(device.deviceID)) rate=\(Int(nominalSampleRate(device.deviceID)))Hz"
    }

    static func transport(_ device: AudioDeviceID) -> InputSelection.Transport {
        switch transportType(device) {
        case kAudioDeviceTransportTypeBuiltIn: return .builtIn
        case kAudioDeviceTransportTypeUSB: return .usb
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return .bluetooth
        default: return .other
        }
    }

    static func nominalSampleRate(_ device: AudioDeviceID) -> Double {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: Double = 0
        var size = UInt32(MemoryLayout<Double>.size)
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &value) == noErr else { return 0 }
        return value
    }

    private static func transportType(_ device: AudioDeviceID) -> UInt32 {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &transport) == noErr else { return 0 }
        return transport
    }

    private static func isAggregate(_ device: AudioDeviceID) -> Bool {
        transportType(device) == kAudioDeviceTransportTypeAggregate
    }

    private static func isRunningSomewhere(_ device: AudioDeviceID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &value) == noErr else { return false }
        return value != 0
    }

    /// UIDs of the sub-devices an aggregate is built from (empty for non-aggregates
    /// or when the property is unavailable). `FullSubDeviceList` is a CFArray of
    /// CFString device UIDs — directly comparable to `AudioInputDevice.uid`.
    private static func aggregateSubDeviceUIDs(_ device: AudioDeviceID) -> [String] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioAggregateDevicePropertyFullSubDeviceList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(device, &addr) else { return [] }
        var cf: Unmanaged<CFArray>?
        var size = UInt32(MemoryLayout<Unmanaged<CFArray>?>.size)
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &cf) == noErr,
              let list = cf?.takeRetainedValue() as? [String] else { return [] }
        return list
    }

    // MARK: - CoreAudio plumbing

    private static func deviceIDs() -> [AudioDeviceID] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func inputChannelCount(_ device: AudioDeviceID) -> Int {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let data = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { data.deallocate() }
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, data) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(data.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func stringProperty(_ device: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var cf: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &cf) == noErr else { return nil }
        return cf?.takeRetainedValue() as String?
    }

    static func defaultInput() -> AudioDeviceID? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &device) == noErr else { return nil }
        return device == kAudioObjectUnknown ? nil : device
    }
}
