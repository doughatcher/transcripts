import Foundation
import AVFoundation
import CoreMedia
import Speech
import TranscriptsCore

/// Progressive (streaming) transcription of one audio track using the same
/// on-device `SpeechAnalyzer` stack the batch path uses — but fed live buffers
/// instead of a finished file, so finalized segments arrive seconds behind
/// speech. One instance per track (mic, system audio); the caller labels the
/// results and folds them into the live transcript.
///
/// Every entry point is failure-isolated: a live-transcription problem logs and
/// goes quiet rather than disturbing the recording it observes.
@available(macOS 26, iOS 26, *)
public final class LiveTrackTranscriber: @unchecked Sendable {
    private let onSegment: @Sendable (TranscriptSegment) -> Void
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var analyzer: SpeechAnalyzer?
    private var collector: Task<Void, Never>?
    private var converter: AVAudioConverter?
    private var analyzerFormat: AVAudioFormat?
    private let queue = DispatchQueue(label: "ltd.hatcher.transcripts.livetranscribe")

    public init(onSegment: @escaping @Sendable (TranscriptSegment) -> Void) {
        self.onSegment = onSegment
    }

    /// Sets up the analyzer. Returns false (and stays inert) when live
    /// transcription can't run — the batch pass at the end of the recording is
    /// unaffected. The input converter is built lazily from the first buffer's
    /// actual format (the system-audio format isn't knowable up front).
    public func start() async -> Bool {
        do {
            var locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current)
            if locale == nil { locale = await SpeechTranscriber.supportedLocales.first }
            guard let locale else { return false }
            let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [],
                                                reportingOptions: [], attributeOptions: [])
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await request.downloadAndInstall()
            }
            guard let best = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
                return false
            }
            analyzerFormat = best

            let (stream, cont) = AsyncStream.makeStream(of: AnalyzerInput.self)
            continuation = cont
            let analyzer = SpeechAnalyzer(modules: [transcriber], options: nil)
            self.analyzer = analyzer

            let handle = onSegment
            collector = Task {
                do {
                    for try await result in transcriber.results {
                        let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !text.isEmpty else { continue }
                        handle(TranscriptSegment(start: result.range.start.seconds,
                                                 end: result.range.end.seconds,
                                                 text: text))
                    }
                } catch {
                    Log.write("live: result stream ended (\(error))")
                }
            }
            try await analyzer.start(inputSequence: stream)
            return true
        } catch {
            Log.write("live: could not start (\(error)) — recording continues without live transcript")
            teardown()
            return false
        }
    }

    /// Feeds one buffer from the capture path. Cheap and non-blocking for the
    /// audio thread: conversion + yield happen on a serial background queue.
    public func feed(_ buffer: AVAudioPCMBuffer) {
        queue.async { [weak self] in
            guard let self, let continuation = self.continuation,
                  let format = self.analyzerFormat else { return }
            if self.converter == nil || self.converter?.inputFormat != buffer.format {
                self.converter = AVAudioConverter(from: buffer.format, to: format)
            }
            guard let converter = self.converter else { return }
            let ratio = format.sampleRate / buffer.format.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
            guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return }
            var fed = false
            var error: NSError?
            converter.convert(to: out, error: &error) { _, status in
                if fed { status.pointee = .noDataNow; return nil }
                fed = true
                status.pointee = .haveData
                return buffer
            }
            guard error == nil, out.frameLength > 0 else { return }
            continuation.yield(AnalyzerInput(buffer: out))
        }
    }

    /// Ends the input and finalizes any pending segments.
    public func finish() async {
        continuation?.finish()
        if let analyzer {
            try? await analyzer.finalizeAndFinishThroughEndOfInput()
        }
        await collector?.value
        teardown()
    }

    private func teardown() {
        continuation = nil
        analyzer = nil
        collector = nil
        converter = nil
        analyzerFormat = nil
    }
}

/// Converts a CoreMedia sample buffer (ScreenCaptureKit's currency) to the
/// AVAudioPCMBuffer the live transcriber eats. Returns nil for non-PCM or
/// malformed buffers.
public func pcmBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
    guard let desc = CMSampleBufferGetFormatDescription(sampleBuffer),
          let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc),
          let format = AVAudioFormat(streamDescription: asbd) else { return nil }
    let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
    guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
    buffer.frameLength = frames
    let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
        sampleBuffer, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList)
    return status == noErr ? buffer : nil
}
