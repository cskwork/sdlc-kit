#!/usr/bin/env python3
"""Draws the app icon: the tray glyph (a rounded check box) in white on an accent tile.

Run on macOS with Pillow: python3 todo/app/icon.py. It writes AppIcon.icns, which install-macos.sh
copies into the bundle, and AppIcon.png, which the app sets as its window and Dock icon at runtime
(without it eframe shows its own default icon over the bundle's).
"""
import pathlib
import subprocess
import tempfile

from PIL import Image, ImageDraw

HERE = pathlib.Path(__file__).resolve().parent
TOP, BOTTOM = (124, 122, 240), (79, 77, 214)  # accent 0x5e5ce6, lighter at the top
SCALE = 4  # draw large, then downsample for smooth edges


def master(size=1024):
    s = size * SCALE
    tile = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    # macOS icon grid: an 824/1024 body with a 185/1024 corner radius.
    inset, radius = s * 100 // 1024, s * 185 // 1024
    gradient = Image.new("RGBA", (s, s))
    for y in range(s):
        t = y / (s - 1)
        row = tuple(round(a + (b - a) * t) for a, b in zip(TOP, BOTTOM)) + (255,)
        gradient.paste(row, (0, y, s, y + 1))
    mask = Image.new("L", (s, s), 0)
    ImageDraw.Draw(mask).rounded_rectangle((inset, inset, s - inset, s - inset), radius, fill=255)
    tile.paste(gradient, (0, 0), mask)
    # The tray glyph on its 32-unit grid: box 5..27 radius 6, check 11,16.5 → 14.5,20 → 21,12.
    draw = ImageDraw.Draw(tile)
    u = (s - 2 * inset) / 32 * 0.78
    off = s / 2 - 16 * u
    p = lambda x, y: (off + x * u, off + y * u)
    width = round(2.8 * u)
    draw.rounded_rectangle((*p(5, 5), *p(27, 27)), round(6 * u), outline="white", width=width)
    draw.line([p(11, 16.5), p(14.5, 20), p(21, 12)], fill="white", width=width, joint="curve")
    for x, y in ((11, 16.5), (14.5, 20), (21, 12)):
        cx, cy = p(x, y)
        draw.ellipse((cx - width / 2, cy - width / 2, cx + width / 2, cy + width / 2), fill="white")
    return tile.resize((size, size), Image.Resampling.LANCZOS)


def main():
    art = master()
    art.resize((256, 256), Image.Resampling.LANCZOS).save(HERE / "AppIcon.png")
    with tempfile.TemporaryDirectory() as tmp:
        iconset = pathlib.Path(tmp, "AppIcon.iconset")
        iconset.mkdir()
        for base in (16, 32, 128, 256, 512):
            for factor, suffix in ((1, ""), (2, "@2x")):
                art.resize((base * factor,) * 2, Image.Resampling.LANCZOS).save(iconset / f"icon_{base}x{base}{suffix}.png")
        subprocess.run(["iconutil", "-c", "icns", str(iconset), "-o", str(HERE / "AppIcon.icns")], check=True)
    print(HERE / "AppIcon.icns", HERE / "AppIcon.png")


if __name__ == "__main__":
    main()
