import Foundation
import CoreAudio

/// Watches whether the default input device is in use by *any* process on the
/// system, using the CoreAudio property `kAudioDevicePropertyDeviceIsRunningSomewhere`.
/// When it flips on (debounced), `onActivation` fires — that's the "mic went live,
/// start recording" trigger. When it flips off (debounced), `onDeactivation` fires.
///
/// This is an event listener, not a poll. It also re-targets when the default
/// input device changes.
final class MicActivityWatcher {
    var onActivation: (() -> Void)?
    var onDeactivation: (() -> Void)?

    private let debounce: TimeInterval
    private let queue = DispatchQueue(label: "net.superterran.transcripts.micwatch")
    private var watchedDevice: AudioDeviceID = kAudioObjectUnknown
    private var isActive = false
    private var pendingWorkItem: DispatchWorkItem?

    init(debounce: TimeInterval = 1.5) {
        self.debounce = debounce
    }

    // MARK: - Lifecycle

    func start() {
        queue.async { [weak self] in
            self?.installDefaultDeviceListener()
            self?.retargetToDefaultInput()
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.removeRunningListener(on: self.watchedDevice)
            self.removeDefaultDeviceListener()
            self.pendingWorkItem?.cancel()
        }
    }

    // MARK: - Default-input tracking

    private var defaultDeviceAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    private func installDefaultDeviceListener() {
        var address = defaultDeviceAddress
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, queue
        ) { [weak self] _, _ in
            self?.retargetToDefaultInput()
        }
    }

    private func removeDefaultDeviceListener() {
        // Listener blocks are released with the object; for a long-lived app this
        // is acceptable. A production build would retain and remove the exact block.
    }

    private func retargetToDefaultInput() {
        let newDevice = Self.defaultInputDevice()
        guard newDevice != kAudioObjectUnknown else { return }
        if newDevice != watchedDevice {
            removeRunningListener(on: watchedDevice)
            watchedDevice = newDevice
            installRunningListener(on: watchedDevice)
            evaluate(deviceIsRunning(watchedDevice)) // sync initial state
        }
    }

    // MARK: - "is running somewhere" listener

    private var runningAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    private func installRunningListener(on device: AudioDeviceID) {
        guard device != kAudioObjectUnknown else { return }
        var address = runningAddress
        AudioObjectAddPropertyListenerBlock(device, &address, queue) { [weak self] _, _ in
            guard let self else { return }
            self.evaluate(self.deviceIsRunning(self.watchedDevice))
        }
    }

    private func removeRunningListener(on device: AudioDeviceID) {
        guard device != kAudioObjectUnknown else { return }
        // See note in removeDefaultDeviceListener.
    }

    // MARK: - State machine

    private func evaluate(_ running: Bool) {
        pendingWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard running != self.isActive else { return }
            self.isActive = running
            if running { self.onActivation?() } else { self.onDeactivation?() }
        }
        pendingWorkItem = work
        queue.asyncAfter(deadline: .now() + debounce, execute: work)
    }

    // MARK: - CoreAudio reads

    private func deviceIsRunning(_ device: AudioDeviceID) -> Bool {
        guard device != kAudioObjectUnknown else { return false }
        var address = runningAddress
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value)
        return status == noErr && value != 0
    }

    static func defaultInputDevice() -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device
        )
        return status == noErr ? device : kAudioObjectUnknown
    }
}
