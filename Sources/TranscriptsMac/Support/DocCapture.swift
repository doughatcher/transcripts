import SwiftUI
import AppKit

/// Offscreen renderer that snapshots each Settings tab to `docs/images/*.png`
/// for the README / GitHub wiki. Runs entirely in-process via `ImageRenderer`
/// — no Screen Recording permission, no window automation, no AppleScript —
/// which is why it wraps each tab in a *drawn* window frame instead of
/// capturing the real window.
///
/// Trigger: launch with `TRANSCRIPTS_CAPTURE_DOCS=1` (optionally set it to the output
/// directory). `scripts/make-app.sh CAPTURE_DOCS=1` wires this up and then the
/// process exits — it never shows the menu bar UI.
@MainActor
enum DocCapture {
    static var isRequested: Bool {
        ProcessInfo.processInfo.environment["TRANSCRIPTS_CAPTURE_DOCS"] != nil
    }

    /// Renders every tab, writes the PNGs, and terminates the process.
    static func runAndExit() {
        NSApp.setActivationPolicy(.prohibited)
        // Docs are shot in dark mode to match the shipped look.
        NSApp.appearance = NSAppearance(named: .darkAqua)

        let outDir = resolveOutputDir()
        do {
            try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        } catch {
            FileHandle.standardError.write(Data("✗ docs capture: cannot create \(outDir.path): \(error)\n".utf8))
            exit(1)
        }

        // Order MUST match SettingsView's tab tags (0…4).
        let files = ["settings-general", "settings-voices", "settings-sorting", "settings-pipeline", "settings-about"]
        var written = 0
        for index in files.indices {
            let url = outDir.appendingPathComponent("\(files[index]).png")
            if render(tabIndex: index, to: url) {
                written += 1
                print("  ✓ \(url.lastPathComponent)")
            } else {
                FileHandle.standardError.write(Data("  ✗ failed to render \(files[index])\n".utf8))
            }
        }
        print("✓ docs capture: wrote \(written)/\(files.count) screenshot(s) to \(outDir.path)")
        exit(written == files.count ? 0 : 1)
    }

    // MARK: - Rendering

    private static func render(tabIndex: Int, to url: URL) -> Bool {
        let content = FauxWindow(title: "Transcripts Settings") {
            SettingsView(forcedTab: tabIndex)
        }
        .environmentObject(AppController.shared)
        .environment(\.colorScheme, .dark)

        // NSHostingView + cacheDisplay renders the REAL NSView tree (native
        // TabView/Form/Toggle/Picker), unlike ImageRenderer which draws an
        // "unsupported" placeholder for AppKit-backed controls. All in-process,
        // no Screen Recording permission.
        let hosting = NSHostingView(rootView: content)
        hosting.appearance = NSAppearance(named: .darkAqua)
        hosting.frame = NSRect(origin: .zero, size: hosting.fittingSize)

        // A borderless offscreen window gives the hierarchy a backing store (and
        // the host machine's 2x scale factor) so native controls lay out + draw.
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        // Let SwiftUI settle its async layout before snapshotting.
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))

        let bounds = hosting.bounds
        guard bounds.width > 1, bounds.height > 1,
              let rep = hosting.bitmapImageRepForCachingDisplay(in: bounds) else { return false }
        hosting.cacheDisplay(in: bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return false }
        do { try png.write(to: url); return true } catch { return false }
    }

    private static func resolveOutputDir() -> URL {
        let raw = ProcessInfo.processInfo.environment["TRANSCRIPTS_CAPTURE_DOCS"] ?? ""
        // A bare "1"/"true"/"" means "use the default docs/images under the CWD".
        if raw.isEmpty || raw == "1" || raw.lowercased() == "true" {
            return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("docs/images")
        }
        return URL(fileURLWithPath: (raw as NSString).expandingTildeInPath)
    }
}

/// A drawn approximation of the macOS Settings window — traffic lights, centered
/// title, and the tab bar — so an `ImageRenderer` snapshot reads like a real
/// screenshot without needing to capture an actual window.
private struct FauxWindow<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    private static var lights: [Color] {
        [Color(red: 1.00, green: 0.37, blue: 0.34),   // close
         Color(red: 1.00, green: 0.74, blue: 0.18),   // minimize
         Color(red: 0.16, green: 0.79, blue: 0.25)]   // zoom
    }

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            content   // the real SettingsView, incl. its own tab bar
        }
        .background(Color(red: 0.13, green: 0.13, blue: 0.14))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.45), radius: 24, y: 12)
        .padding(40)
        .background(Color.clear)
    }

    private var titleBar: some View {
        ZStack {
            HStack(spacing: 8) {
                ForEach(Array(Self.lights.enumerated()), id: \.offset) { _, c in
                    Circle().fill(c).frame(width: 12, height: 12)
                }
                Spacer()
            }
            .padding(.leading, 16)
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .frame(height: 40)
    }
}
