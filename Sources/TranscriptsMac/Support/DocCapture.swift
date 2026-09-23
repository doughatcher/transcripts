import SwiftUI
import AppKit
import TranscriptsCore

/// Offscreen renderer that photographs the whole guide — every Settings tab, the
/// menu, the Recordings window and the overlay — to `docs/guide/images/*.png`.
/// Runs entirely in-process via `NSHostingView` + `cacheDisplay` — no Screen
/// Recording permission, no window automation, no AppleScript — which is why it
/// wraps each view in a *drawn* window frame instead of capturing a real window.
///
/// That is the whole point. The guide used to be shot with `screencapture`
/// against the app the author happened to be running, and it published ten
/// images of real meetings: real titles, a whole real transcript, a room's worth
/// of real conversation in the overlay, and a desktop with the weather widget
/// naming the city. Shots taken that way also cannot be re-taken — they need a
/// GUI session, an awake display, a granted TCC permission and whatever was on
/// screen that day, so they get put off, and stale images stay published.
/// Everything here renders from the generated demo library instead (see
/// `scripts/demo-library.py`), on any machine, over SSH, with the lid shut.
///
/// Trigger: launch with `TRANSCRIPTS_CAPTURE_DOCS=1` (optionally set it to the
/// output directory). `scripts/guide-shots.py` wires up the demo config, library
/// and vault registry around it and then the process exits — it never shows the
/// menu bar UI.
@MainActor
enum DocCapture {
    static var isRequested: Bool {
        ProcessInfo.processInfo.environment["TRANSCRIPTS_CAPTURE_DOCS"] != nil
    }

    /// One image in the guide: what to draw, and how big to draw it.
    private struct Shot {
        let name: String
        /// Applied immediately before this shot renders. Carried on the shot
        /// rather than set while the list is built, because the views are
        /// closures: posing during construction leaves whichever pose was set
        /// last in force for every one of them, which is how three different
        /// menu states first came out as three copies of the same picture.
        var pose: AppController.CapturePose?
        /// Fixed render size, or nil to take the view's fitting size.
        var size: CGSize?
        /// Settles async work — a `.task` that reads the document off disk, an
        /// audio player measuring a file — before the snapshot is taken.
        var settle: TimeInterval = 0.2
        let view: () -> AnyView
    }

