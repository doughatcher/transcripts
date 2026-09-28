import AppKit
import TranscriptsEngine

/// The `export` / `import` subcommands: the app binary run from a shell.
///
///     Transcripts.app/Contents/MacOS/Transcripts export > state.json
///     Transcripts.app/Contents/MacOS/Transcripts import < state.json
///
/// Or the two editions piped straight into each other:
///
///     ~/Applications/Transcripts.app/Contents/MacOS/Transcripts export \
///       | /Applications/Transcripts.app/Contents/MacOS/Transcripts import
///
/// stdout and stdin, not file paths, on purpose: the store build is sandboxed,
/// and a path passed as an argument is a path it cannot open — but the pipes a
/// shell hands it are file handles the sandbox never restricts. Each edition
/// reads and writes only its own state, and the shell carries it between them.
///
/// Runs headless and exits — same rule as the probe invocations (see
/// TranscriptsApp): never boot the controller, which recovers interrupted
/// recordings and auto-records calls the moment it wakes.
enum CommandLineTool {

    /// True when argv named a subcommand, which then ran (and exited on error).
    /// Anything unrecognized is not ours — launchd and Finder pass arguments of
    /// their own — so the app starts normally.
    static func run() -> Bool {
        guard let command = CommandLine.arguments.dropFirst().first else { return false }
        switch command {
        case "export": runExport()
        case "import": runImport()
        case "help", "--help", "-h": FileHandle.standardError.write(Data(usage.utf8))
        default: return false
        }
        return true
    }

    private static let usage = """
    Transcripts <export|import>

      export   Write this copy's recordings history and remembered voices
               to stdout as JSON. The transcripts themselves stay in your
               library folder and are not part of the bundle.
      import   Merge such a bundle from stdin into this copy. Additive:
               nothing already here is overwritten. Quit the app first.

    """

    private static func runExport() {
        do {
            let data = try Migration.encode(Migration.exportBundle())
            FileHandle.standardOutput.write(data)
        } catch {
            fail("could not encode the bundle: \(error.localizedDescription)")
        }
    }

    private static func runImport() {
        // A second writer corrupts the merge: the running app saves its own
        // history over whatever this process writes. (This process is a second
        // instance of that same app, so exclude ourselves from the check.)
        let running = NSRunningApplication.runningApplications(
            withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        guard running.isEmpty else {
            fail("Transcripts is running — quit it first, then import.")
        }
        guard let data = try? FileHandle.standardInput.readToEnd(), !data.isEmpty else {
            fail("nothing on stdin — pipe an `export` in, or `import < state.json`.")
        }
        let bundle: MigrationBundle
        do {
            bundle = try Migration.decode(data)
        } catch {
            fail("stdin was not an export bundle: \(error.localizedDescription)")
        }
        guard bundle.version <= MigrationBundle.currentVersion else {
            fail("bundle version \(bundle.version) is newer than this app understands — update this copy first.")
        }
        let summary = Migration.apply(bundle, history: HistoryStore())
        print(summary.description)
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("transcripts: \(message)\n".utf8))
        exit(1)
    }
}
