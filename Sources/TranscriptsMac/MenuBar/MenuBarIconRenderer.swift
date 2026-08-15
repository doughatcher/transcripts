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
            return symbol("waveform", color: state == .recording ? tint : nil)
        }
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
