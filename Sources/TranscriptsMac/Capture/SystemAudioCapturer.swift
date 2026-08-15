import Foundation
import AVFoundation
import ScreenCaptureKit
import TranscriptsEngine

/// Captures **system audio** — everything playing out of the Mac's output, which
/// during a call is the *other participants* (Teams/Zoom render their voices to the
/// system mix). Our own mic is captured separately by `Recorder`; the two are mixed
/// at the end. Uses ScreenCaptureKit's audio path (`SCStream` + `.audio` output),
/// excluding our own process audio to avoid echo.
///
/// Requires the Screen Recording TCC grant. If it isn't granted (or anything fails)
/// we degrade to mic-only rather than losing the recording.
final class SystemAudioCapturer: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {

    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var startedSession = false
    private let queue = DispatchQueue(label: "ltd.hatcher.transcripts.sysaudio")
    private let lock = NSLock()
    private(set) var outputURL: URL?
    private(set) var wroteAnySamples = false
    /// Wall-clock time of the first written sample — aligns this track's timeline
    /// with the mic track's (which starts earlier) for speaker attribution.
    private(set) var firstSampleAt: Date?
    /// Wall-clock time audible signal was last seen — feeds dead-air detection
    /// (both call sides quiet for minutes ⇒ the meeting is probably over).
    private var lastAudibleAt: Date?
    /// Latest buffer's peak (0…1) and when it was measured — feeds the menu-bar
    /// pulse so the icon proves *capture* is flowing, not just the user's mic
    /// (muted-but-listening is the common call posture).
    private var levelValue: Float = 0
    private var levelAt: Date = .distantPast

    func lastAudible() -> Date? {
        lock.lock(); defer { lock.unlock() }
        return lastAudibleAt
    }

    /// Live output level for the UI; reads 0 when buffers stop arriving.
    func sampleLevel() -> Float {
        lock.lock(); defer { lock.unlock() }
        return Date().timeIntervalSince(levelAt) < 0.5 ? levelValue : 0
    }

    /// Optional live consumer of the system-audio buffers (streaming
    /// transcription). Called on the capture queue — must be non-blocking.
    var onSampleBuffer: ((CMSampleBuffer) -> Void)?

    /// Starts capturing system audio into `url` (a crash-safe `.caf`). Returns true
    /// on success; false means we couldn't start (no permission / no display) —
    /// caller continues mic-only.
    func start(into url: URL) async -> Bool {
        do {
            // Triggers the Screen Recording prompt on first use if not yet granted.
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            guard let display = content.displays.first else {
                Log.write("sysaudio: no display available; skipping system audio")
                return false
            }

            let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])

            let config = SCStreamConfiguration()
            config.capturesAudio = true
            config.excludesCurrentProcessAudio = true
            config.sampleRate = 48_000
            config.channelCount = 2
            // Audio-only, but SCStream still needs a valid (tiny) video size.
            config.width = 2
            config.height = 2
            config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

            // LPCM-in-CAF: crash-safe (readable even if we never finalize) — this
            // side of a call must survive a kill just like the mic side does.
            let writer = try AVAssetWriter(outputURL: url, fileType: .caf)
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ])
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else {
                Log.write("sysaudio: writer can't add audio input; skipping")
                return false
            }
            writer.add(input)

            let stream = SCStream(filter: filter, configuration: config, delegate: self)
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
            try await stream.startCapture()

            lock.lock()
            self.writer = writer; self.input = input; self.stream = stream
            self.outputURL = url; self.startedSession = false; self.wroteAnySamples = false
            self.firstSampleAt = nil
            lock.unlock()

            Log.write("sysaudio: capturing system audio (other participants) → \(url.lastPathComponent)")
            return true
        } catch {
            Log.write("sysaudio: ⚠️ could not start (\(error.localizedDescription)). Likely Screen Recording not granted — recording mic only. Grant it in System Settings ▸ Privacy & Security ▸ Screen Recording.")
            return false
        }
    }

    /// Stops capture and finalizes the file. Returns the URL only if real samples
    /// were written.
    func stop() async -> URL? {
        lock.lock()
        let stream = self.stream
        let writer = self.writer
        let input = self.input
        let url = self.outputURL
        let wrote = self.wroteAnySamples
        lock.unlock()

        if let stream { try? await stream.stopCapture() }
        input?.markAsFinished()
        if let writer, writer.status == .writing {
            await writer.finishWriting()
        }

        lock.lock(); self.stream = nil; self.writer = nil; self.input = nil; lock.unlock()

        guard wrote, let url else {
            Log.write("sysaudio: no system-audio samples captured")
            return nil
        }
        Log.write("sysaudio: finalized \(url.lastPathComponent)")
        return url
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, CMSampleBufferDataIsReady(sampleBuffer) else { return }
        lock.lock()
        guard let writer, let input else { lock.unlock(); return }
        if !startedSession {
            if writer.status == .unknown {
                writer.startWriting()
                writer.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
            }
            startedSession = true
        }
        let ready = input.isReadyForMoreMediaData && writer.status == .writing
        lock.unlock()

        if ready {
            input.append(sampleBuffer)
            let level = Self.signalLevel(sampleBuffer)
            lock.lock()
            if !wroteAnySamples { firstSampleAt = Date() }
            wroteAnySamples = true
            levelValue = level
            levelAt = Date()
            if level > 0.01 { lastAudibleAt = Date() }
            lock.unlock()
            onSampleBuffer?(sampleBuffer)
        }
    }

    /// Cheap peak probe (0…1) on the incoming buffer (SCStream delivers PCM):
    /// sparse-scans samples for the loudest one. Handles the float and int16
    /// layouts CoreMedia may hand us; unknown formats read as silent.
    static func signalLevel(_ sampleBuffer: CMSampleBuffer) -> Float {
        guard let block = CMSampleBufferGetDataBuffer(sampleBuffer),
              let desc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc)?.pointee
        else { return 0 }
        var length = 0
        var raw: UnsafeMutablePointer<CChar>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil,
                                          totalLengthOut: &length, dataPointerOut: &raw) == kCMBlockBufferNoErr,
              let raw, length > 4 else { return 0 }

        let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        if isFloat, asbd.mBitsPerChannel == 32 {
            let count = length / 4
            return raw.withMemoryRebound(to: Float32.self, capacity: count) { samples in
                var peak: Float = 0
                for i in stride(from: 0, to: count, by: 16) { peak = max(peak, abs(samples[i])) }
                return min(1, peak)
            }
        }
        if !isFloat, asbd.mBitsPerChannel == 16 {
            let count = length / 2
            return raw.withMemoryRebound(to: Int16.self, capacity: count) { samples in
                var peak: Int = 0
                for i in stride(from: 0, to: count, by: 16) { peak = max(peak, abs(Int(samples[i]))) }
                return min(1, Float(peak) / 32_768)
            }
        }
        return 0
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Log.write("sysaudio: stream stopped with error: \(error.localizedDescription)")
    }
}
