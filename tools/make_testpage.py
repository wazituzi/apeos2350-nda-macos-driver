#!/usr/bin/env python3
"""Render an A4 @ 600 dpi 1-bit PBM (pbmraw / P4) test page.

foo2hbpl2 consumes pbmraw on stdin; this produces it without needing
Ghostscript, so the HBPL encoder can be exercised standalone.
"""
import sys
from PIL import Image, ImageDraw, ImageFont

W, H = 4960, 7016          # A4 at 600 dpi (210 x 297 mm)
OUT = sys.argv[1] if len(sys.argv) > 1 else "testpage.pbm"

FONTS = [
    "/System/Library/Fonts/Supplemental/Arial Bold.ttf",
    "/System/Library/Fonts/Supplemental/Arial.ttf",
    "/System/Library/Fonts/Helvetica.ttc",
    "/System/Library/Fonts/Supplemental/Verdana.ttf",
]


def font(size, bold=False):
    for path in (FONTS if bold else FONTS[1:]):
        try:
            return ImageFont.truetype(path, size)
        except OSError:
            continue
    return ImageFont.load_default()


img = Image.new("1", (W, H), 1)          # 1 = white
d = ImageDraw.Draw(img)

# Frame, so page geometry / margins are obvious on paper.
d.rectangle([200, 200, W - 200, H - 200], outline=0, width=12)
d.line([200, 700, W - 200, 700], fill=0, width=8)

d.text((320, 300), "HBPL TEST PAGE", font=font(160, True), fill=0)
d.text((320, 760), "FUJIFILM Apeos 2350 NDA", font=font(110, True), fill=0)
d.text((320, 920), "600 dpi  |  monochrome  |  A4", font=font(80), fill=0)

body = [
    "If you can read this on paper, the device speaks HBPL v2",
    "and the open-source foo2hbpl2 encoder is compatible.",
    "",
    "Generated on macOS without Ghostscript:",
    "  PDF -> cgpdftoraster -> CUPS raster -> pbmraw -> HBPL",
    "",
    "Line / glyph test:",
    "  1 px hairline, 8 pt, 10 pt, 12 pt, 18 pt, 24 pt text",
]
y = 1150
for line in body:
    d.text((320, y), line, font=font(64), fill=0)
    y += 110

# Hairlines at 1/2/4 px: reveals resolution and dot gain.
for i, wdt in enumerate((1, 2, 4)):
    d.line([320, y + 40 + i * 60, W - 320, y + 40 + i * 60], fill=0, width=wdt)
d.text((320, y + 240), "1 px / 2 px / 4 px hairlines above", font=font(56), fill=0)

# Solid block + 50% checker: reveals compression and dithering problems.
d.rectangle([320, y + 360, 1320, y + 1160], fill=0)
for yy in range(y + 360, y + 1160, 16):
    for xx in range(1420, 2420, 16):
        d.rectangle([xx, yy, xx + 7, yy + 7], fill=0)
d.text((320, y + 1220), "solid black block   |   50% checkerboard", font=font(56), fill=0)
d.text((320, y + 1340), "END OF TEST PAGE", font=font(72, True), fill=0)

img.save(OUT)
print("wrote %s  (%dx%d, mode %s)" % (OUT, img.width, img.height, img.mode))
