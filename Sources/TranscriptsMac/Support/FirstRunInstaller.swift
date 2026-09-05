import AppKit
import TranscriptsEngine   // Log

/// Offers, on first launch from somewhere else, to move Transcripts into
/// `~/Applications` and reopen from there.
///
/// Handing someone a zip assumes they know an app belongs in an Applications
/// folder, that `~/Applications` is the one that works without an
/// administrator, and that it may not exist yet. That is three pieces of Mac
/// lore standing between a colleague and a working app, and it is exactly where
/// people get stuck. The app can do it itself, so it offers to.
///
/// Gatekeeper path randomization is the one complication, and it only affects
/// cleanup. An app opened straight out of Downloads while still quarantined runs
/// from a read-only translocated mount, so its own bundle URL is not where the
/// user thinks the app is. Copying *out* of that mount works, which is all we
/// need; finding the original to delete does not, so we leave the download
/// alone rather than guess.
@MainActor
enum FirstRunInstaller {

    /// Set once the user says no, so this is an offer and not a nag.
    private static let declinedKey = "declinedInstallToApplications"

    static func offerIfNeeded() {
        // The screenshot harness runs a second copy straight out of .build, which
        // is exactly the situation this offer exists for — and a modal grabbing
        // focus is the one thing a headless capture cannot answer. Any run that
        // asked for a window on launch is a screenshot run, not a first run.
        guard ProcessInfo.processInfo.environment["TRANSCRIPTS_SHOW"] == nil else { return }
        guard !UserDefaults.standard.bool(forKey: declinedKey) else { return }
        let current = Bundle.main.bundleURL
        guard !isInAnApplicationsFolder(current) else { return }

        let apps = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications")
        let destination = apps.appendingPathComponent(current.lastPathComponent)
        let replacing = FileManager.default.fileExists(atPath: destination.path)

        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Move Transcripts to your Applications folder?"
        alert.informativeText = replacing
            ? """
              A copy of Transcripts is already in your personal Applications folder. Replace it with this one and reopen from there?

              Keeping it in one place is what lets macOS remember the permissions you grant it.
              """
            : """
              Transcripts will copy itself to ~/Applications — your personal Applications folder, which needs no administrator — and reopen from there.

              This is worth doing: an app run from your Downloads folder loses the permissions you grant it as soon as the folder is cleaned up.
              """
        alert.addButton(withTitle: replacing ? "Replace and Reopen" : "Move and Reopen")
        alert.addButton(withTitle: "Not Now")
        guard alert.runModal() == .alertFirstButtonReturn else {
            UserDefaults.standard.set(true, forKey: declinedKey)
            Log.write("install: offered to move into ~/Applications; user declined")
            return
        }

        do {
            try FileManager.default.createDirectory(at: apps, withIntermediateDirectories: true)
            if replacing {
                // Ask the copy being replaced to quit first. Removing a running
                // bundle succeeds on macOS — the process keeps its inode — so
                // without this the old build stays running, the new one starts
                // beside it, and the user has two menu-bar icons and no way to
                // tell which is which. terminate() is the polite quit the app
                // already handles, so anything mid-flight is finalised.
                let identifier = Bundle.main.bundleIdentifier ?? "ltd.hatcher.transcripts"
                for other in NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
                where other != .current {
                    other.terminate()
                }
                try? FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: current, to: destination)
        } catch {
            Log.write("install: could not copy into ~/Applications — \(error.localizedDescription)")
            let failure = NSAlert()
            failure.messageText = "Couldn't move Transcripts"
            failure.informativeText = "\(error.localizedDescription)\n\nDrag Transcripts.app into your Applications folder by hand and open it from there."
            failure.runModal()
            return
        }

        Log.write("install: copied into \(destination.path); reopening from there")
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        // -n, because the copy has the same bundle identifier as the process
        // making this call: without it LaunchServices decides Transcripts is
        // already running and simply activates *this* copy, leaving the user
        // exactly where they started.
        open.arguments = ["-n", destination.path]
        try? open.run()
        NSApp.terminate(nil)
    }

    /// True when the bundle already lives in either Applications folder. A
    /// translocated bundle never does — the mount is under /private/var — which
    /// is what makes a freshly-downloaded copy recognisable without having to
    /// ask Gatekeeper about it.
    private static func isInAnApplicationsFolder(_ url: URL) -> Bool {
        let parent = url.deletingLastPathComponent().standardizedFileURL.path
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return parent == "/Applications" || parent == "\(home)/Applications"
    }
}
