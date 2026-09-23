import AppKit
import TranscriptsEngine

/// Sets up the menu-bar status item once AppKit is ready. Transcripts is a pure menu-bar
/// utility (`.accessory`) — no Dock icon — and stays alive after its windows close.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBar: StatusBarController?
    /// Retained for the lifetime of the app — a cancelled source stops firing.
    private var sigtermSource: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Before anything reads the library, inbox or vault: sandboxed, those
        // folders open only through the bookmarks the user granted last time.
        FolderAccess.restoreAll()
        // Doc-screenshot mode: render Settings tabs to PNGs and quit before any
        // menu-bar / recording machinery starts. See DocCapture.
        if DocCapture.isRequested {
            DocCapture.runAndExit()
            return
        }
        // Print the end of this app's log and quit. The store edition's log is
        // inside its sandbox container, which macOS keeps even a Terminal from
        // reading; the app itself always can.
        //   TRANSCRIPTS_PRINT_LOG=200 open -W --stdout /tmp/log.txt Transcripts.app
        if let raw = ProcessInfo.processInfo.environment["TRANSCRIPTS_PRINT_LOG"] {
            let lines = (try? String(contentsOf: Log.fileURL, encoding: .utf8))?
                .split(separator: "\n", omittingEmptySubsequences: false) ?? []
            print("\(Log.fileURL.path)")
            print(lines.suffix(Int(raw) ?? 200).joined(separator: "\n"))
            exit(0)
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
        // Live-attribution replay: run a file through the live path and quit.
        // See LiveDiarizeCheck.
        if let path = LiveDiarizeCheck.requestedPath {
            LiveDiarizeCheck.runAndExit(path: path)
            return
        }
        // Icon contact sheet: render every menu-bar icon and quit. See IconCheck.
        if let path = IconCheck.requestedPath {
            IconCheck.runAndExit(path: path)
            return
        }
        // Summarizer smoke test: load the MLX model and quit. See MLXCheck.
        if MLXCheck.isRequested {
            MLXCheck.runAndExit()
            return
        }
        // Before anything takes hold: a copy opened from Downloads should become
        // an installed copy, because permissions are granted to a path and a
        // recording is worth more than the folder it was launched from. Runs
        // ahead of the status item so a user who accepts never sees this
        // process finish starting — it relaunches from the new location.
        // The App Store installs and updates the store build itself.
        if !StoreEdition.isStore { FirstRunInstaller.offerIfNeeded() }
        // Store build: a fresh sandbox can open no folder, so settle where the
        // library lives. The controller already exists — SwiftUI made it for
        // the Settings scene — so it has to be told to take the new config.
        if StoreEdition.prepareLibrary() { AppController.shared.reloadConfig() }

        NSApp.setActivationPolicy(.accessory)
        statusBar = StatusBarController(controller: .shared)
        installTerminationHandler()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Quitting with a recording live carries it forward instead of abandoning
    /// it, so relaunching resumes the meeting. See `prepareForRelaunch`.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        AppController.shared.prepareForRelaunch {
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// The same path for `SIGTERM`, which is what a rebuild script sends.
    ///
    /// AppKit does not route signals through `applicationShouldTerminate`, so
    /// without this a `pkill` would skip every bit of the graceful path. The
    /// default disposition is suppressed so only this handler runs.
    private func installTerminationHandler() {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler {
            MainActor.assumeIsolated {
                AppController.shared.prepareForRelaunch { exit(0) }
            }
        }
        source.resume()
        sigtermSource = source
    }
}
