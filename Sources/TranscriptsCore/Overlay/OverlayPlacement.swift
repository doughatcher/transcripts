import Foundation
import CoreGraphics

/// Where the overlay is allowed to sit.
///
/// The panel is draggable and its position is remembered, which introduces one
/// way to lose it permanently: drag it mostly off the edge, or park it on a
/// second monitor and then unplug that monitor. Either way the remembered point
/// is somewhere nothing can reach, and every later launch restores it there.
///
/// So a remembered position is a request, not an instruction — it is clamped
/// onto a screen that actually exists before it is used.
public enum OverlayPlacement {
    /// Clamps `topLeft` so a panel of `size` sits fully within one of `screens`.
    ///
    /// Coordinates are AppKit's: y grows upward, and `topLeft` is the panel's
    /// upper-left corner. `screens` are visible frames (menu bar and Dock already
    /// excluded). Returns nil when there are no screens at all.
    ///
    /// The chosen screen is whichever the panel already overlaps most, so
    /// dragging it a little past an edge nudges it back onto the display it was
    /// on rather than teleporting it to the primary one.
    public static func clamp(topLeft: CGPoint, size: CGSize, screens: [CGRect]) -> CGPoint? {
        guard let fallback = screens.first else { return nil }
        let rect = CGRect(x: topLeft.x, y: topLeft.y - size.height,
                          width: size.width, height: size.height)

        let screen = screens.max { a, b in area(of: a.intersection(rect)) < area(of: b.intersection(rect)) }
            ?? fallback
        // No overlap with anything: the remembered spot is gone (an unplugged
        // display), so start from the best screen's own top-left region.
        let target = area(of: screen.intersection(rect)) > 0 ? screen : fallback

        // `max(lower, ...)` last so a panel larger than the screen pins to the
        // top-left corner instead of inverting the range.
        let x = max(target.minX, min(topLeft.x, target.maxX - size.width))
        let bottom = max(target.minY, min(rect.minY, target.maxY - size.height))
        return CGPoint(x: x, y: bottom + size.height)
    }

    private static func area(of rect: CGRect) -> CGFloat {
        rect.isNull || rect.isEmpty ? 0 : rect.width * rect.height
    }
}
