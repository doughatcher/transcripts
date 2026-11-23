import Foundation

/// Explicitly selected technical fields for sharing. Raw capture sidecars stay
/// local: they contain routes, UIDs and paths useful for private investigation.
public enum SupportDiagnostics {
    private static let keys: Set<String> = [
        "schemaVersion", "app", "version", "build", "os", "receivedBuffers", "writtenBuffers", "droppedBuffers",
        "writeFailures", "framesWritten", "writtenSeconds", "firstCaptureSeconds", "lastCaptureSeconds",
        "firstArrivalAt", "lastArrivalAt", "discontinuities", "largestGapSeconds", "clock", "sampleRate", "channels",
        "fileSampleRate", "hardwareSampleRate", "voiceProcessingEnabled", "writerStatus", "formatFlags", "bitsPerChannel",
        "peak", "latestPeak", "systemCallbackStartOffsetSeconds", "micPlacementSeconds", "systemPlacementSeconds",
        "transcriptionSystemOffsetSeconds", "assembledFragments", "isRecovery", "continuing", "inMeeting", "systemAudioEnabled"
    ]

    private static func kind(_ name: String) -> String {
        let value = name.lowercased()
        if value.contains("iphone") { return "continuity-iphone" }
        if value.contains("airpod") || value.contains("bluetooth") { return "bluetooth" }
        if value.contains("built-in") || value.contains("macbook") { return "built-in" }
        if value.contains("usb") || value.contains("brio") || value.contains("c920") { return "usb" }
        return "other"
    }

    public static func summary(jsonLines: Data) throws -> Data {
        let text = String(decoding: jsonLines, as: UTF8.self)
        // Keep the beginning (capture setup) and tail (recent changes and stop).
        let lines = text.split(separator: "\n")
        let selected = lines.count > 100 ? Array(lines.prefix(10)) + Array(lines.suffix(90)) : Array(lines)
        let events: [[String: Any]] = selected.compactMap { line in
            guard let event = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let name = event["event"] as? String,
                  let input = event["data"] as? [String: Any] else { return nil }
            var safe = input.filter { key, value in
                keys.contains(key) && (value is NSNumber || ((value as? String)?.count ?? Int.max) <= 160)
            }
            if let requested = input["requestedName"] as? String { safe["selectedInputKind"] = kind(requested) }
            if let devices = input["devices"] as? [[String: Any]] {
                for (idKey, target) in [("actualInputID", "selectedInputKind"), ("defaultOutputID", "defaultOutputKind")] {
                    if let id = input[idKey] as? NSNumber,
                       let device = devices.first(where: { ($0["id"] as? NSNumber) == id }),
                       let deviceName = device["name"] as? String { safe[target] = kind(deviceName) }
                }
            }
            return ["event": String(name.prefix(64)), "data": safe]
        }
        return try JSONSerialization.data(withJSONObject: events, options: [.prettyPrinted, .sortedKeys])
    }
}
