import Foundation
import TranscriptsEngine   // Log

/// Remembers the folders the user has picked, so a sandboxed build can reopen
/// them after a relaunch.
///
/// Unsandboxed, a path in the config is enough: the app opens it. Sandboxed,
/// a path opens nothing — the only folders the app can reach are ones the user
/// chose in an open panel, and that grant dies with the process unless it is
/// kept as a security-scoped bookmark. This is the Mac half of what
/// `Destination` already does on iOS.
///
/// Bookmarks are keyed by the folder's real path, so the config keeps storing
/// plain paths and nothing that reads them has to know whether the app is
/// sandboxed. Every grant is opened at launch and held for the life of the
/// process — the library, the inbox and the vault are all touched constantly,
/// and scoping each access would thread `start/stop` through code that has
/// never had to think about it.
enum FolderAccess {

    /// True inside App Sandbox. Unsandboxed builds skip all of this.
    static var isSandboxed: Bool {
        ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
    }

    private static let defaultsKey = "folderBookmarks"
    private static var open: [String: URL] = [:]
    private static let lock = NSLock()
    /// restoreAll runs from the controller's init, which SwiftUI reaches before
    /// the app delegate does; once is enough.
    private static var restored = false

    /// Records access to a folder the user just picked in an open panel. The
    /// panel's grant already covers this process; the bookmark carries it into
    /// the next one.
    static func grant(_ url: URL) {
        guard isSandboxed else { return }
        do {
            let data = try url.bookmarkData(options: .withSecurityScope,
                                            includingResourceValuesForKeys: nil,
                                            relativeTo: nil)
            var all = stored()
            all[url.standardizedFileURL.path] = data
            UserDefaults.standard.set(all, forKey: defaultsKey)
            hold(url)
            Log.write("access: remembered \(url.path)")
        } catch {
            Log.write("access: could not bookmark \(url.path) — \(error)")
        }
    }

    /// Reopens every remembered folder. Must run before anything reads the
    /// library, inbox or vault — so from the top of AppController.init, since
    /// SwiftUI builds the Settings scene, and with it the controller, before
    /// applicationDidFinishLaunching. Safe to call again.
    static func restoreAll() {
        guard isSandboxed, !restored else { return }
        restored = true
        var all = stored()
        for (path, data) in all {
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope,
                                     relativeTo: nil, bookmarkDataIsStale: &stale) else {
                Log.write("access: bookmark for \(path) no longer resolves — pick the folder again")
                all[path] = nil
                continue
            }
            hold(url)
            if stale, let fresh = try? url.bookmarkData(options: .withSecurityScope,
                                                        includingResourceValuesForKeys: nil,
                                                        relativeTo: nil) {
                all[path] = fresh
            }
        }
        UserDefaults.standard.set(all, forKey: defaultsKey)
        Log.write("access: reopened \(open.count) folder(s)")
    }

    /// Whether `path` (or a folder containing it) is reachable. Always true
    /// unsandboxed.
    static func canReach(_ path: String) -> Bool {
        guard isSandboxed else { return true }
        let target = URL(fileURLWithPath: path).standardizedFileURL.path
        lock.lock(); defer { lock.unlock() }
        return open.keys.contains { target == $0 || target.hasPrefix($0 + "/") }
    }

    private static func hold(_ url: URL) {
        let key = url.standardizedFileURL.path
        lock.lock(); defer { lock.unlock() }
        guard open[key] == nil else { return }
        if url.startAccessingSecurityScopedResource() { open[key] = url }
    }

    private static func stored() -> [String: Data] {
        UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: Data] ?? [:]
    }
}
