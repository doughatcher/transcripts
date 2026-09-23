#!/usr/bin/env python3
"""Compose the Mac App Store screenshots from the guide's images.

The guide's images are shot from invented data (`just shots`), so these are
too: the same "Onboarding flow review" meeting the iPhone and iPad store shots
show. Each is one guide image on a dark field with a single line of caption, at
2880x1800 — the 16:10 size App Store Connect accepts for a Mac app.

    python3 scripts/mac-store-shots.py     # → dist/appstore/mac/

Needs Pillow. Upload with `just store-upload` alongside the iPhone and iPad sets.
"""
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parent.parent
IMAGES = ROOT / "docs" / "guide" / "images"
OUT = ROOT / "dist" / "appstore" / "mac"
W, H = 2880, 1800
FONT = "/System/Library/Fonts/SFNS.ttf"

SHOTS = [
    ("01-menu", "menu-recording.webp",
     "Lives in the menu bar, and notices when a call starts"),
    ("02-overlay", "overlay.webp",
     "Answers the question that was just asked"),
    ("03-transcript", "document-transcript.webp",
     "Every speaker named, as it happens"),
    ("04-summary", "document-summary.webp",
     "Afterwards, a summary and the action items"),
]


def field() -> Image.Image:
    """A dark vertical gradient, the colour of the site's hero."""
    top, bottom = (22, 24, 34), (12, 13, 18)
    img = Image.new("RGB", (W, H))
    px = ImageDraw.Draw(img)
    for y in range(H):
        t = y / (H - 1)
        px.line([(0, y), (W, y)], fill=tuple(round(a + (b - a) * t) for a, b in zip(top, bottom)))
    return img


def compose(src: Path, caption: str) -> Image.Image:
    img = field()
    draw = ImageDraw.Draw(img)
    font = ImageFont.truetype(FONT, 104)
    font.set_variation_by_name("Semibold")
    tw = draw.textlength(caption, font=font)
    draw.text(((W - tw) / 2, 150), caption, font=font, fill=(236, 238, 244))

    shot = Image.open(src).convert("RGBA")
    box_w, box_h = W - 400, H - 420
    scale = min(box_w / shot.width, box_h / shot.height)
    shot = shot.resize((round(shot.width * scale), round(shot.height * scale)), Image.LANCZOS)
    x = (W - shot.width) // 2
    y = 330 + (box_h - shot.height) // 2
    img.paste(shot, (x, y), shot)
    return img


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    for name, src, caption in SHOTS:
        path = OUT / f"{name}.png"
        compose(IMAGES / src, caption).save(path)
        print(f"✓ {path.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
