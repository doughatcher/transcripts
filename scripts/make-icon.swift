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
//   swift scripts/make-icon.swift Sources/Transcripts/Assets.xcassets/AppIcon.appiconset/icon-1024.png

let S: CGFloat = 1024

// Indigo → violet. Cool and document-ish rather than "recording red", which is
// reserved for the in-app record affordance where it actually means something.
let top    = CGColor(red: 0x4F/255, green: 0x46/255, blue: 0xE5/255, alpha: 1)
let bottom = CGColor(red: 0x7C/255, green: 0x3A/255, blue: 0xED/255, alpha: 1)
let ink    = CGColor(red: 1, green: 1, blue: 1, alpha: 1)
let muted  = CGColor(red: 1, green: 1, blue: 1, alpha: 0.62)

// macOS icons are an inset rounded rect on a transparent canvas; iOS icons are
// full-bleed and masked by the system. Same artwork, two framings.
let macOS = CommandLine.arguments.contains("--macos")

let cs = CGColorSpaceCreateDeviceRGB()
guard let ctx = CGContext(data: nil, width: Int(S), height: Int(S),
                          bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
else { fatalError("no context") }

ctx.setAllowsAntialiasing(true)
ctx.interpolationQuality = .high

// MARK: Background

let plate = macOS
    ? CGRect(x: S * 0.06, y: S * 0.06, width: S * 0.88, height: S * 0.88)
    : CGRect(x: 0, y: 0, width: S, height: S)

ctx.saveGState()
if macOS {
    let r = plate.width * 0.235   // Apple's squircle radius, near enough
    ctx.addPath(CGPath(roundedRect: plate, cornerWidth: r, cornerHeight: r, transform: nil))
    ctx.clip()
}
let grad = CGGradient(colorsSpace: cs, colors: [top, bottom] as CFArray,
                      locations: [0, 1])!
ctx.drawLinearGradient(grad,
                       start: CGPoint(x: plate.minX, y: plate.maxY),
                       end: CGPoint(x: plate.maxX, y: plate.minY),
                       options: [])
ctx.restoreGState()

// MARK: Text lines
//
// Four lines, ragged like real prose rather than a uniform stack — the ragged
// right edge is what makes it read as *text* and not as a hamburger menu.
// Widths are fractions of the text block; the third is the live one.

let block = CGRect(x: S * 0.235, y: S * 0.30, width: S * 0.53, height: S * 0.40)
let lineH = S * 0.052
let gap   = (block.height - lineH * 4) / 3
let cap   = lineH / 2                        // fully rounded ends

func line(_ index: Int, width: CGFloat, color: CGColor) {
    // Row 0 is the top line; CoreGraphics y grows upward.
    let y = block.maxY - lineH - CGFloat(index) * (lineH + gap)
    let r = CGRect(x: block.minX, y: y, width: block.width * width, height: lineH)
    ctx.addPath(CGPath(roundedRect: r, cornerWidth: cap, cornerHeight: cap, transform: nil))
    ctx.setFillColor(color)
    ctx.fillPath()
}

line(0, width: 1.00, color: ink)
line(1, width: 0.72, color: muted)
// index 2 is the waveform, below
line(3, width: 0.46, color: muted)

// MARK: The live line
//
// Bars on a shared centre line, filling the width a text line would have
// occupied. Heights are hand-set rather than random so the silhouette is stable
// across regenerations and reads as speech: a couple of peaks, not a comb.

let waveY = block.maxY - lineH - 2 * (lineH + gap) + lineH / 2
let bars: [CGFloat] = [0.30, 0.62, 1.00, 0.78, 1.00, 0.45, 0.86, 0.34, 0.55, 0.26]
let barW = lineH * 0.62
let span = block.width * 0.88
let step = (span - barW) / CGFloat(bars.count - 1)
let maxH = lineH * 2.5

for (i, h) in bars.enumerated() {
    let height = max(barW, maxH * h)
    let r = CGRect(x: block.minX + CGFloat(i) * step,
                   y: waveY - height / 2,
                   width: barW, height: height)
    ctx.addPath(CGPath(roundedRect: r, cornerWidth: barW / 2, cornerHeight: barW / 2,
                       transform: nil))
    ctx.setFillColor(ink)
    ctx.fillPath()
}

// MARK: Write

guard let img = ctx.makeImage() else { fatalError("no image") }
let rep = NSBitmapImageRep(cgImage: img)
guard let png = rep.representation(using: .png, properties: [:]) else { fatalError("no png") }
let out = CommandLine.arguments.first(where: { $0.hasSuffix(".png") }) ?? "icon.png"
try! png.write(to: URL(fileURLWithPath: out))
print("wrote \(out) (\(png.count) bytes)")
