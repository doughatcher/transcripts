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
