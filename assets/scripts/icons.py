#!/usr/bin/env python3
"""Regenerates favicon, PWA icons and the header mark from the designed logo.

    python3 assets/scripts/icons.py      # from the repo root; needs Pillow

Source: priv/static/images/logo.png (transparent LX mark). Launcher icons
sit on the navy from the mark's dark stroke so the blue reads anywhere.
"""
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parents[2]
STATIC = ROOT / "priv" / "static"
NAVY = (11, 18, 32, 255)

src = Image.open(STATIC / "images" / "logo.png").convert("RGBA")
mark = src.crop(src.getchannel("A").getbbox())


def fit(size: int, pad: float, bg=None) -> Image.Image:
    canvas = Image.new("RGBA", (size, size), bg or (0, 0, 0, 0))
    m = mark.copy()
    inner = int(size * (1 - 2 * pad))
    m.thumbnail((inner, inner), Image.LANCZOS)
    canvas.alpha_composite(m, ((size - m.width) // 2, (size - m.height) // 2))
    return canvas


fit(512, 0.02).save(STATIC / "images" / "logo-mark.png")
fit(192, 0.14, NAVY).save(STATIC / "icons" / "icon-192.png")
fit(512, 0.14, NAVY).save(STATIC / "icons" / "icon-512.png")
fit(512, 0.22, NAVY).save(STATIC / "icons" / "maskable-512.png")
fit(180, 0.14, NAVY).convert("RGB").save(STATIC / "icons" / "apple-touch-icon.png")
fit(64, 0.06).save(STATIC / "favicon.ico", sizes=[(16, 16), (32, 32), (48, 48)])
fit(32, 0.04).save(STATIC / "favicon-32.png")
print("icons written")
