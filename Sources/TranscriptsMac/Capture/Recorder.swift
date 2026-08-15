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

        // Write the tap's native LPCM format straight through — no encoder on the
        // hot path (an encoder config error can stop the whole engine; LPCM can't
        // fail that way, and it's what makes the CAF readable mid-write).
        audioFile = try AVAudioFile(forWriting: url, settings: format.settings)
        peak = 0
        currentLevel = 0

        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            self.measure(buffer)
            if let file = self.audioFile { try? file.write(from: buffer) }
            self.onBuffer?(buffer)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            audioFile = nil
            throw RecorderError.engineStart(error.localizedDescription)
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
