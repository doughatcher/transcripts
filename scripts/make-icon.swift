import AppKit
import CoreGraphics

// Transcripts app icon: a page of text whose middle line is still being spoken.
//
// One idea, not two. A document *and* a waveform drawn as separate objects is
// the skeuomorphic trap — two little pictures glued together, unreadable at
// 40pt. Instead the waveform IS a line of the text: the page reads as a
// transcript, and the one live line says the words are arriving as sound.
//
// Deliberately not a feather, a quill, a microphone, or a cassette. Those are
// pictures of obsolete objects; this is a picture of what the app produces.
//
// The artwork is drawn in three groups — ground, text lines, waveform — and
// each can be emitted on its own transparent canvas. That is what `--layers`
// is for: Icon Composer wants the pieces separately so it can put Liquid Glass
// between them, and a flattened PNG cannot be taken apart again.
//
//   swift scripts/make-icon.swift out.png [--macos] [--dark|--tinted] [--layers DIR]

let S: CGFloat = 1024

// MARK: - Theme
//
// The components keep their indigo→violet gradient in every appearance; only
// the ground changes. That is the whole trick — the gradient is the thing you
// recognise at 40pt, so inverting the ground beneath it reads as the same icon
// wearing a different coat rather than as a second icon.

enum Appearance {
    /// The original artwork: coloured ground, white marks. Still what the Mac
    /// build wears. The Mac app is `LSUIElement` — it lives in the menu bar and
    /// never appears in a Dock — so it has no dark-appearance problem to solve,
    /// and restyling it would be a change for its own sake.
    case brand
    case light, dark, tinted

    /// Ground gradient, top-leading → bottom-trailing.
    var ground: (CGColor, CGColor) {
        switch self {
        case .brand:  return (rgb(0x4F, 0x46, 0xE5), rgb(0x7C, 0x3A, 0xED))
        // Not pure white: a hair of warmth keeps the plate from vibrating
        // against the true-white of a Finder window behind it.
        case .light:  return (rgb(0xFF, 0xFF, 0xFF), rgb(0xF4, 0xF3, 0xF8))
        // Neutral, and very nearly black. An earlier version gave this a violet
        // cast on the theory that #000 reads as a hole rather than a tile —
        // true of an icon viewed alone, and wrong on a home screen, where every
        // other dark icon is essentially black and the cast made ours the one
        // tinted square in the dock. Judge a tile against its neighbours, not
        // against itself. The colour lives in the marks; the ground gets out of
        // the way, lifted off pure black only enough to read as a surface.
        case .dark:   return (rgb(0x0A, 0x0A, 0x0C), rgb(0x16, 0x16, 0x18))
        // Tinted is graded by luminance, not colour: the system re-maps this
        // to whatever tint the user picked, so all that matters is the ramp.
        case .tinted: return (rgb(0x00, 0x00, 0x00), rgb(0x00, 0x00, 0x00))
        }
    }

    /// Component gradient — the text lines and the waveform.
    var ink: (CGColor, CGColor) {
        switch self {
        // Flat white; the muted lines get there by alpha, as they always did.
        case .brand:  return (rgb(0xFF, 0xFF, 0xFF), rgb(0xFF, 0xFF, 0xFF))
        // Indigo → violet. Cool and document-ish rather than "recording red",
        // which is reserved for the in-app record affordance where it means
        // something.
        case .light:  return (rgb(0x4F, 0x46, 0xE5), rgb(0x7C, 0x3A, 0xED))
        // Lifted two steps for dark. The light-mode indigo is only ~3:1
        // against a near-black ground, which turns the ragged text edge — the
        // detail that makes it read as prose — into mush at small sizes.
        case .dark:   return (rgb(0x81, 0x8C, 0xF8), rgb(0xA7, 0x8B, 0xFA))
        case .tinted: return (rgb(0xFF, 0xFF, 0xFF), rgb(0xD8, 0xD8, 0xD8))
        }
    }
}

