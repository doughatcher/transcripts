import Foundation
import ServiceManagement
import TranscriptsEngine

/// Thin wrapper over `SMAppService.mainApp` to run Transcripts at login. No helper tool
/// or entitlement needed — the OS registers the main app bundle as a login item.
enum LoginItem {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Enables/disables launch at login. Returns true on success.
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                }
            }
            Log.write("login item: \(enabled ? "enabled" : "disabled")")
            return true
        } catch {
            Log.write("login item: failed to \(enabled ? "enable" : "disable") — \(error.localizedDescription)")
            return false
        }
    }
}
