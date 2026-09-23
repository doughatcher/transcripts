import Foundation

/// Picks sensible first-run folders.
///
/// The common case is a personal Mac signed into iCloud alongside a personal
/// iPhone and iPad, where iCloud Drive is the one place every device can already
/// see without setup, auth, or a third-party account. So that's the default when
/// it's actually there, and `~/Documents` when it isn't — a managed Mac with
/// iCloud Drive restricted, or an account that never signed in.
///
/// This is a *capability* check, not a guess about the machine. Whether a Mac is
/// MDM-enrolled says nothing reliable about whether this folder is writable, and
/// testing the thing you actually depend on can't be wrong the way a heuristic
/// can. Nothing here migrates an existing install: `ConfigStore` only consults
/// these when no config file exists yet, so a configured root is never moved.
public enum Locations {
    public static let folderName = "Transcripts"

    /// The user's real home directory. Not `NSHomeDirectory()` on the Mac: inside
    /// App Sandbox that is the app's container, so `~/Library/Mobile Documents`
    /// would resolve to a folder that does not exist and a configured path would
    /// quietly point somewhere else. The password database is not redirected.
    /// On iOS the home directory is the app sandbox and that is what is meant.
    public static var userHome: String {
        #if os(macOS)
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            return String(cString: dir)
        }
        #endif
        return NSHomeDirectory()
    }

    /// Expands a leading `~` against `userHome`.
    public static func expand(_ path: String) -> String {
        if path == "~" { return userHome }
        if path.hasPrefix("~/") { return userHome + path.dropFirst(1) }
        return path
    }

    /// iCloud Drive's document root, when the user has it.
    ///
    /// `NSHomeDirectory()` rather than `homeDirectoryForCurrentUser`, which is
    /// unavailable on iOS — this type compiles into the shared core, and the
    /// mobile recorder links the same module even though only the Mac consults
    /// these paths (on iOS the home directory is an app sandbox, where none of
    /// this would mean anything).
    public static func iCloudDrive(fileManager: FileManager = .default) -> URL? {
        let url = URL(fileURLWithPath: userHome)
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            return nil
        }
        return url
    }

    public static var isICloudAvailable: Bool { iCloudDrive() != nil }

    /// The library folder to use when someone picks `path` for it.
    ///
    /// Picking a whole cloud drive — iCloud Drive itself, or a provider's root
    /// under `~/Library/CloudStorage` such as OneDrive — means the Transcripts
    /// folder inside it, the one the iPhone and iPad app creates when it is
    /// pointed at the same drive. Anything else is taken as chosen, including
    /// that Transcripts folder itself. So "iCloud Drive, or the Transcripts
    /// folder in it?" has no wrong answer, which it had until 1.1: pick the
    /// drive and the Mac watched all of it while the phone wrote one level down.
    public static func libraryFolder(forPicked path: String, home: String = userHome) -> String {
        let picked = URL(fileURLWithPath: path).standardizedFileURL.path
        let iCloudRoot = home + "/Library/Mobile Documents/com~apple~CloudDocs"
        let cloudStorage = home + "/Library/CloudStorage"
        let parent = (picked as NSString).deletingLastPathComponent
        if picked == iCloudRoot || parent == cloudStorage {
            return picked + "/" + folderName
        }
        return picked
    }

    /// Where a fresh install should file transcripts.
    ///
    /// Deliberately the *same* folder the phone syncs into: one location the
    /// user points every device at, so "where are my recordings" has a single
    /// answer. The device inbox keeps its files under `Inbox/` and `Processed/`
    /// subfolders, which routing ignores — it only ever considers `*/transcripts/`.
    public static func defaultKnowledgeRoot(fileManager: FileManager = .default) -> String {
        guard iCloudDrive(fileManager: fileManager) != nil else { return "~/Documents/\(folderName)" }
        return "~/Library/Mobile Documents/com~apple~CloudDocs/\(folderName)"
    }

    /// Where a fresh install should watch for phone/iPad captures. Nil when
    /// iCloud isn't available — better to leave device ingest off than to invent
    /// a local folder no phone can reach and have it silently never fire.
    public static func defaultDeviceInbox(fileManager: FileManager = .default) -> String? {
        guard iCloudDrive(fileManager: fileManager) != nil else { return nil }
        return "~/Library/Mobile Documents/com~apple~CloudDocs/\(folderName)"
    }
}
