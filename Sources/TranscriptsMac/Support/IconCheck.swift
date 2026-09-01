import AppKit
import TranscriptsCore

/// Menu-bar icon contact sheet — renders every style and state through the real
/// `MenuBarIconRenderer` and writes a PNG, so an icon can be judged before it is
/// lived with:
///
///   TRANSCRIPTS_ICONS=/tmp/icons.png ~/Applications/Transcripts.app/Contents/MacOS/Transcripts
///
/// Through the shipping renderer on purpose. A mock-up drawn beside the real
/// code drifts from it the moment either is touched, and the whole point of
/// looking is to see what will actually appear next to the clock.
@MainActor
enum IconCheck {
    static var requestedPath: String? {
        ProcessInfo.processInfo.environment["TRANSCRIPTS_ICONS"]
    }

    static func runAndExit(path: String) {
        NSApp.setActivationPolicy(.prohibited)
        exit(perform(path: path))
    }

    /// Menu-bar icons are 18pt; `scale` is only for looking at them.
    private static let unit: CGFloat = 18
    private static let scale: CGFloat = 5
    private static let levels: [Float] = [0, 0.08, 0.25, 0.5, 0.8, 1.0]

    private static func perform(path: String) -> Int32 {
        let tint = NSColor.fromHex(HexColor.recordingRed)
        let styles = MenuBarIconStyle.allCases
        let states: [(String, MenuBarIconRenderer.IconState)] =
            [("Stopped", .idle), ("Armed", .armed)]

        let colW = unit * scale + 26
        let leftGutter: CGFloat = 118
        let rowH = unit * scale + 34
        let cols = CGFloat(states.count + levels.count)
        let width = leftGutter + colW * cols + 20
        let height = 54 + rowH * CGFloat(styles.count)

        let sheet = NSImage(size: NSSize(width: width, height: height))
        sheet.lockFocus()
        // Drawn on the darker of the two menu bars: it is the harder one for a
        // template glyph, and the one the recording colour has to survive.
        NSColor(white: 0.13, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()

        func label(_ t: String, _ x: CGFloat, _ y: CGFloat, size: CGFloat, alpha: CGFloat) {
            (t as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: [
                .font: NSFont.systemFont(ofSize: size, weight: .medium),
                .foregroundColor: NSColor(white: 1, alpha: alpha),
            ])
        }

        for (i, s) in states.enumerated() {
            label(s.0, leftGutter + colW * CGFloat(i), height - 34, size: 11, alpha: 0.8)
        }
        for (i, l) in levels.enumerated() {
            let x = leftGutter + colW * CGFloat(states.count + i)
            label(i == 0 ? "Recording" : "\(Int(l * 100))%", x, height - 34, size: 11,
                  alpha: i == 0 ? 0.8 : 0.55)
        }

        for (ri, style) in styles.enumerated() {
            let y = height - 54 - rowH * CGFloat(ri + 1)
            label(style.rawValue, 14, y + rowH / 2, size: 12, alpha: 0.85)
            for (ci, s) in states.enumerated() {
                let img = MenuBarIconRenderer.image(style: style, state: s.1, tint: tint)
                draw(img, at: leftGutter + colW * CGFloat(ci), y + 24)
            }
            for (ci, l) in levels.enumerated() {
                let img = pulse(style: style, level: l, tint: tint)
                draw(img, at: leftGutter + colW * CGFloat(states.count + ci), y + 24)
            }
        }
        sheet.unlockFocus()

        guard let tiff = sheet.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            print("✗ could not encode the sheet")
            return 1
        }
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        do {
            try png.write(to: url)
            print("✓ wrote \(url.path)")
            return 0
        } catch {
            print("✗ \(error)")
            return 1
        }
    }

    /// Paints a template glyph white in its own transparent image.
    ///
    /// Compositing it onto the sheet directly with `destinationIn` punches a
    /// hole straight through the sheet's background, which is how the first
    /// version of this came out as black boxes — a contact sheet that lies about
    /// the icons is worse than not having one.
    private static func inked(_ image: NSImage) -> NSImage {
        let out = NSImage(size: image.size, flipped: false) { rect in
            NSColor.white.set()
            rect.fill(using: .sourceOver)
            image.draw(in: rect, from: .zero, operation: .destinationIn, fraction: 1)
            return true
        }
        out.isTemplate = false
        return out
    }

    /// Draws one icon: enlarged, with actual size beneath it.
    private static func draw(_ image: NSImage, at x: CGFloat, _ y: CGFloat) {
        let rect = NSRect(x: x, y: y, width: unit * scale, height: unit * scale)
        let drawable = image.isTemplate ? inked(image) : image
        drawable.draw(in: rect)
        // Actual size beneath, which is the only size that decides anything.
        image.draw(in: NSRect(x: x + (unit * scale - unit) / 2, y: y - 24, width: unit, height: unit))
    }

    private static func pulse(style: MenuBarIconStyle, level: Float, tint: NSColor) -> NSImage {
        switch style {
        case .transport: return MenuBarIconRenderer.transportPulse(level: level, tint: tint)
        case .waveform: return MenuBarIconRenderer.levelPulse(level: level, tint: tint)
        case .mark: return MenuBarIconRenderer.markPulse(level: level, tint: tint)
        case .microphone: return MenuBarIconRenderer.image(style: .microphone, state: .recording, tint: tint)
        }
    }
}
