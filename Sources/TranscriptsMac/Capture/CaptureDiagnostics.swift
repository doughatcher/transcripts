import Foundation
import TranscriptsCore
import TranscriptsEngine

/// Append-only, per-capture evidence. Survives a crash and follows the capture's
/// existing retention policy. No audio, window titles, or transcript text.
/// Encoding and disk IO never run on the audio callback.
final class CaptureDiagnostics: @unchecked Sendable {
    private let queue = DispatchQueue(label: "ltd.hatcher.transcripts.capture-diagnostics", qos: .utility)
    private let url: URL
    private var failed = false

    init(directory: URL) {
        url = directory.appendingPathComponent("capture-diagnostics.jsonl")
        event("capture-open", [
            "schemaVersion": 1,
            "captureID": directory.lastPathComponent,
            "app": Bundle.main.bundleIdentifier ?? "unknown",
            "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "processID": ProcessInfo.processInfo.processIdentifier,
        ])
    }

    func event(_ name: String, _ fields: [String: Any] = [:]) {
        // Freeze mutable caller-owned dictionaries before crossing queues.
        let envelope: [String: Any] = ["event": name, "at": Date().timeIntervalSince1970, "data": fields]
        guard JSONSerialization.isValidJSONObject(envelope),
              var data = try? JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys]) else { return }
        data.append(0x0a)
        let line = data
        queue.async { [self] in
            do {
                if !FileManager.default.fileExists(atPath: url.path) {
                    guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
                        throw CocoaError(.fileWriteUnknown)
                    }
                }
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: line)
            } catch {
                if !failed { Log.write("capture diagnostics: could not write \(url.path): \(error)"); failed = true }
            }
        }
    }

    func metrics(_ name: String, _ metrics: AudioCaptureMetrics, extra: [String: Any] = [:]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(metrics),
              var fields = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        fields.merge(extra) { _, new in new }
        event(name, fields)
    }

    /// For the hardware self-check before it removes its scratch directory.
    /// Never call from an audio callback.
    func flush() -> URL {
        queue.sync {}
        return url
    }

    /// Timer/main-thread snapshots, and explicit start/stop snapshots. Query the
    /// actual AudioUnit device as selection can fail or reset on reconfiguration.
    func route(_ name: String, actualInputID: UInt32?, requestedInputID: UInt32) {
        var fields = AudioInputDevices.diagnosticRoute(actualInputID: actualInputID,
                                                      requestedInputID: requestedInputID)
        fields["meetingDeviceUIDs"] = CallDetector.meetingAppDeviceUIDs()
        fields["meetingApp"] = CallDetector.meetingAppUsingInput() ?? "none"
        event(name, fields)
    }
}