func rgb(_ r: Int, _ g: Int, _ b: Int) -> CGColor {
    CGColor(red: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
}

// MARK: - Arguments

let args = CommandLine.arguments
let macOS = args.contains("--macos")
// macOS defaults to `.brand` so that re-running make-icns.sh cannot silently
// restyle the Mac icon into iOS's white-ground light variant. iOS defaults to
// `.light`, which is the appearance the system pairs with `.dark` and
// `.tinted` in the asset catalog.
let appearance: Appearance =
    args.contains("--brand")  ? .brand
    : args.contains("--dark")   ? .dark
    : args.contains("--tinted") ? .tinted
    : args.contains("--light")  ? .light
    : (macOS ? .brand : .light)
let layersDir: String? = args.firstIndex(of: "--layers").map { args[args.index(after: $0)] }

// MARK: - Geometry
//
// macOS icons are an inset rounded rect on a transparent canvas; iOS icons are
// full-bleed and masked by the system. Same artwork, two framings.

let plate = macOS
    ? CGRect(x: S * 0.06, y: S * 0.06, width: S * 0.88, height: S * 0.88)
    : CGRect(x: 0, y: 0, width: S, height: S)

// Four lines, ragged like real prose rather than a uniform stack — the ragged
// right edge is what makes it read as *text* and not as a hamburger menu.
let block = CGRect(x: S * 0.235, y: S * 0.30, width: S * 0.53, height: S * 0.40)
let lineH = S * 0.052
let gap   = (block.height - lineH * 4) / 3
let cap   = lineH / 2                        // fully rounded ends

let cs = CGColorSpaceCreateDeviceRGB()

func newContext() -> CGContext {
    guard let ctx = CGContext(data: nil, width: Int(S), height: Int(S),
                              bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { fatalError("no context") }
    ctx.setAllowsAntialiasing(true)
    ctx.interpolationQuality = .high
    return ctx
}

// MARK: - Paths

/// Row 0 is the top line; CoreGraphics y grows upward. Index 2 is the live
/// line, drawn as the waveform instead.
func linePath(_ index: Int, width: CGFloat) -> CGPath {
    let y = block.maxY - lineH - CGFloat(index) * (lineH + gap)
    let r = CGRect(x: block.minX, y: y, width: block.width * width, height: lineH)
    return CGPath(roundedRect: r, cornerWidth: cap, cornerHeight: cap, transform: nil)
}

/// Bars on a shared centre line, filling the width a text line would have
/// occupied. Heights are hand-set rather than random so the silhouette is
/// stable across regenerations and reads as speech: a couple of peaks, not a
/// comb.
func wavePath() -> CGPath {
    let waveY = block.maxY - lineH - 2 * (lineH + gap) + lineH / 2
    let bars: [CGFloat] = [0.30, 0.62, 1.00, 0.78, 1.00, 0.45, 0.86, 0.34, 0.55, 0.26]
    let barW = lineH * 0.62
    let span = block.width * 0.88
    let step = (span - barW) / CGFloat(bars.count - 1)
    let maxH = lineH * 2.5

    let path = CGMutablePath()
    for (i, h) in bars.enumerated() {
        let height = max(barW, maxH * h)
        let r = CGRect(x: block.minX + CGFloat(i) * step,
                       y: waveY - height / 2, width: barW, height: height)
        path.addPath(CGPath(roundedRect: r, cornerWidth: barW / 2,
                            cornerHeight: barW / 2, transform: nil))
    }
    return path
}

// MARK: - Drawing

/// Fills a path with the component gradient. The gradient runs across the whole
/// text block rather than each shape's own bounds, so the lines share one ramp
/// instead of each restarting it.
func fill(_ ctx: CGContext, _ path: CGPath, alpha: CGFloat) {
    let (a, b) = appearance.ink
    ctx.saveGState()
    ctx.setAlpha(alpha)
    ctx.addPath(path)
    ctx.clip()
    let g = CGGradient(colorsSpace: cs, colors: [a, b] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(g,
                           start: CGPoint(x: block.minX, y: block.maxY),
                           end: CGPoint(x: block.maxX, y: block.minY),
                           options: [])
    ctx.restoreGState()
}

func drawGround(_ ctx: CGContext) {
    let (a, b) = appearance.ground
    ctx.saveGState()
    if macOS {
        let r = plate.width * 0.235   // Apple's squircle radius, near enough
        ctx.addPath(CGPath(roundedRect: plate, cornerWidth: r, cornerHeight: r, transform: nil))
        ctx.clip()
    }
    let g = CGGradient(colorsSpace: cs, colors: [a, b] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(g,
                           start: CGPoint(x: plate.minX, y: plate.maxY),
                           end: CGPoint(x: plate.maxX, y: plate.minY),
                           options: [])
    ctx.restoreGState()
}

/// The three full-opacity and muted text lines. The muted ones are the same
/// gradient at lower alpha rather than a flat grey, so they stay in the family
/// when the ground inverts.
func drawLines(_ ctx: CGContext) {
    fill(ctx, linePath(0, width: 1.00), alpha: 1.00)
    fill(ctx, linePath(1, width: 0.72), alpha: 0.62)
    fill(ctx, linePath(3, width: 0.46), alpha: 0.62)
}

func drawWave(_ ctx: CGContext) {
    fill(ctx, wavePath(), alpha: 1.00)
}

// MARK: - Write

func write(_ ctx: CGContext, to path: String) {
    guard let img = ctx.makeImage() else { fatalError("no image") }
    let rep = NSBitmapImageRep(cgImage: img)
    guard let png = rep.representation(using: .png, properties: [:]) else { fatalError("no png") }
    try! png.write(to: URL(fileURLWithPath: path))
    print("wrote \(path) (\(png.count) bytes)")
}

if let dir = layersDir {
    // Separate transparent canvases, all 1024² and in register, so Icon
    // Composer stacks them without any nudging.
    try? FileManager.default.createDirectory(atPath: dir,
                                             withIntermediateDirectories: true)
    let ground = newContext(); drawGround(ground)
    write(ground, to: "\(dir)/ground.png")

    let lines = newContext(); drawLines(lines)
    write(lines, to: "\(dir)/lines.png")

    let wave = newContext(); drawWave(wave)
    write(wave, to: "\(dir)/wave.png")
} else {
    let ctx = newContext()
    drawGround(ctx)
    drawLines(ctx)
    drawWave(ctx)
    let out = args.first(where: { $0.hasSuffix(".png") && $0 != args[0] }) ?? "icon.png"
    write(ctx, to: out)
}
