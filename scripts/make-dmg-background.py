#!/usr/bin/env python3
"""Draw the disk image's Finder background: dark, the Transcripts violet, an
arrow from the app to Applications, and one line saying what to do.

The window is 660x420 points. Finder draws the two icons itself, at the
positions in dmg-settings.py; this only draws what goes behind and between them.
Rendered at 1x and 2x and combined into one TIFF, which is how Finder picks the
sharp one on a Retina screen.

    python3 scripts/make-dmg-background.py    # → scripts/dmg/background.tiff

Needs Pillow. The TIFF is committed, so a release does not.
"""
import subprocess
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont

OUT = Path(__file__).resolve().parent / "dmg"
W, H = 660, 420
APP_X, APPS_X, ICON_Y = 180, 480, 190     # must match dmg-settings.py
FONT = "/System/Library/Fonts/SFNS.ttf"


def draw(scale: int) -> Image.Image:
    w, h = W * scale, H * scale
    img = Image.new("RGB", (w, h), (16, 16, 20))

    # A soft violet glow behind the app icon, the homepage's aura at rest.
    glow = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    g = ImageDraw.Draw(glow)
    r = 150 * scale
    g.ellipse((APP_X * scale - r, ICON_Y * scale - r, APP_X * scale + r, ICON_Y * scale + r),
              fill=(124, 108, 246, 70))
    glow = glow.filter(ImageFilter.GaussianBlur(70 * scale))
    img = Image.alpha_composite(img.convert("RGBA"), glow)

    d = ImageDraw.Draw(img)
    # The arrow: a dotted shaft and a chevron, in the accent, between the icons.
    y = ICON_Y * scale
    x0, x1 = (APP_X + 78) * scale, (APPS_X - 78) * scale
    dot = 5 * scale
    x = x0
    while x < x1 - 22 * scale:
        d.ellipse((x - dot / 2, y - dot / 2, x + dot / 2, y + dot / 2), fill=(139, 124, 246, 255))
        x += 14 * scale
    c = 14 * scale
    d.line([(x1 - c, y - c), (x1, y), (x1 - c, y + c)], fill=(139, 124, 246, 255),
           width=int(4 * scale), joint="curve")

    font = ImageFont.truetype(FONT, 17 * scale)
    font.set_variation_by_name("Medium")
    text = "Drag Transcripts to Applications"
    tw = d.textlength(text, font=font)
    d.text(((w - tw) / 2, 318 * scale), text, font=font, fill=(236, 236, 241, 255))

    small = ImageFont.truetype(FONT, 12 * scale)
    note = "Signed and notarized by Apple"
    nw = d.textlength(note, font=small)
    d.text(((w - nw) / 2, 346 * scale), note, font=small, fill=(154, 154, 168, 255))
    return img.convert("RGB")


def main() -> None:
    OUT.mkdir(exist_ok=True)
    one, two = OUT / "background.png", OUT / "background@2x.png"
    draw(1).save(one)
    draw(2).save(two)
    subprocess.run(["tiffutil", "-cathidpicheck", str(one), str(two),
                    "-out", str(OUT / "background.tiff")], check=True, capture_output=True)
    one.unlink()
    two.unlink()
    print(f"✓ {OUT / 'background.tiff'}")


if __name__ == "__main__":
    main()
