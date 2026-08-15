import Foundation

/// Parsing for the user-configurable recording-indicator color, kept in the core
/// so the config default and its tests don't need AppKit. The app layer bridges
/// these components to `NSColor`/`Color`.
public enum HexColor {
    /// The classic recording red — the default indicator tint.
    public static let recordingRed = "#FF453B"

    /// A bright azure preset, legible on both light and dark menu bars.
    public static let azure = "#159BD7"

    /// Parses `#RRGGBB` (the leading `#` optional) into sRGB components in 0…1.
    /// nil for anything malformed, so callers fall back to a known-good default
    /// rather than rendering an invisible icon.
    public static func components(_ hex: String) -> (r: Double, g: Double, b: Double)? {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        return (Double((v >> 16) & 0xFF) / 255,
                Double((v >> 8) & 0xFF) / 255,
                Double(v & 0xFF) / 255)
    }

    /// A canonical `#RRGGBB` (uppercase) for storage, or `fallback` when the input
    /// can't be parsed. Callers that have a machine-appropriate default (see
    /// `AppConfig.defaultRecordingColorHex`) should pass it, so a corrupt value
    /// lands back on the color that machine would have started with rather than
    /// silently branding an unmanaged Mac blue.
    public static func normalize(_ hex: String, fallback: String = recordingRed) -> String {
        guard let c = components(hex) else { return fallback }
        return string(r: c.r, g: c.g, b: c.b)
    }

    public static func string(r: Double, g: Double, b: Double) -> String {
        func byte(_ x: Double) -> Int { max(0, min(255, Int((x * 255).rounded()))) }
        return String(format: "#%02X%02X%02X", byte(r), byte(g), byte(b))
    }
}
