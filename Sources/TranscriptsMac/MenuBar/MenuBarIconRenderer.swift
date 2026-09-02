import SwiftUI
import AppKit
import TranscriptsCore

/// Renders the menu-bar icon as an `NSImage`. A menu-bar label template-renders
/// custom SwiftUI views (which is why a live EQ came out blank), but an `NSImage`
/// with `isTemplate = false` shows real color — so idle uses a template (adapts to
/// light/dark) and recording uses the user's chosen recording color (default
/// blue by default).
@MainActor
enum MenuBarIconRenderer {
    /// Visual states: `idle` (auto-record off) → outline; `armed` (watching) → solid
    /// adaptive (white on a dark menu bar); `recording` → solid colored.
    enum IconState: String { case idle, armed, recording }

    private static var cache: [String: NSImage] = [:]

    static func image(style: MenuBarIconStyle, state: IconState,
                      tint: NSColor = .recordingDefault) -> NSImage {
        // The tint only matters while recording; keep the cache key stable
        // otherwise so idle/armed images stay shared across color changes.
        let key = "\(style.rawValue)-\(state.rawValue)-\(state == .recording ? tint.hexKey : "x")"
        if let cached = cache[key] { return cached }
        let img = render(style: style, state: state, tint: tint)
        cache[key] = img
        return img
    }

    private static func render(style: MenuBarIconStyle, state: IconState, tint: NSColor) -> NSImage {
        switch style {
        case .transport:
            switch state {
            case .idle: return transport(.stopped, color: nil, tint: tint)
            case .armed: return transport(.armed, color: nil, tint: tint)
            case .recording: return transport(.rolling(level: 0), color: tint, tint: tint)
            }
        case .microphone:
            switch state {
            case .idle: return symbol("mic", color: nil)
            case .armed: return symbol("mic.fill", color: nil)
            case .recording: return symbol("mic.fill", color: tint)
            }
        case .waveform:
            switch state {
            // `waveform` has no outline variant, so idle and armed used to
            // render identically — the one distinction the icon exists to make.
            // Alpha is the template image's ink, so dimming reads as "off".
            case .idle: return dimmed(symbol("waveform", color: nil))
            case .armed: return symbol("waveform", color: nil)
            case .recording: return symbol("waveform", color: tint)
            }
        case .mark:
            switch state {
            case .idle: return dimmed(mark(color: nil))
            case .armed: return mark(color: nil)
            case .recording: return mark(color: tint)
            }
        }
    }

    /// What a tape deck's transport tells you, drawn at menu-bar size.
    enum Transport {
        /// Not recording and not going to: the stop square.
        case stopped
        /// Auto-record is on and watching. A deck's record-standby — the record
        /// light present but unlit — which is exactly this state and reads as
        /// "ready" rather than "off".
        case armed
        /// Rolling. `level` (0…1) inflates a translucent ring around the disc,
        /// so the icon shows audio arriving and not merely that a timer runs.
        case rolling(level: CGFloat)
    }

