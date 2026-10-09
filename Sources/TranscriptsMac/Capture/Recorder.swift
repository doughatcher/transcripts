import Foundation
import AVFoundation
import CoreAudio
import AudioToolbox
import TranscriptsCore
import TranscriptsEngine

/// Records a chosen microphone to an `.m4a` using `AVAudioEngine` with an explicit
/// input device. Choosing the device is the whole point: on a docked/clamshell Mac
/// the *system default* input ("MacBook Pro Microphone") is dead and yields pure
/// silence, so we must be able to record from the Brio / USB mic instead — which
/// `AVAudioRecorder` cannot do (it only ever uses the default).
///
/// Per-buffer metering feeds the live EQ and proves whether real audio is arriving.
final class Recorder {
    enum RecorderError: Error, CustomStringConvertible {
        case alreadyRecording, notRecording
        case noInputDevice
        case engineStart(String)

        var description: String {
            switch self {
            case .alreadyRecording: return "already recording"
            case .notRecording: return "not recording"
            case .noInputDevice: return "no usable input device found"
            case .engineStart(let m): return "engine failed to start: \(m)"
            }
        }
    }

    private let engine = AVAudioEngine()
    private var audioFile: AVAudioFile?
    private(set) var isRecording = false
    private(set) var currentURL: URL?
    private var startedAt: Date?
    private var activeApp: ActiveAppContext?
    private var windowTitles: [String] = []

    /// The format the CAF was opened with. Every tap buffer is delivered in this
    /// format, through a converter when the device has moved on — so a mid-call
    /// device reconfiguration never changes what the file or the live
    /// transcriber sees.
    private var fileFormat: AVAudioFormat?
    private var configChangeObserver: (any NSObjectProtocol)?
    private var rebuildPending: DispatchWorkItem?

    private let meter = NSLock()
    private var peak: Float = 0
    private var currentLevel: Float = 0

    /// Optional live consumer of the mic buffers (streaming transcription).
    /// Called on the audio tap thread — implementations must be non-blocking.
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?

    let device: AudioInputDevice
    let captureSystemAudio: Bool
    /// Capture meeting-app window titles at start. Only true during an actual active
    /// call — otherwise Teams/Slack windows sitting open would wrongly name and route
    /// a non-meeting recording (e.g. a Slack channel title on a quick voice note).
    let captureWindowTitles: Bool

    init(device: AudioInputDevice, captureSystemAudio: Bool, captureWindowTitles: Bool = false) {
        self.device = device
        self.captureSystemAudio = captureSystemAudio
        self.captureWindowTitles = captureWindowTitles
    }

    @discardableResult
    func start(into directory: URL) throws -> URL {
        guard !isRecording else { throw RecorderError.alreadyRecording }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Crash-safe container: LPCM-in-CAF is readable at any truncation point,
        // so a kill/crash/power-loss mid-recording still leaves recoverable audio.
        // (AAC .m4a is worthless without its final header — two live-call
        // fragments were lost exactly that way on 2026-07-13.) EncodeStage
        // transcodes to archive AAC after the recording ends.
        let url = directory.appendingPathComponent("audio.caf")

        // Bind the engine's input to the chosen CoreAudio device BEFORE reading its
        // format or starting.
        let input = engine.inputNode
        if let unit = input.audioUnit {
            var dev = device.deviceID
            let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                              kAudioUnitScope_Global, 0, &dev,
                                              UInt32(MemoryLayout<AudioDeviceID>.size))
            if status != noErr {
                Log.write("recorder: ⚠️ could not select device '\(device.name)' (status \(status)); using engine default")
            }
        }

