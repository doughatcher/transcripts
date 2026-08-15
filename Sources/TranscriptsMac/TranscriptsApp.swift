import SwiftUI

@main
struct TranscriptsApp: App {
    // The menu bar is a real NSStatusItem owned by the delegate (see StatusBarController)
    // so the icon can pulse with the live input level — SwiftUI's MenuBarExtra can't.
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    /// Probe invocations (TRANSCRIPTS_SELFCHECK, TRANSCRIPTS_DIARIZE) run headless and
    /// exit. They must NEVER boot the full controller — it recovers interrupted
    /// recordings and auto-records active calls, so a probe binary running next
    /// to the real instance hijacks in-flight captures and double-records live
    /// meetings (2026-07-13). Checked via the environment directly so nothing
    /// on this path touches the AppController singleton.
    private static let isProbe =
        ProcessInfo.processInfo.environment["TRANSCRIPTS_SELFCHECK"] != nil
        || ProcessInfo.processInfo.environment["TRANSCRIPTS_DIARIZE"] != nil
        || ProcessInfo.processInfo.environment["TRANSCRIPTS_MLX"] != nil

    var body: some Scene {
        // The only SwiftUI scene. The dropdown and the Recordings window are AppKit-
        // hosted by StatusBarController; keeping Settings here means the standard
        // `showSettingsWindow:` selector opens it (and satisfies App's need for a scene).
        Settings {
            if !Self.isProbe {
                SettingsView()
                    .environmentObject(AppController.shared)
            }
        }
    }
}
