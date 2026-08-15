import Foundation
import AppKit
import TranscriptsCore

/// Captures which app is frontmost right now, for recording metadata.
enum ActiveAppProvider {
    static func current() -> ActiveAppContext {
        let app = NSWorkspace.shared.frontmostApplication
        return ActiveAppContext(
            appName: app?.localizedName,
            bundleID: app?.bundleIdentifier,
            capturedAt: Date()
        )
    }
}