        let format = input.outputFormat(forBus: 0)
        Log.write("recorder: device='\(device.name)' uid=\(device.uid) format=\(Int(format.sampleRate))Hz \(format.channelCount)ch mic auth=\(Recorder.micAuthDescription)")
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw RecorderError.engineStart("selected device reports no channels")
        }

        // What the engine thinks the device runs at, versus what the device is
        // actually running at right now. They disagree when another client already
        // holds the device in voice-processing mode — a call app's echo canceller
        // drops it to 16k/24k — and the engine keeps reporting the rate it
        // negotiated. The tap then writes digital zero for the whole meeting, and
        // nothing says so until `stop()` reports peak=0.0 with the call already
        // over. The dead-mic watchdog does catch this, but not for 90 seconds, so
        // a short recording never hears about it at all. Say it at open instead.
        let hardwareRate = AudioInputDevices.nominalSampleRate(device.deviceID)
        if hardwareRate > 0, abs(hardwareRate - format.sampleRate) > 1 {
            Log.write("recorder: ⚠️ '\(device.name)' is running at \(Int(hardwareRate))Hz but the engine opened it at "
                      + "\(Int(format.sampleRate))Hz (\(AudioInputDevices.describeSignalPath(device))) — another app is "
                      + "probably holding it in echo-cancellation mode, and this track will record silence. "
                      + "Pick a different input in Settings ▸ General.")
        }

        // Write the tap's native LPCM format straight through — no encoder on the
        // hot path (an encoder config error can stop the whole engine; LPCM can't
        // fail that way, and it's what makes the CAF readable mid-write).
        audioFile = try AVAudioFile(forWriting: url, settings: format.settings)
        fileFormat = audioFile?.processingFormat
        peak = 0
        currentLevel = 0

        installTap(tapFormat: format)

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            audioFile = nil
            throw RecorderError.engineStart(error.localizedDescription)
        }

        // When a call app takes the mic in voice-processing mode (FaceTime
        // dropping the device to its 3ch call format), the engine reconfigures
        // and this tap stops receiving buffers — silently, no error, the track
        // just turns to digital zero for the rest of the call. The notification
        // is the only signal, and reconfiguration storms post it several times
        // back-to-back, so rebuild once after a short quiet gap.
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            guard let self, self.isRecording else { return }
            self.rebuildPending?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.rebuildAfterConfigurationChange() }
            self.rebuildPending = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
        }

        isRecording = true
        currentURL = url
        startedAt = Date()
        activeApp = ActiveAppProvider.current()
        windowTitles = captureWindowTitles ? WindowTitleProvider.meetingWindowTitles() : []
        if !windowTitles.isEmpty { Log.write("recorder: meeting window(s): \(windowTitles.joined(separator: " | "))") }
        Log.write("recorder: started into \(url.lastPathComponent)")
        return url
    }

    /// Latest input level in 0…1 for the EQ (updated per audio buffer).
    func sampleLevel() -> Float {
        meter.lock(); defer { meter.unlock() }
        return currentLevel
    }

    /// Highest absolute sample seen since start — the same number the silent
    /// verdict uses at stop, exposed live so a dead mic can be caught mid-recording.
    func samplePeak() -> Float {
        meter.lock(); defer { meter.unlock() }
        return peak
    }

    /// Merges freshly-sampled meeting window titles into the set captured at
    /// start. Titles improve mid-call (the Teams join screen becomes the real
    /// meeting window), and the accumulated set feeds routing + frontmatter.
    func mergeWindowTitles(_ titles: [String]) {
        for t in titles where !windowTitles.contains(t) {
            windowTitles.append(t)
        }
    }

    func stop() throws -> Recording {
        guard isRecording, let url = currentURL, let startedAt else {
            throw RecorderError.notRecording
        }
        if let configChangeObserver { NotificationCenter.default.removeObserver(configChangeObserver) }
        configChangeObserver = nil
        rebuildPending?.cancel()
        rebuildPending = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        audioFile = nil
        isRecording = false

        meter.lock(); let peakSeen = peak; meter.unlock()
        if AudioLevel.isSilent(peak: peakSeen) {
            Log.write("recorder: ⚠️ '\(device.name)' was SILENT (peak=\(peakSeen)). Pick a different input in Settings ▸ General.")
        } else {
            Log.write("recorder: captured audio ok from '\(device.name)' (peak=\(String(format: "%.3f", peakSeen)))")
        }

        let recording = Recording(audioURL: url, startedAt: startedAt, endedAt: Date(), activeApp: activeApp, windowTitles: windowTitles, peakLevel: peakSeen)
        currentURL = nil
        self.startedAt = nil
        self.activeApp = nil
        return recording
    }

    // MARK: - Surviving device reconfiguration

    /// Taps the input in whatever format the device speaks right now, delivering
    /// downstream (file, meter, live transcriber) in `fileFormat` — converted
    /// when the two differ, passed straight through when they don't.
    private func installTap(tapFormat: AVAudioFormat) {
        let converter: AVAudioConverter?
        if let fileFormat, fileFormat != tapFormat {
            converter = AVAudioConverter(from: tapFormat, to: fileFormat)
        } else {
            converter = nil
        }
        let outFormat = fileFormat
        engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: tapFormat) { [weak self] buffer, _ in
            guard let self else { return }
            let delivered: AVAudioPCMBuffer
            if let converter, let outFormat {
                let ratio = outFormat.sampleRate / buffer.format.sampleRate
                let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
                guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { return }
                var fed = false
                var err: NSError?
                converter.convert(to: out, error: &err) { _, status in
                    if fed { status.pointee = .noDataNow; return nil }
                    fed = true
                    status.pointee = .haveData
                    return buffer
                }
                guard err == nil, out.frameLength > 0 else { return }
                delivered = out
            } else {
                delivered = buffer
            }
            self.measure(delivered)
            if let file = self.audioFile { try? file.write(from: delivered) }
            self.onBuffer?(delivered)
        }
    }

    /// Rebuilds the engine and tap after the input device changed shape under us.
    /// The tap format is re-read from the device, and the converter bridges it
    /// back to the format the file was opened with.
    private func rebuildAfterConfigurationChange() {
        guard isRecording else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()

        // Re-bind the chosen device: a reconfiguration can also reset the
        // engine's input back to the system default.
        if let unit = engine.inputNode.audioUnit {
            var dev = device.deviceID
            AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                 kAudioUnitScope_Global, 0, &dev,
                                 UInt32(MemoryLayout<AudioDeviceID>.size))
        }

        let newFormat = engine.inputNode.outputFormat(forBus: 0)
        guard newFormat.sampleRate > 0, newFormat.channelCount > 0 else {
            Log.write("recorder: ⚠️ device reconfigured to an unusable format — mic track paused until it recovers")
            return
        }
        // installTap raises an ObjC exception — uncatchable from Swift, so it
        // aborts the whole app — when the tap's rate differs from the hardware
        // side of the input node. That is exactly the state a call app's echo
        // canceller leaves behind: a webcam mic held at 32k by Teams while the
        // engine still reports 48k. Crashed twice on 2026-10-09, and the
        // relaunch resumed the call straight back into the same abort. Leave
        // the mic track paused instead; the next configuration change retries,
        // and the dead-mic watchdog can swap to a working input.
        let hardwareFormat = engine.inputNode.inputFormat(forBus: 0)
        guard abs(hardwareFormat.sampleRate - newFormat.sampleRate) <= 1 else {
            Log.write("recorder: ⚠️ device reconfigured with mismatched rates (hardware \(Int(hardwareFormat.sampleRate))Hz, "
                      + "engine \(Int(newFormat.sampleRate))Hz) — another app is probably holding '\(device.name)' in "
                      + "echo-cancellation mode; mic track paused until it recovers")
            return
        }
        Log.write("recorder: input device reconfigured (now \(Int(newFormat.sampleRate))Hz \(newFormat.channelCount)ch) — rebuilding tap")
        installTap(tapFormat: newFormat)
        engine.prepare()
        do {
            try engine.start()
        } catch {
            Log.write("recorder: ⚠️ engine restart after reconfiguration failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Metering

    private func measure(_ buffer: AVAudioPCMBuffer) {
        guard let ch = buffer.floatChannelData else { return }
        let n = Int(buffer.frameLength)
        guard n > 0 else { return }
        var sumSquares: Float = 0
        var localPeak: Float = 0
        for c in 0..<Int(buffer.format.channelCount) {
            let samples = ch[c]
            for i in 0..<n {
                let s = samples[i]
                sumSquares += s * s
                localPeak = max(localPeak, abs(s))
            }
        }
        // Interpretation (RMS → 0…1 meter level) is shared, tested logic in TranscriptsCore.
        let level = AudioLevel.meterLevel(sumSquares: sumSquares,
                                          sampleCount: n * Int(buffer.format.channelCount))
        meter.lock()
        currentLevel = level
        peak = max(peak, localPeak)
        meter.unlock()
    }

    static var micAuthDescription: String {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return "authorized"
        case .denied: return "DENIED"
        case .restricted: return "RESTRICTED"
        case .notDetermined: return "notDetermined"
        @unknown default: return "unknown"
        }
    }

    static func ensureMicAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }
}
