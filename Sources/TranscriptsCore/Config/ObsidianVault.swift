import Foundation

/// Finding the user's Obsidian vault, so an Obsidian user does not have to
/// describe their own setup to an app that could have looked.
///
/// Obsidian keeps a registry of every vault it has opened, with the timestamp
/// of the last open. That file is the only reliable way to find a vault: the
/// folder can be anywhere, is often not called "vault", and on this kind of
/// setup is synced by Obsidian Sync rather than living in iCloud — so no path
/// convention would find it.
public enum ObsidianVault {
    /// Obsidian's own registry of known vaults (macOS).
    static var registryURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/obsidian/obsidian.json")
    }

    /// Every registered vault that still exists on disk, most recently opened
    /// first. Empty when Obsidian isn't installed — including on iOS, where the
    /// registry path simply isn't there and the caller gets "no vaults" rather
    /// than a special case.
    public static func known() -> [URL] {
        guard let data = try? Data(contentsOf: registryURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let vaults = root["vaults"] as? [String: [String: Any]]
        else { return [] }

        return vaults.values
            .compactMap { entry -> (URL, Double)? in
                guard let path = entry["path"] as? String else { return nil }
                let url = URL(fileURLWithPath: path)
                // A vault Obsidian remembers but that has since moved or been
                // deleted is worse than none: filing into it would recreate the
                // folder somewhere the user no longer looks.
                guard isVault(url) else { return nil }
                return (url, (entry["ts"] as? Double) ?? 0)
            }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }

    /// The vault to file into when nobody has said otherwise: the one most
    /// recently opened. With several vaults that is the one being lived in, and
    /// it is a Settings row away from being any of the others.
    public static func mostRecentlyOpened() -> URL? { known().first }

    /// A directory is a vault if it carries Obsidian's `.obsidian` folder.
    public static func isVault(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        let marker = url.appendingPathComponent(".obsidian").path
        return FileManager.default.fileExists(atPath: marker, isDirectory: &isDir) && isDir.boolValue
    }

    /// Walks up from `path` to the vault root containing it, or nil if it sits
    /// outside every vault.
    public static func root(containing path: String) -> URL? {
        var dir = URL(fileURLWithPath: path).standardizedFileURL.deletingLastPathComponent()
        while dir.path != "/" {
            if isVault(dir) { return dir }
            let parent = dir.deletingLastPathComponent()
            if parent == dir { break }
            dir = parent
        }
        return nil
    }
}
