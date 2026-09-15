import Foundation
import AVFoundation
import CoreMedia
import Speech
import TranscriptsCore

/// On-device transcription using the macOS 26 `SpeechAnalyzer` / `SpeechTranscriber`
/// stack. Fully local (Apple Neural Engine), no daemon, no third-party model
/// download — the transcription assets are OS-managed and shared between apps.
///
/// This implements the post-meeting (batch) path: it reads a finished audio file
/// end to end and returns the finalized transcript. The same `SpeechTranscriber`
/// module also supports live `progressiveTranscription`; layering that on is a
/// follow-up that feeds the recorder's buffers into an input stream instead of a
/// file.
@available(macOS 26, iOS 26, *)
public struct SpeechTranscriberEngine: Transcriber {
    public init() {}

    public enum EngineError: Error, CustomStringConvertible {
        case noSupportedLocale
        case assetsUnavailable
        case resultsNeverFinished(seconds: TimeInterval)

        public var description: String {
            switch self {
            case .noSupportedLocale: return "No on-device transcription locale is available."
            case .assetsUnavailable: return "Transcription models could not be installed."
            case .resultsNeverFinished(let s):
                return "Transcription results did not finish within \(Int(s))s."
            }
        }
    }

    /// The `model` argument is ignored here — the OS selects the on-device model for
    /// the locale. It's kept for protocol compatibility with engines that name a model.
    public func transcribe(audioURL: URL, model: String) async throws -> String {
        let text = try await transcribeSegments(audioURL: audioURL, model: model)
            .map(\.text)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "[no speech detected]" : text
    }

    /// Timestamped variant: each finalized result carries the audio time range it
    /// covers, which is what speaker attribution interleaves on.
    public func transcribeSegments(audioURL: URL, model: String) async throws -> [TranscriptSegment] {
        // 1. Pick an on-device locale equivalent to the user's current one.
        let preferred = Locale.current
        let locale: Locale
        if let match = await SpeechTranscriber.supportedLocale(equivalentTo: preferred) {
            locale = match
        } else if let fallback = await SpeechTranscriber.supportedLocales.first {
            locale = fallback
        } else {
            throw EngineError.noSupportedLocale
        }

        // 2. Batch transcriber: finalized results only (no volatile/partial output).
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: []
        )

        // 3. Ensure the model assets are installed. Returns nil when already present;
        //    the first run downloads from Apple's servers (a few hundred MB, cached
        //    and shared system-wide thereafter).
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }

        // 4. Analyzer over the single transcriber module.
        let analyzer = SpeechAnalyzer(modules: [transcriber], options: nil)

        // 5. Start consuming finalized results before feeding audio.
        let collector = Task { () throws -> [TranscriptSegment] in
            var segments: [TranscriptSegment] = []
            for try await result in transcriber.results {
                let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                let range = result.range
                segments.append(TranscriptSegment(
                    start: range.start.seconds,
                    end: range.end.seconds,
                    text: text))
            }
            return segments
        }

        // 6. Feed the recorded file; the analyzer converts format as needed.
        let audioFile = try AVAudioFile(forReading: audioURL)

        // A file with no frames has nothing to finalize: analyzeSequence returns
        // nil, and cancelAndFinishNow() does not reliably terminate
        // `transcriber.results` — so the collector below would iterate a sequence
        // that never ends and `collector.value` would never return. That is not a
        // slow transcript, it is a task parked forever with no thread and no CPU,
        // which is also why the stage timeout wrapped around this could never fire:
        // a suspended task cannot be cancelled from outside. Recordings sat in
        // `processing` for a week that way, and every relaunch queued them again.
        guard audioFile.length > 0 else {
            collector.cancel()
            try? await analyzer.cancelAndFinishNow()
            return []
        }

        if let lastSample = try await analyzer.analyzeSequence(from: audioFile) {
            try await analyzer.finalizeAndFinish(through: lastSample)
        } else {
            try await analyzer.cancelAndFinishNow()
        }

        // Belt and braces for every other way that sequence could fail to end.
        // Cancelling the collector directly is the only lever that reaches it, so
        // the deadline is an unstructured task rather than a task group — a group
        // would itself wait on the child it is trying to give up on.
        let seconds = max(600, (Double(audioFile.length) / audioFile.fileFormat.sampleRate) * 4)
        let deadline = Task {
            try await Task.sleep(for: .seconds(seconds))
            collector.cancel()
        }
        defer { deadline.cancel() }
        do {
            return try await collector.value
        } catch is CancellationError {
            throw EngineError.resultsNeverFinished(seconds: seconds)
        }
    }
}
