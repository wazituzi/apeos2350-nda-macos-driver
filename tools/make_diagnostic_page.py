#!/usr/bin/env python3
"""Build a real A4 diagnostic test page for the Apeos 2350 NDA driver.

The previous test page was plain text run through cgtexttopdf, so every line
came out at the same size and the "1 pt line" was really a row of underscore
glyphs.  This one is drawn explicitly:

  * real rules of 0.5 / 1 / 2 / 4 pt, so line reproduction is measurable
  * real type at 6 / 8 / 10 / 12 / 18 / 24 / 36 pt, Chinese and Latin
  * a smooth 0-100% gradient plus 11 discrete steps, to judge halftoning
  * a radial gradient (photo-like) and fine checkerboards

Usage:  python3 make_diagnostic_page.py out.pdf
"""
import sys
from PIL import Image, ImageDraw, ImageFont

DPI = 600
W, H = 4960, 7016                      # A4 at 600 dpi
MM = DPI / 25.4                        # pixels per millimetre
OUT = sys.argv[1] if len(sys.argv) > 1 else "diagnostic.pdf"

CJK_CANDIDATES = [
    "/System/Library/Fonts/Supplemental/Arial Unicode.ttf",
    "/System/Library/Fonts/PingFang.ttc",
    "/System/Library/Fonts/STHeiti Medium.ttc",
    "/System/Library/Fonts/Hiragino Sans GB.ttc",
]
LATIN_CANDIDATES = [
    "/System/Library/Fonts/Supplemental/Arial.ttf",
    "/System/Library/Fonts/Helvetica.ttc",
]


def load(candidates, size):
    for path in candidates:
        try:
            return ImageFont.truetype(path, size)
        except OSError:
            continue
    return ImageFont.load_default()


def pt(size):
    """Point size -> pixels at this DPI."""
    return max(1, int(round(size * DPI / 72.0)))


cjk = lambda s: load(CJK_CANDIDATES, pt(s))      # noqa: E731
latin = lambda s: load(LATIN_CANDIDATES, pt(s))  # noqa: E731

img = Image.new("L", (W, H), 255)
d = ImageDraw.Draw(img)

M = int(8 * MM)             # 8 mm page margin
y = M

d.text((M, y), "Apeos 2350 NDA 打印驱动诊断页", font=cjk(20), fill=0)
y += pt(20) + int(2 * MM)
d.text((M, y), "FUJIFILM Apeos 2350 NDA - driver diagnostic page", font=latin(13), fill=0)
y += pt(13) + int(6 * MM)

# --- 1. real rules --------------------------------------------------------
d.text((M, y), "1. 线条还原 / Line reproduction (real rules)", font=cjk(11), fill=0)
y += pt(11) + int(2 * MM)
for size_pt, expect_px in ((0.5, 4), (1, 8), (2, 17), (4, 33)):
    px = max(1, int(round(size_pt * DPI / 72.0)))
    d.line([M, y, W - M, y], fill=0, width=px)
    d.text((W - M - int(54 * MM), y - pt(9) - px), "%g pt = %d px" % (size_pt, expect_px),
           font=latin(9), fill=0)
    y += max(px, 2) + int(5 * MM)

y += int(2 * MM)

# --- 2. real type sizes ---------------------------------------------------
d.text((M, y), "2. 字号 / Type sizes (each line is really that size)", font=cjk(11), fill=0)
y += pt(11) + int(3 * MM)
for size_pt in (6, 8, 10, 12, 18, 24, 36):
    label = "%2d pt" % size_pt
    d.text((M, y), label, font=latin(9), fill=0)
    d.text((M + int(16 * MM), y - pt(2)),
           "敏捷的棕色狐狸 0123456789 Apeos", font=cjk(size_pt), fill=0)
    y += pt(size_pt) + int(3.5 * MM)

y += int(2 * MM)

# --- 3. halftoning --------------------------------------------------------
d.text((M, y), "3. 加网 / Halftoning: 平滑渐变 + 11 级灰阶", font=cjk(11), fill=0)
y += pt(11) + int(2 * MM)

grad_h = int(14 * MM)
for x in range(M, W - M):
    v = int(255 * (x - M) / float(W - 2 * M))
    d.line([x, y, x, y + grad_h], fill=255 - v)
y += grad_h + int(3 * MM)

step_h = int(14 * MM)
n = 11
step_w = (W - 2 * M) // n
for i in range(n):
    g = int(255 * i / float(n - 1))
    d.rectangle([M + i * step_w, y, M + (i + 1) * step_w - 2, y + step_h], fill=255 - g)
y += step_h + int(1.5 * MM)
for i in range(n):
    d.text((M + i * step_w + 2, y), "%d%%" % int(100 * i / float(n - 1)),
           font=latin(7), fill=0)
y += pt(7) + int(5 * MM)

# --- 4. detail ------------------------------------------------------------
d.text((M, y), "4. 分辨率极限 / Resolution limit", font=cjk(11), fill=0)
y += pt(11) + int(2 * MM)

# Checkerboard pitch swept from far below to well above the halftone cell,
# so the resolution limit of 1-bit output is visible on the paper itself.
pitches = [2, 4, 8, 16, 32]
cell = int(17 * MM)
gap = int(3 * MM)
for i, pitch in enumerate(pitches):
    x0 = M + i * (cell + gap)
    for yy in range(y, y + cell, pitch):
        for xx in range(x0, x0 + cell, pitch):
            if ((xx // pitch) + (yy // pitch)) % 2 == 0:
                d.rectangle([xx, yy, xx + pitch - 1, yy + pitch - 1], fill=0)
    d.text((x0, y + cell + int(1 * MM)), "%dx%d px" % (pitch, pitch), font=latin(7), fill=0)
    d.text((x0, y + cell + int(1 * MM) + pt(8)),
           "%.2f mm" % (pitch / DPI * 25.4), font=latin(7), fill=0)
y += cell + pt(8) + int(9 * MM)

# Rings whose pitch is comfortably above one halftone cell -> must survive.
cy = y + int(14 * MM)
cx = M + int(14 * MM)
for r in range(8, int(14 * MM), 16):
    d.ellipse([cx - r, cy - r, cx + r, cy + r], outline=0, width=3)
d.text((M + int(34 * MM), cy - int(7 * MM)),
       "同心圆：线宽 3px，环间距 16px（0.68 mm）", font=cjk(9), fill=0)
d.text((M + int(34 * MM), cy + int(0 * MM)),
       "环间距大于一个加网单元，所以能完整还原。", font=cjk(9), fill=0)
d.text((M + int(34 * MM), cy + int(7 * MM)),
       "上面 2px / 4px 的棋盘格会糊成灰块：1-bit 加网用空间", font=cjk(9), fill=0)
d.text((M + int(34 * MM), cy + int(14 * MM)),
       "分辨率换灰阶层次，周期小于加网单元时只能还原「等效灰度」。", font=cjk(9), fill=0)
y += int(32 * MM)

d.text((M, y), "生成链 / chain: PDF -> cgpdftoraster -> CUPS raster -> rastertohbpl -> HBPL -> 9100",
       font=cjk(9), fill=0)

img.save(OUT, "PDF", resolution=DPI)
print("wrote %s  (%dx%d at %d dpi, page %.1f x %.1f mm)"
      % (OUT, W, H, DPI, W / MM, H / MM))
