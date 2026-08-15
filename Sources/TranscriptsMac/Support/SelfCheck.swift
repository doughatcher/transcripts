import AppKit
import AVFoundation
import TranscriptsCore

/// Hardware smoke test for both audio flows — the part unit tests can't reach.
/// Records ~2s from the microphone a real recording would use (same config,
/// same resolution rules) and verifies the engine started, the file was written,
/// and whether real signal arrived; then starts/stops system-audio capture to
/// verify the ScreenCaptureKit path. Prints a PASS/FAIL report and exits.
///
/// Run against the installed app so it inherits the TCC grants (mic / Screen
/// Recording are tied to the bundle identity):
///
///   TRANSCRIPTS_SELFCHECK=1 ~/Applications/Transcripts.app/Contents/MacOS/Transcripts
///
/// Caveat: immediately after make-app.sh replaces the installed bundle, the
/// first ScreenCaptureKit call can spuriously report "user declined TCCs"
/// while macOS re-validates the (unchanged) signature against the new bundle.
/// If system audio fails right after a reinstall, re-run before concluding
/// the grant is missing.
///
/// Exit codes: 0 = both flows verified · 1 = mic flow broken (device/engine/file)
/// · 2 = mic flow ran but captured silence (dead/muted mic — check the room)
/// · 3 = mic OK, system-audio capture unavailable (Screen Recording not granted?)
@MainActor
enum SelfCheck {
    static var isRequested: Bool {
        ProcessInfo.processInfo.environment["TRANSCRIPTS_SELFCHECK"] != nil
    }

    static func runAndExit() {
        NSApp.setActivationPolicy(.prohibited)
        Task { @MainActor in
            exit(await perform())
        }
    }

    private static func perform() async -> Int32 {
        print("Transcripts self-check — exercising both audio flows (~5s)")
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("transcripts-selfcheck-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        // ── Flow 1: microphone ────────────────────────────────────────────────
        guard await Recorder.ensureMicAccess() else {
            print("✗ mic: access not granted (System Settings ▸ Privacy & Security ▸ Microphone)")
            return 1
        }

        let cfg = (try? ConfigStore().load()) ?? .default
        guard let device = AudioInputDevices.resolve(favorites: cfg.favoriteInputUIDs,
                                                     override: cfg.overrideInputUID) else {
            print("✗ mic: no input device resolved")
            return 1
        }
        print("• mic: recording 2s from '\(device.name)' (same device a real recording would use)")

        let recorder = Recorder(device: device, captureSystemAudio: false)
        let recording: Recording
        do {
            try recorder.start(into: scratch)
            try await Task.sleep(for: .seconds(2))
            recording = try recorder.stop()
        } catch {
            print("✗ mic: \(error)")
            return 1
        }

        let attrs = try? FileManager.default.attributesOfItem(atPath: recording.audioURL.path)
        let size = (attrs?[.size] as? Int) ?? 0
        guard size > 0 else {
            print("✗ mic: no audio file written")
            return 1
        }
        let peak = recording.peakLevel ?? 0
        // Fail only on *digital* silence (dead/hardware-muted device). A quiet
        // room with a healthy mic still shows ambient noise — that's a pass;
        // requiring someone to talk during every release build isn't a gate,
        // it's a superstition.
        let silent = AudioLevel.isDigitallyDead(peak: peak)
        let quiet = !silent && AudioLevel.isSilent(peak: peak)
        print("\(silent ? "⚠" : "✓") mic: engine ok, \(size) bytes written, peak=\(String(format: "%.4f", peak))"
              + (silent ? "  ← DEAD (no signal at all — dead/hardware-muted mic?)" : "")
              + (quiet ? "  (quiet room — ambient noise present, device is alive)" : ""))

        // ── Flow 2: system audio (the other side of calls) ────────────────────
        let capturer = SystemAudioCapturer()
        let sysURL = scratch.appendingPathComponent("system.caf")
        let started = await capturer.start(into: sysURL)
        var sysOK = false
        if started {
            try? await Task.sleep(for: .seconds(2))
            sysOK = await capturer.stop() != nil
        }
        print("\(sysOK ? "✓" : "⚠") system audio: \(sysOK ? "capture started and wrote samples" : started ? "started but wrote no samples" : "could not start (Screen Recording not granted?) — calls degrade to mic-only")")

        if silent { return 2 }
        if !sysOK { return 3 }
        print("✓ self-check passed — both flows verified on this Mac")
        return 0
    }
}
