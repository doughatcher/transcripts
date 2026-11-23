import AppKit
import UniformTypeIdentifiers
import TranscriptsCore
import TranscriptsEngine

@MainActor
enum SupportReporter {
    static func report() {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        if let base = Bundle.main.object(forInfoDictionaryKey: "SupportReportURL") as? String,
           let url = URL(string: base)?.appendingPathComponent(version) {
            NSWorkspace.shared.open(url)
        } else {
            var url = URLComponents(string: "https://github.com/doughatcher/transcripts-support/issues/new")!
            url.queryItems = [URLQueryItem(name: "body", value: "App version: \(version)\nmacOS: \(ProcessInfo.processInfo.operatingSystemVersionString)\n\nWhat happened?\n\nWhat did you expect?\n")]
            if let url = url.url { NSWorkspace.shared.open(url) }
        }
    }

    static func saveDiagnostics() {
        let fm = FileManager.default
        let entries = (try? fm.contentsOfDirectory(at: HistoryStore.capturesDir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let candidates = entries.map { $0.appendingPathComponent("capture-diagnostics.jsonl") }
            .filter { fm.fileExists(atPath: $0.path) }
            .sorted { ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
                > ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
        guard let source = candidates.first else {
            show("No diagnostic summary yet", "Record a session with this version first. No audio or transcript is needed in the report.")
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "transcripts-diagnostic-summary.json"
        panel.message = "Save technical counters from the most recent capture. Audio, transcripts, paths and device identifiers are excluded."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try SupportDiagnostics.summary(jsonLines: Data(contentsOf: source))
            try data.write(to: url, options: .atomic)
            show("Diagnostic summary saved", "You can attach this JSON file on the Report a Problem page. Nothing has been uploaded.")
        } catch {
            show("Couldn't save diagnostics", error.localizedDescription)
        }
    }

    private static func show(_ title: String, _ message: String) {
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = message; alert.runModal()
    }
}
