import AppKit
import AVFoundation
import TranscriptsCore

/// Hardware smoke test for both audio flows — the part unit tests can't reach.
/// Records ~2s from the microphone a real recording would use (same config,
/// same resolution rules) and verifies the engine started, the file was written,
/// and whether real signal arrived; then starts/stops system-audio capture to
/// verify that path (Core Audio tap on 14.2+, ScreenCaptureKit as fallback). Prints a PASS/FAIL report and exits.
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
/// · 3 = mic OK, system-audio capture unavailable (permission not granted?)
@MainActor
enum SelfCheck {
    static var isRequested: Bool {
        ProcessInfo.processInfo.environment["TRANSCRIPTS_SELFCHECK"] != nil
    }

    static func runAndExit() {
        let env = ProcessInfo.processInfo.environment
        // Spike: grant folders in one launch, prove they reopen in the next.
        if let paths = env["TRANSCRIPTS_SPIKE_GRANT"] {
            NSApp.setActivationPolicy(.accessory)
            NSApp.activate(ignoringOtherApps: true)
            for path in paths.split(separator: ":").map(String.init) {
                let got = SettingsView.adoptFolder(path, title: "Spike: allow access to \((path as NSString).lastPathComponent)")
                print("• grant \(path) → \(got ?? "cancelled")")
            }
            exit(0)
        }
        if let paths = env["TRANSCRIPTS_SPIKE_READ"] {
            FolderAccess.restoreAll()
            exit(probeFolders(paths.split(separator: ":").map { Locations.expand(String($0)) }))
        }
        NSApp.setActivationPolicy(.prohibited)
        Task { @MainActor in
            exit(await perform())
        }
    }

