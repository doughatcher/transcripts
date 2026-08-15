import AppKit
import TranscriptsCore
import TranscriptsEngine

/// Built-in-summarizer smoke test — loads the MLX model and runs one tiny
/// completion, then quits. Isolates the summarize tier from the rest of the
/// pipeline so a load failure is visible in seconds instead of after a full
/// record → transcribe → summarize run:
///
///   TRANSCRIPTS_MLX=1 ~/Applications/Transcripts.app/Contents/MacOS/Transcripts
///
/// Exit codes: 0 = model loaded and generated · 3 = load/generate failed.
@MainActor
enum MLXCheck {
    static var isRequested: Bool {
        ProcessInfo.processInfo.environment["TRANSCRIPTS_MLX"] != nil
    }

    static func runAndExit() {
        NSApp.setActivationPolicy(.prohibited)
        Task { @MainActor in
            exit(await perform())
        }
    }

    private static func perform() async -> Int32 {
        #if arch(arm64)
        print("Transcripts mlx-check — \(MLXChatModel.defaultModelID)")
        do {
            print("• loading (first run downloads ~1.5 GB from Hugging Face) …")
            let reply = try await MLXChatModel().chat(
                system: "You are terse.",
                user: "Say OK.",
                jsonFormat: false,
                maxTokens: 16)
            print("✓ model ready — reply: \(reply)")
            return 0
        } catch {
            print("✗ failed: \(error)")
            return 3
        }
        #else
        print("✗ MLX is Apple Silicon only")
        return 3
        #endif
    }
}
