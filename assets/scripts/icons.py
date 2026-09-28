#!/usr/bin/env python3
"""Regenerates favicon, PWA icons and the header mark from the designed logo.

    python3 assets/scripts/icons.py      # from the repo root; needs Pillow

Source: priv/static/images/logo.png (transparent LX mark, designed on white).
The launcher icons are the mark on a white rounded tile with a clear margin,
the shape a macOS or Windows dock shows as it is (the full-bleed navy square
they had read as a black tile, and hid the mark's dark stroke). Where the
system masks the icon itself — Android's maskable icon, iOS's touch icon —
the white goes to the edge and the mark stays inside the safe zone.
"""
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parents[2]
STATIC = ROOT / "priv" / "static"
WHITE = (255, 255, 255, 255)
# drawn at 4x and scaled down: smooth corners and edges
SCALE = 4

src = Image.open(STATIC / "images" / "logo.png").convert("RGBA")
mark = src.crop(src.getchannel("A").getbbox())


def place(canvas: Image.Image, box: int) -> Image.Image:
    """The mark fitted inside a `box`-wide square at the canvas's centre."""
    m = mark.copy()
    m.thumbnail((box, box), Image.Resampling.LANCZOS)
    canvas.alpha_composite(m, ((canvas.width - m.width) // 2, (canvas.height - m.height) // 2))
    return canvas


def fit(size: int, pad: float, bg=None) -> Image.Image:
    """The mark alone on a square (transparent unless `bg`), `pad` of the side around it."""
    canvas = Image.new("RGBA", (size, size), bg or (0, 0, 0, 0))
    return place(canvas, int(size * (1 - 2 * pad)))


def tile(size: int) -> Image.Image:
    """A white rounded tile, 80.5% of the canvas as in Apple's icon grid, a soft
    shadow and a hairline so it holds its edge on a light dock."""
    s = size * SCALE
    side = int(s * 0.805)
    off = (s - side) // 2
    radius = int(side * 0.225)
    box = [off, off, off + side, off + side]

    canvas = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    shadow = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    drop = s // 90
    ImageDraw.Draw(shadow).rounded_rectangle([off, off + drop, off + side, off + side + drop], radius=radius, fill=(0, 0, 0, 70))
    canvas = Image.alpha_composite(canvas, shadow.filter(ImageFilter.GaussianBlur(s // 60)))

    body = Image.new("L", (s, s), 0)
    ImageDraw.Draw(body).rounded_rectangle(box, radius=radius, fill=255)
    canvas.paste(Image.new("RGBA", (s, s), WHITE), (0, 0), body)

    ring = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    ImageDraw.Draw(ring).rounded_rectangle(box, radius=radius, outline=(0, 0, 0, 22), width=max(2, s // 256))
    canvas = Image.alpha_composite(canvas, ring)

    place(canvas, int(side * 0.6))
    return canvas.resize((size, size), Image.Resampling.LANCZOS)


def full(size: int, box: float) -> Image.Image:
    """White to the edge, the mark `box` of the side wide: for a system that masks."""
    return fit(size, (1 - box) / 2, WHITE)


fit(512, 0.02).save(STATIC / "images" / "logo-mark.png")
tile(192).save(STATIC / "icons" / "icon-192.png")
tile(512).save(STATIC / "icons" / "icon-512.png")
# Android's safe zone is the centre circle of 80%: a 52% square fits inside it
full(512, 0.52).save(STATIC / "icons" / "maskable-512.png")
full(180, 0.62).convert("RGB").save(STATIC / "icons" / "apple-touch-icon.png")
fit(64, 0.06).save(STATIC / "favicon.ico", sizes=[(16, 16), (32, 32), (48, 48)])
fit(32, 0.04).save(STATIC / "favicon-32.png")
print("icons written")