    /// Spike: the shape of a real recording — mic engine running, system-audio
    /// capture started alongside it — on a named mic, both tracks measured.
    private static func concurrent(micUID: String) async -> Int32 {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("transcripts-spike-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        guard await Recorder.ensureMicAccess() else { print("✗ mic: access not granted"); return 1 }
        guard let device = AudioInputDevices.all().first(where: { $0.uid == micUID }) else {
            print("✗ mic: no device \(micUID); have: \(AudioInputDevices.all().map { "\($0.uid)=\($0.name)" })")
            return 1
        }
        print("• sandboxed=\(ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil) mic='\(device.name)'")
        let recorder = Recorder(device: device, captureSystemAudio: false)
        let capturer = SystemAudioCapturer()
        let sysURL = scratch.appendingPathComponent("system.caf")
        let recording: Recording
        do {
            try recorder.start(into: scratch)
            let started = await capturer.start(into: sysURL)
            print("• system audio started=\(started)")
            try await Task.sleep(for: .seconds(8))
            _ = await capturer.stop()
            recording = try recorder.stop()
        } catch { print("✗ \(error)"); return 1 }
        print("• mic peak=\(String(format: "%.4f", recording.peakLevel ?? 0))")
        print("• " + measure(sysURL))
        return 0
    }

    /// Spike: can this launch list, read and write each folder?
    private static func probeFolders(_ paths: [String]) -> Int32 {
        let fm = FileManager.default
        print("• sandboxed=\(FolderAccess.isSandboxed) home=\(Locations.userHome)")
        var failed = false
        for path in paths {
            let url = URL(fileURLWithPath: path)
            print("── \(path)  canReach=\(FolderAccess.canReach(path))")
            guard let items = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.contentModificationDateKey],
                                                             options: [.skipsHiddenFiles]) else {
                print("  ✗ cannot list"); failed = true; continue
            }
            print("  ✓ list: \(items.count) entries")
            // Newest few, recursively, so a fresh phone recording shows up.
            var newest: [(Date, String)] = []
            if let walk = fm.enumerator(at: url, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                                        options: [.skipsHiddenFiles]) {
                for case let f as URL in walk {
                    let v = try? f.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
                    if v?.isRegularFile == true, let d = v?.contentModificationDate {
                        newest.append((d, String(f.path.dropFirst(url.path.count + 1))))
                    }
                }
            }
            newest.sort { $0.0 > $1.0 }
            for (d, n) in newest.prefix(3) { print("    \(d)  \(n)") }
            if let md = newest.first(where: { $0.1.hasSuffix(".md") }),
               let text = try? String(contentsOf: url.appendingPathComponent(md.1), encoding: .utf8) {
                print("  ✓ read: \(md.1) (\(text.count) chars)")
            } else { print("  ⚠ read: no readable .md among newest files") }
            let probe = url.appendingPathComponent(".transcripts-spike-\(UUID().uuidString)")
            do {
                try Data("spike".utf8).write(to: probe)
                try fm.removeItem(at: probe)
                print("  ✓ write: created and removed a probe file")
            } catch { print("  ✗ write: \(error.localizedDescription)"); failed = true }
        }
        return failed ? 1 : 0
    }

    private static func measure(_ url: URL) -> String {
        guard let file = try? AVAudioFile(forReading: url),
              let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                         frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: buf)) != nil, let ch = buf.floatChannelData
        else { return "system.caf unreadable or absent" }
        var peak: Float = 0, nonZero = 0
        for c in 0..<Int(buf.format.channelCount) {
            for i in 0..<Int(buf.frameLength) {
                let v = abs(ch[c][i]); peak = max(peak, v); if v > 0 { nonZero += 1 }
            }
        }
        return "system.caf frames=\(buf.frameLength) peak=\(String(format: "%.4f", peak)) nonZeroSamples=\(nonZero)"
    }

    private static func perform() async -> Int32 {
        if let uid = ProcessInfo.processInfo.environment["TRANSCRIPTS_SPIKE_MIC"] {
            return await concurrent(micUID: uid)
        }
        print("Transcripts self-check — exercising both audio flows (~5s)")
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("transcripts-selfcheck-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let sysOnly = ProcessInfo.processInfo.environment["TRANSCRIPTS_SYSAUDIO_ONLY"] != nil
        var silent = false
        if !sysOnly {
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
        silent = AudioLevel.isDigitallyDead(peak: peak)
        let quiet = !silent && AudioLevel.isSilent(peak: peak)
        print("\(silent ? "⚠" : "✓") mic: engine ok, \(size) bytes written, peak=\(String(format: "%.4f", peak))"
              + (silent ? "  ← DEAD (no signal at all — dead/hardware-muted mic?)" : "")
              + (quiet ? "  (quiet room — ambient noise present, device is alive)" : ""))

        }

        // ── Flow 2: system audio (the other side of calls) ────────────────────
        let capturer = SystemAudioCapturer()
        let sysURL = scratch.appendingPathComponent("system.caf")
        let started = await capturer.start(into: sysURL)
        var sysOK = false
        if started {
            try? await Task.sleep(for: .seconds(4))
            sysOK = await capturer.stop() != nil
        }
        // Spike: "wrote samples" cannot tell a working tap from TCC-authorized
        // silence, and silence is the question. Measure what landed.
        if let file = try? AVAudioFile(forReading: sysURL),
           let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                      frameCapacity: AVAudioFrameCount(file.length)),
           (try? file.read(into: buf)) != nil, let ch = buf.floatChannelData {
            var peak: Float = 0, nonZero = 0
            for c in 0..<Int(buf.format.channelCount) {
                for i in 0..<Int(buf.frameLength) {
                    let v = abs(ch[c][i]); peak = max(peak, v); if v > 0 { nonZero += 1 }
                }
            }
            print("• spike: system.caf frames=\(buf.frameLength) peak=\(String(format: "%.4f", peak)) nonZeroSamples=\(nonZero)")
        } else {
            print("• spike: system.caf unreadable or absent")
        }
        print("\(sysOK ? "✓" : "⚠") system audio: \(sysOK ? "capture started and wrote samples" : started ? "started but wrote no samples" : "could not start (Screen Recording not granted?) — calls degrade to mic-only")")

        if silent { return 2 }
        if !sysOK { return 3 }
        print("✓ self-check passed — both flows verified on this Mac")
        return 0
    }
}