    /// Renders every shot, writes the PNGs, and terminates the process.
    static func runAndExit() {
        // Refuse to shoot the user's own library. Both overrides have to be in
        // force: the config names the knowledge root, and the support directory
        // holds history.json — which is where the menu and the Recordings window
        // get their titles from, so an unset one photographs real meetings while
        // everything else in the frame looks staged. Checked here rather than
        // trusted to the caller, because the caller is a script that can be run
        // by hand with half its environment.
        let env = ProcessInfo.processInfo.environment
        let missing = ["TRANSCRIPTS_CONFIG", "TRANSCRIPTS_SUPPORT_DIR"]
            .filter { (env[$0] ?? "").isEmpty }
        guard missing.isEmpty else {
            let names = missing.joined(separator: " and ")
            FileHandle.standardError.write(Data(("✗ docs capture: \(names) unset — "
                + "refusing to photograph the real library. "
                + "Run scripts/guide-shots.py.\n").utf8))
            exit(2)
        }

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

        let controller = AppController.shared
        // The library is read on a first pass after launch; without a beat here
        // the menu and the Recordings window photograph empty.
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))

        let shots = allShots(controller)
        var written = 0
        for shot in shots {
            let url = outDir.appendingPathComponent("\(shot.name).png")
            if render(shot, to: url) {
                written += 1
                print("  ✓ \(url.lastPathComponent)")
            } else {
                FileHandle.standardError.write(Data("  ✗ failed to render \(shot.name)\n".utf8))
            }
        }
        print("✓ docs capture: wrote \(written)/\(shots.count) image(s) to \(outDir.path)")
        exit(written == shots.count ? 0 : 1)
    }

    // MARK: - The guide

    /// Every image the guide uses, in the order the guide uses them.
    private static func allShots(_ controller: AppController) -> [Shot] {
        var shots: [Shot] = []

        // Settings — five tabs, drawn in the Settings window's own chrome.
        let tabs = ["settings-general", "settings-voices", "settings-sorting",
                    "settings-pipeline", "settings-about"]
        for (index, name) in tabs.enumerated() {
            shots.append(Shot(name: name, settle: 0.35) {
                AnyView(FauxWindow(title: "Transcripts Settings") {
                    SettingsView(forcedTab: index, drawnTabBar: true)
                }
                .environmentObject(controller))
            })
        }

        // The menu, in its three states worth a picture.
        shots.append(menuShot("menu-idle", controller, pose: .watching))
        shots.append(menuShot("menu-recording", controller, pose: .recording))
        shots.append(menuShot("remember-voice", controller, pose: .voiceSuggestion))

        // The Recordings window, showing the demo library's newest take.
        let newest = controller.allRecents.first
        controller.selectedRecordID = newest?.id
        shots.append(Shot(name: "document-summary", pose: .watching,
                          size: CGSize(width: 940, height: 640), settle: 1.2) {
            AnyView(FauxWindow(title: "Recordings") {
                LibraryView().frame(width: 940, height: 640)
            }
            .environmentObject(controller))
        })
        // The transcript is the same document, further down. Scrolling to it is
        // the one thing an offscreen render cannot do — a ScrollView offscreen
        // has no scroller to drive — so the document is laid out at full height
        // and shown through a window-sized opening onto its lower half. The
        // sidebar is left out rather than photographed empty: at that scroll
        // depth it has nothing in it, and a blank pane reads as a broken app.
        if let doc = newest?.path {
            shots.append(Shot(name: "document-transcript", pose: .watching,
                              size: CGSize(width: 900, height: 470), settle: 1.2) {
                AnyView(FauxWindow(title: newest?.title ?? "Recordings") {
                    MarkdownViewerView(url: doc)
                        .frame(width: 900, height: 1600)
                        .offset(y: -720)
                        .frame(width: 900, height: 470, alignment: .top)
                        .clipped()
                }
                .environmentObject(controller))
            })
        }

        // The overlay: the pill on its own, and the panel it opens into.
        // Light, unlike everything else here: the collapsed pill is Liquid
        // Glass, which draws its label dark for the bright surface it expects to
        // be floating over. Offscreen it cannot sample one, so the shot has to
        // supply it — dark text on a dark plate is a pill with nothing in it.
        shots.append(Shot(name: "live-edge", pose: .watching, settle: 0.3) {
            AnyView(Backdrop(width: 620, height: 200, light: true) {
                Glass(cornerRadius: 22, light: true) {
                    OverlayContent(model: OverlayModel.demoPill(), onClose: {})
                }
            })
        })
        shots.append(Shot(name: "overlay", pose: .watching, settle: 0.3) {
            AnyView(Backdrop(width: 620, height: 420) {
                Glass(cornerRadius: 18) {
                    OverlayContent(model: OverlayModel.demoExpanded(), onClose: {})
                }
            })
        })

        return shots
    }

    private static func menuShot(_ name: String, _ controller: AppController,
                                 pose: AppController.CapturePose) -> Shot {
        Shot(name: name, pose: pose, settle: 0.35) {
            AnyView(Backdrop(width: 520, height: nil) {
                FauxPopover { MenuBarView().environmentObject(controller) }
            })
        }
    }

    // MARK: - Rendering

    private static func render(_ shot: Shot, to url: URL) -> Bool {
        if let pose = shot.pose { AppController.shared.poseForCapture(pose) }

        // NSHostingView + cacheDisplay renders the REAL NSView tree (native
        // TabView/Form/Toggle/Picker), unlike ImageRenderer which draws an
        // "unsupported" placeholder for AppKit-backed controls. All in-process,
        // no Screen Recording permission.
        let hosting = NSHostingView(rootView: shot.view())
        hosting.appearance = NSAppearance(named: .darkAqua)
        hosting.frame = NSRect(origin: .zero, size: shot.size ?? hosting.fittingSize)

        // A borderless offscreen window gives the hierarchy a backing store (and
        // the host machine's 2x scale factor) so native controls lay out + draw.
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        // The *window's* appearance is what AppKit-drawn controls resolve
        // against, and a window that has none drawn its selected settings tab as
        // a light Aqua capsule while SwiftUI drew the label on it in dark-mode
        // white — a highlighted tab with no name on it, in every settings image
        // the guide has ever shipped.
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        // Key, even though nobody can click it: AppKit draws selection without
        // emphasis in a window that is not key, and "without emphasis" for the
        // selected settings tab and the selected row in the Recordings list
        // means drawing the highlight and then *not drawing the label on it* —
        // a blue box with nothing in it, which is what the first pass of this
        // harness published.
        window.makeKeyAndOrderFront(nil)
        // Let SwiftUI settle its async layout — and any `.task` reading a file —
        // before snapshotting.
        RunLoop.current.run(until: Date().addingTimeInterval(shot.settle))
        hosting.layoutSubtreeIfNeeded()
        window.displayIfNeeded()

        let bounds = hosting.bounds
        guard bounds.width > 1, bounds.height > 1,
              let rep = hosting.bitmapImageRepForCachingDisplay(in: bounds) else { return false }
        hosting.cacheDisplay(in: bounds, to: rep)

        guard let png = rep.representation(using: .png, properties: [:]) else { return false }
        // A view that laid out but never drew comes back as one flat colour, and
        // a flat PNG is small: it compresses to a few KB where a real screenshot
        // of the same size is hundreds. Cheaper to check than decoding pixels,
        // and it is the failure this harness actually has.
        guard png.count > 12_000 else {
            FileHandle.standardError.write(Data(
                "  ! \(shot.name) rendered blank (\(png.count) bytes)\n".utf8))
            return false
        }
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

// MARK: - Drawn chrome

/// A drawn approximation of the macOS Settings window — traffic lights, centered
/// title, and the tab bar — so a snapshot reads like a real screenshot without
/// needing to capture an actual window.
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
            content   // the real SettingsView / LibraryView, incl. its own chrome
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

/// A drawn approximation of the menu-bar popover: the arrow that points back at
/// the status item, and the material panel under it. `NSPopover` draws both, and
/// nothing offscreen has an `NSPopover` to borrow them from.
private struct FauxPopover<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            Arrow()
                .fill(Color(red: 0.16, green: 0.16, blue: 0.17))
                .frame(width: 22, height: 11)
            content
                .background(Color(red: 0.16, green: 0.16, blue: 0.17))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.09), lineWidth: 1)
                )
        }
        .shadow(color: .black.opacity(0.4), radius: 20, y: 8)
    }

    private struct Arrow: Shape {
        func path(in rect: CGRect) -> Path {
            var p = Path()
            p.move(to: CGPoint(x: rect.midX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            p.closeSubpath()
            return p
        }
    }
}

/// A drawn stand-in for the overlay's own material surface.
///
/// `.ultraThinMaterial` is an `NSVisualEffectView`, and one of those samples
/// what is *behind its window* through the compositor. An offscreen render has
/// no compositor and nothing behind it, so the material comes out fully
/// transparent and the pill photographs as text floating on the desktop. This
/// draws what the material resolves to over a dark backdrop, so the shape is in
/// the picture.
private struct Glass<Content: View>: View {
    let cornerRadius: CGFloat
    var light = false
    @ViewBuilder var content: Content

    var body: some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(light ? Color(red: 0.93, green: 0.94, blue: 0.96).opacity(0.97)
                          : Color(red: 0.17, green: 0.18, blue: 0.21).opacity(0.97))
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .strokeBorder((light ? Color.black : Color.white).opacity(0.10),
                                          lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.45), radius: 18, y: 8)
            )
    }
}