    /// `color` nil renders a template (adapts to light and dark menu bars);
    /// otherwise it is drawn in ink and the recording tint is used for the disc.
    ///
    /// Hollow-ring standby beat the alternatives at the size that matters. A
    /// ring with a dot inside has the dot close the ring at 18 points, and a
    /// dashed ring — the best "waiting" metaphor of the three — turns to mush.
    ///
    /// The shapes are sized to ~14 points across, not the ~11 they started at.
    /// The other styles here render at `pointSize: 15` (and the mark's text line
    /// spans 15), as does everything else in a menu bar — so a transport drawn
    /// to 11 read as a small icon sitting among normal ones, which is a thing
    /// the eye notices even when it cannot say why. The ripple's ceiling is
    /// unchanged: it still reaches 8.5 at full level and no further.
    private static func transport(_ transport: Transport, color: NSColor?, tint: NSColor) -> NSImage {
        let ink = (color ?? .black).usingColorSpace(.sRGB) ?? .black
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            let c = NSPoint(x: 9, y: 9)
            func circle(_ r: CGFloat) -> NSBezierPath {
                NSBezierPath(ovalIn: NSRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
            }
            switch transport {
            case .stopped:
                ink.setFill()
                let side: CGFloat = 11.5
                NSBezierPath(roundedRect: NSRect(x: c.x - side / 2, y: c.y - side / 2,
                                                 width: side, height: side),
                             xRadius: 2.0, yRadius: 2.0).fill()
            case .armed:
                ink.setStroke()
                let ring = circle(6.1)
                ring.lineWidth = 2.0
                ring.stroke()
            case .rolling(let level):
                let l = max(0, min(1, level))
                // Three layers, loudest last. Brightness carries the signal and
                // the rings second it: a disc that only changes colour says
                // "recording", one that throws a ripple outward as the room gets
                // loud says "someone is talking" from the corner of an eye.
                //
                // The whole thing has to live inside 18 points, and the disc
                // takes up most of them — so the ripple gets the ~3 points
                // outside it, and the radii below are set to reach 8.5 at full
                // level and no further. Anything past 9 is clipped by the canvas
                // and reads as a flat edge, not a ring.
                let base = (tint.usingColorSpace(.sRGB) ?? tint)
                let lift = l * 0.9
                let hot = NSColor(srgbRed: base.redComponent + (1 - base.redComponent) * lift,
                                  green: base.greenComponent + (1 - base.greenComponent) * lift,
                                  blue: base.blueComponent + (1 - base.blueComponent) * lift,
                                  alpha: 1)
                // Outermost: a thin ring that pushes away from the disc. Nearly
                // invisible in a quiet room, which is the point — silence should
                // look like a plain disc, not a permanent halo.
                tint.withAlphaComponent(0.10 + 0.55 * l).setStroke()
                let ripple = circle(7.3 + 1.2 * l)
                ripple.lineWidth = 1.2
                ripple.stroke()
                // A soft fill bridging disc and ring so the gap between them
                // does not read as a separate floating outline.
                tint.withAlphaComponent(0.16 + 0.26 * l).setFill()
                circle(6.8 + 0.9 * l).fill()
                // The disc itself keeps a fixed size: it is the shape being
                // read, and a target that changes size is harder to read than
                // one that changes colour. The rings do the moving.
                hot.setFill()
                circle(6.1).fill()
            }
            return true
        }
        // A rolling disc is always the recording colour — never a template, or
        // the menu bar would repaint the one thing that must stay red.
        if case .rolling = transport { img.isTemplate = false } else { img.isTemplate = (color == nil) }
        return img
    }

    /// The transport style's recording pulse: the disc flashes toward white and
    /// its halo swells as the room gets louder.
    ///
    /// Sixteen buckets rather than eight. The disc is the whole icon here, so
    /// the steps between levels are much more visible than they were on a
    /// waveform's bars, and eight of them read as a stutter.
    static func transportPulse(level: Float, tint: NSColor = .recordingDefault) -> NSImage {
        let bucket = max(0, min(15, Int((level).squareRoot() * 16)))  // sqrt: lively at low levels
        let key = "transport-pulse-\(tint.hexKey)-\(bucket)"
        if let cached = cache[key] { return cached }
        let img = transport(.rolling(level: CGFloat(bucket) / 15.0), color: tint, tint: tint)
        cache[key] = img
        return img
    }

    /// The app icon's motif — a line of text over a waveform — redrawn as a
    /// menu-bar glyph. Drawn in code rather than shipped as an asset so it stays
    /// crisp at every scale factor and tints/dims exactly like the symbols do.
    ///
    /// One text line, not the icon's three. The full mark is a picture of a
    /// document, and at 16 points a picture of a document is a smudge: rendered
    /// beside wifi and battery it was visibly finer-grained and busier than
    /// every neighbour, all of which are single bold shapes. One line reads as
    /// "what was said, written down" and leaves the waveform room to be the
    /// thing you actually look at.
    ///
    /// Everything sits low deliberately. The line is solid ink and the wave is
    /// mostly gaps, so weighting them equally puts the optical centre above the
    /// geometric one and the icon looks like it is floating.
    ///
    /// `waveLift` (0…1) lightens only the waveform bars toward white — the
    /// recording pulse — while the text line holds the tint, so the flash reads
    /// as sound arriving inside the mark rather than the whole icon blinking.
    private static func mark(color: NSColor?, waveLift: CGFloat = 0) -> NSImage {
        let ink = (color ?? .black).usingColorSpace(.sRGB) ?? .black
        let wave = NSColor(srgbRed: ink.redComponent + (1 - ink.redComponent) * waveLift * 0.85,
                           green: ink.greenComponent + (1 - ink.greenComponent) * waveLift * 0.85,
                           blue: ink.blueComponent + (1 - ink.blueComponent) * waveLift * 0.85,
                           alpha: 1)
        let img = NSImage(size: NSSize(width: 18, height: 16), flipped: false) { _ in
            func bar(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ c: NSColor) {
                c.setFill()
                NSBezierPath(roundedRect: NSRect(x: x, y: y, width: w, height: h),
                             xRadius: min(w, h) / 2, yRadius: min(w, h) / 2).fill()
            }
            bar(1.5, 12.0, 15.0, 2.2, ink)
            let heights: [CGFloat] = [3.0, 5.4, 8.4, 6.0, 7.4, 4.2, 2.8]
            let barW: CGFloat = 1.8, gap: CGFloat = 0.55
            let total = CGFloat(heights.count) * barW + CGFloat(heights.count - 1) * gap
            var x = (18 - total) / 2
            for h in heights {
                bar(x, 4.9 - h / 2, barW, h, wave)
                x += barW + gap
            }
            return true
        }
        img.isTemplate = (color == nil)
        return img
    }

