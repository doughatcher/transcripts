import Foundation

/// Dead-simple file logger. A bundled menu-bar app has no console, so we append
/// timestamped lines to `~/Library/Logs/Transcripts.log` for diagnosis. Tail it with:
///   tail -f ~/Library/Logs/Transcripts.log
public enum Log {
    public static let fileURL: URL = {
        let logs = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        return logs.appendingPathComponent("Transcripts.log")
    }()

    private static let queue = DispatchQueue(label: "ltd.hatcher.transcripts.log")
    private static let iso = ISO8601DateFormatter()

    public static func write(_ message: String) {
        let line = "\(iso.string(from: Date()))  \(message)\n"
        queue.async {
            if let data = line.data(using: .utf8) {
                if let handle = try? FileHandle(forWritingTo: fileURL) {
                    defer { try? handle.close() }
                    _ = try? handle.seekToEnd()
                    try? handle.write(contentsOf: data)
                } else {
                    try? data.write(to: fileURL)
                }
            }
        }
        #if DEBUG
        print("[transcripts] \(message)")
        #endif
    }
}