/// What floating chrome is photographed against. A desktop would do it, but the
/// desktop is exactly what leaked last time — widgets name a city, a wallpaper
/// dates the shot, and every re-take looks different. A gradient is none of
/// those things and stays the same on any machine.
private struct Backdrop<Content: View>: View {
    let width: CGFloat
    let height: CGFloat?
    var light = false
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(.horizontal, 40)
            .padding(.vertical, 34)
            .frame(width: width, height: height)
            .background(
                LinearGradient(colors: light
                               ? [Color(red: 0.86, green: 0.88, blue: 0.92),
                                  Color(red: 0.72, green: 0.75, blue: 0.82)]
                               : [Color(red: 0.20, green: 0.22, blue: 0.29),
                                  Color(red: 0.11, green: 0.12, blue: 0.16)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            )
    }
}

// MARK: - Demo overlay content

extension OverlayModel {
    /// The live edge: what someone is part-way through saying. Invented, and
    /// deliberately continuous with the demo library's onboarding review — the
    /// guide reads as one product being used, not seven unrelated screenshots.
    static func demoPill() -> OverlayModel {
        let model = OverlayModel()
        model.partial = "so the prompt moves after the first recording"
        return model
    }

    /// The panel the pill opens into, with all three lanes filled: where the
    /// topic landed, the figures stated, and the last question — answered from a
    /// note, which is the case worth showing because it is the one that proves
    /// the answer came from somewhere.
    static func demoExpanded() -> OverlayModel {
        let model = OverlayModel()
        model.expanded = true
        // The lanes come from the topic on the floor when there is one, so the
        // cards go in the topic and the digest carries the same set — a digest
        // whose topic is empty renders three "nothing yet" lines.
        let conclusion = OverlayCard(
            kind: .conclusion,
            headline: "Permission prompt moves after the first recording",
            source: .thisCall(at: 39), at: 39)
        let facts = [
            OverlayCard(kind: .fact, headline: "A third of testers declined at the prompt",
                        source: .thisCall(at: 24), at: 24),
            OverlayCard(kind: .fact, headline: "Five-person walkthrough to re-run",
                        source: .thisCall(at: 66), at: 66),
            OverlayCard(kind: .fact, headline: "Three-step onboarding flow",
                        source: .thisCall(at: 2), at: 2),
        ]
        let question = OverlayCard(
            kind: .question,
            headline: "What did the last walkthrough find?",
            answer: "Four of five testers stopped at the empty library and looked for a next step.",
            source: .note(title: "Onboarding walkthrough — round 1",
                          path: "transcripts/onboarding-walkthrough-round-1.md"),
            at: 61)
        let topic = TopicDigest(title: "Onboarding flow", startedAt: 0,
                                conclusion: conclusion, facts: facts,
                                lastQuestion: question, isCurrent: true)
        model.digest = OverlayDigest(
            lastSpoken: "so the prompt moves after the first recording",
            conclusion: conclusion,
            facts: facts,
            lastQuestion: question,
            topics: [topic],
            currentTopicIndex: 0)
        return model
    }
}