    /// Template ink is the alpha channel, so a translucent redraw is "off".
    private static func dimmed(_ image: NSImage, to alpha: CGFloat = 0.45) -> NSImage {
        let out = NSImage(size: image.size, flipped: false) { rect in
            image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: alpha)
            return true
        }
        out.isTemplate = true
        return out
    }

    private static func symbol(_ name: String, color: NSColor?) -> NSImage {
        let cfg = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        let base = NSImage(systemSymbolName: name, accessibilityDescription: name) ?? NSImage()
        if let color {
            let colored = base.withSymbolConfiguration(cfg.applying(.init(paletteColors: [color]))) ?? base
            colored.isTemplate = false
            return colored
        }
        let templated = base.withSymbolConfiguration(cfg) ?? base
        templated.isTemplate = true
        return templated
    }

    /// A recording mark whose color **brightens with the input level** (0…1), so
    /// the menu bar shows audio is actually flowing. The chosen `tint` is the
    /// quiet-state base; louder input lightens it toward white so peaks flash.
    /// Quantized into buckets (and keyed by tint) so the small set of images is
    /// cached.
    ///
    /// The ancestor drew this on an agency logo. The pulse was always the useful
    /// part — a static icon cannot tell you a dead mic from a silent room — so it
    /// moved to the waveform and the logo went.
    static func levelPulse(level: Float, tint: NSColor = .recordingDefault) -> NSImage {
        let bucket = max(0, min(7, Int((level).squareRoot() * 8)))   // sqrt: lively at low levels
        let key = "level-pulse-\(tint.hexKey)-\(bucket)"
        if let cached = cache[key] { return cached }
        let t = CGFloat(bucket) / 7.0
        // Lighten the base tint toward white with level: each channel climbs the
        // remaining distance to 1, so the base stays clearly the chosen color while
        // loud peaks flash near-white.
        let base = (tint.usingColorSpace(.sRGB) ?? tint)
        let color = NSColor(srgbRed: base.redComponent + (1 - base.redComponent) * t * 0.85,
                            green: base.greenComponent + (1 - base.greenComponent) * t * 0.85,
                            blue: base.blueComponent + (1 - base.blueComponent) * t * 0.85,
                            alpha: 1)
        let img = symbol("waveform", color: color)
        img.isTemplate = false
        cache[key] = img
        return img
    }

    /// The mark's recording pulse: same level→brightness idea as `levelPulse`,
    /// but only the waveform bars lift — the text lines hold the tint.
    static func markPulse(level: Float, tint: NSColor = .recordingDefault) -> NSImage {
        let bucket = max(0, min(7, Int((level).squareRoot() * 8)))
        let key = "mark-pulse-\(tint.hexKey)-\(bucket)"
        if let cached = cache[key] { return cached }
        let img = mark(color: tint, waveLift: CGFloat(bucket) / 7.0)
        cache[key] = img
        return img
    }

    /// Recording color as a SwiftUI `Color`, for the popover indicators.
    static func recordingColor(hex: String) -> Color { Color(nsColor: .fromHex(hex)) }

}

extension NSColor {
    /// The recording color when none is configured.
    static let recordingDefault = NSColor.fromHex(HexColor.recordingRed)

    /// An sRGB color from `#RRGGBB`, falling back to the default on bad input.
    static func fromHex(_ hex: String) -> NSColor {
        let c = HexColor.components(hex) ?? HexColor.components(HexColor.recordingRed)!
        return NSColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: 1)
    }

    /// Stable short key for caching (canonical hex of the sRGB components).
    var hexKey: String {
        let c = usingColorSpace(.sRGB) ?? self
        return HexColor.string(r: c.redComponent, g: c.greenComponent, b: c.blueComponent)
    }
}
