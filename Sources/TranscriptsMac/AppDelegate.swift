import AppKit

/// Sets up the menu-bar status item once AppKit is ready. Transcripts is a pure menu-bar
/// utility (`.accessory`) — no Dock icon — and stays alive after its windows close.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBar: StatusBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Doc-screenshot mode: render Settings tabs to PNGs and quit before any
        // menu-bar / recording machinery starts. See DocCapture.
        if DocCapture.isRequested {
            DocCapture.runAndExit()
            return
        }
        // Hardware smoke test: verify both audio flows and quit. See SelfCheck.
        if SelfCheck.isRequested {
            SelfCheck.runAndExit()
            return
        }
        // Attribution smoke test: diarize an existing file and quit. See DiarizeCheck.
        if let path = DiarizeCheck.requestedPath {
            DiarizeCheck.runAndExit(path: path)
            return
        }
        // Summarizer smoke test: load the MLX model and quit. See MLXCheck.
        if MLXCheck.isRequested {
            MLXCheck.runAndExit()
            return
        }
        NSApp.setActivationPolicy(.accessory)
        statusBar = StatusBarController(controller: .shared)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
