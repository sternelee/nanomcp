#!/usr/bin/env python3
"""Draws nanomcp's app icon, the menu bar's bolt in amber over warm charcoal,
and writes AppIcon.icns beside this file. Needs Pillow and macOS's iconutil.
Usage: python3 macos/make-icon.py"""
import os, subprocess, tempfile
from PIL import Image, ImageDraw

HERE = os.path.dirname(os.path.abspath(__file__))
S = 1024

def base():
    img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    # Apple's icon grid: an 824-point square, corners of about 185.
    box = (100, 100, 924, 924)
    mask = Image.new("L", (S, S), 0)
    ImageDraw.Draw(mask).rounded_rectangle(box, 185, fill=255)
    fill = Image.new("RGBA", (S, S))
    fd = ImageDraw.Draw(fill)
    top, bottom = (0x2a, 0x26, 0x1e), (0x16, 0x14, 0x0f)
    for y in range(S):
        t = min(1, max(0, (y - 100) / 824))
        fd.line([(0, y), (S, y)], fill=tuple(int(a + (b - a) * t) for a, b in zip(top, bottom)) + (255,))
    img.paste(fill, (0, 0), mask)
    d.rounded_rectangle(box, 185, outline=(0x3a, 0x35, 0x2b, 255), width=4)
    return img

def draw(img):
    # The bolt is SF Symbol bolt.fill's outline, scaled into the icon grid.
    shape = [(0.62, 0.04), (0.20, 0.55), (0.46, 0.55), (0.36, 0.96),
             (0.82, 0.43), (0.56, 0.43), (0.74, 0.04)]
    pts = [(100 + 824 * x, 100 + 824 * y) for x, y in shape]
    mask = Image.new("L", (S, S), 0)
    ImageDraw.Draw(mask).polygon(pts, fill=255)
    fill = Image.new("RGBA", (S, S))
    fd = ImageDraw.Draw(fill)
    top, bottom = (0xf2, 0xb8, 0x55), (0xd9, 0x8a, 0x2e)
    for y in range(S):
        t = min(1, max(0, (y - 100) / 824))
        fd.line([(0, y), (S, y)], fill=tuple(int(a + (b - a) * t) for a, b in zip(top, bottom)) + (255,))
    img.paste(fill, (0, 0), mask)

def icns(img, name):
    with tempfile.TemporaryDirectory() as tmp:
        iconset = os.path.join(tmp, "AppIcon.iconset")
        os.mkdir(iconset)
        for size in (16, 32, 128, 256, 512):
            for scale in (1, 2):
                px = size * scale
                suffix = "" if scale == 1 else "@2x"
                img.resize((px, px), Image.LANCZOS).save(os.path.join(iconset, f"icon_{size}x{size}{suffix}.png"))
        subprocess.run(["iconutil", "-c", "icns", iconset, "-o", os.path.join(HERE, name)], check=True)

if __name__ == "__main__":
    img = base()
    draw(img)
    img.save(os.path.join(tempfile.gettempdir(), "nanomcp-icon.png"))
    icns(img, "AppIcon.icns")
