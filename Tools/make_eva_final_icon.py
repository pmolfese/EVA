#!/usr/bin/env python3
from pathlib import Path
import math

from PIL import Image, ImageDraw, ImageFilter, ImageFont


ROOT = Path(__file__).resolve().parents[1]
OUT_DIR = ROOT / "icons"
PNG_OUT = OUT_DIR / "eva-final-logo.png"
SVG_OUT = OUT_DIR / "eva-final-logo.svg"

SIZE = 2048
BLACK = "#000000"
ORANGE = "#ff5a05"
GREEN = "#18dc25"
DARK_GREEN = "#0b7a16"
LIGHT_GREEN = "#87ff61"
FONT_PATH = "/System/Library/Fonts/Supplemental/Arial Rounded Bold.ttf"


def cubic(p0, p1, p2, p3, steps=80):
    pts = []
    for i in range(steps + 1):
        t = i / steps
        mt = 1 - t
        x = (
            mt**3 * p0[0]
            + 3 * mt**2 * t * p1[0]
            + 3 * mt * t**2 * p2[0]
            + t**3 * p3[0]
        )
        y = (
            mt**3 * p0[1]
            + 3 * mt**2 * t * p1[1]
            + 3 * mt * t**2 * p2[1]
            + t**3 * p3[1]
        )
        pts.append((x, y))
    return pts


def draw_polyline(draw, pts, fill, width, joint="curve"):
    draw.line(pts, fill=fill, width=width, joint=joint)
    r = width // 2
    for x, y in (pts[0], pts[-1]):
        draw.ellipse((x - r, y - r, x + r, y + r), fill=fill)


def draw_glow_line(base, pts, color, width):
    glow = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    gd = ImageDraw.Draw(glow)
    draw_polyline(gd, pts, color, width + 18)
    glow = glow.filter(ImageFilter.GaussianBlur(16))
    base.alpha_composite(glow)
    draw = ImageDraw.Draw(base)
    draw_polyline(draw, pts, color, width)


def draw_brain(draw, cx, cy, scale=1.0):
    # Compact cortical-surface accent: glossy green folded strokes, not a second signal line.
    w = 440 * scale
    h = 235 * scale
    x0 = cx - w / 2
    y0 = cy - h / 2
    x1 = cx + w / 2
    y1 = cy + h / 2

    shadow = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    sd = ImageDraw.Draw(shadow)
    sd.ellipse((x0 + 10, y0 + 18, x1 + 10, y1 + 28), fill=(0, 0, 0, 130))
    shadow = shadow.filter(ImageFilter.GaussianBlur(18))
    img.alpha_composite(shadow)

    draw.ellipse((x0, y0, x1, y1), fill="#24c82d", outline="#0d8f18", width=int(10 * scale))
    draw.ellipse((x0 + 30 * scale, y0 + 18 * scale, x1 - 18 * scale, y1 - 55 * scale), fill="#5df447")

    folds = [
        [(x0 + 55 * scale, y0 + 105 * scale), (x0 + 120 * scale, y0 + 45 * scale), (x0 + 210 * scale, y0 + 78 * scale)],
        [(x0 + 84 * scale, y0 + 145 * scale), (x0 + 170 * scale, y0 + 108 * scale), (x0 + 250 * scale, y0 + 136 * scale)],
        [(x0 + 162 * scale, y0 + 52 * scale), (x0 + 230 * scale, y0 + 18 * scale), (x0 + 300 * scale, y0 + 52 * scale)],
        [(x0 + 245 * scale, y0 + 95 * scale), (x0 + 323 * scale, y0 + 45 * scale), (x0 + 382 * scale, y0 + 88 * scale)],
        [(x0 + 270 * scale, y0 + 154 * scale), (x0 + 350 * scale, y0 + 128 * scale), (x0 + 410 * scale, y0 + 160 * scale)],
        [(x0 + 95 * scale, y0 + 188 * scale), (x0 + 190 * scale, y0 + 172 * scale), (x0 + 285 * scale, y0 + 204 * scale)],
    ]
    for pts in folds:
        draw.line(pts, fill=DARK_GREEN, width=int(24 * scale), joint="curve")
        draw.line(pts, fill=LIGHT_GREEN, width=int(10 * scale), joint="curve")


OUT_DIR.mkdir(exist_ok=True)
img = Image.new("RGBA", (SIZE, SIZE), BLACK)
draw = ImageDraw.Draw(img)

font = ImageFont.truetype(FONT_PATH, 575)
text = "EVA"
bbox = draw.textbbox((0, 0), text, font=font)
text_w = bbox[2] - bbox[0]
text_h = bbox[3] - bbox[1]
text_x = (SIZE - text_w) / 2
text_y = 780

# Soft orange depth behind the wordmark.
shadow = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
sd = ImageDraw.Draw(shadow)
sd.text((text_x + 20, text_y + 24), text, font=font, fill=(255, 86, 5, 70))
shadow = shadow.filter(ImageFilter.GaussianBlur(18))
img.alpha_composite(shadow)
draw.text((text_x, text_y), text, font=font, fill=ORANGE)

# One continuous signal path. The descent into the V is a straight inset path
# parallel to the V wall; the ascent mirrors the already-good spacing.
signal = []
signal += [(185, 806), (475, 806)]
signal += cubic((475, 806), (545, 806), (555, 635), (625, 635), 40)[1:]
signal += cubic((625, 635), (686, 635), (674, 845), (748, 840), 45)[1:]
signal += cubic((748, 840), (812, 835), (790, 500), (875, 500), 55)[1:]
signal += cubic((875, 500), (948, 500), (920, 775), (1012, 888), 50)[1:]

# Constant-inset V trace: left descent, rounded trough, and right ascent.
left_top = (1012, 888)
left_bottom = (1092, 1168)
trough_left = (1118, 1218)
trough_right = (1198, 1218)
right_top = (1316, 888)
signal += [left_bottom]
signal += cubic(left_bottom, (1099, 1193), (1108, 1208), trough_left, 18)[1:]
signal += cubic(trough_left, (1140, 1237), (1176, 1237), trough_right, 26)[1:]
signal += cubic(trough_right, (1240, 1186), (1273, 974), right_top, 42)[1:]
signal += cubic(right_top, (1354, 806), (1374, 852), (1458, 852), 30)[1:]
signal += [(1870, 852)]

draw_glow_line(img, signal, GREEN, 15)
draw = ImageDraw.Draw(img)
draw_brain(draw, 1582, 600, 0.86)

img.convert("RGB").save(PNG_OUT, quality=95)

svg_path = " ".join(
    [f"M {signal[0][0]:.1f} {signal[0][1]:.1f}"]
    + [f"L {x:.1f} {y:.1f}" for x, y in signal[1:]]
)
SVG_OUT.write_text(
    f'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {SIZE} {SIZE}">
  <rect width="{SIZE}" height="{SIZE}" fill="{BLACK}"/>
  <text x="{text_x:.1f}" y="{text_y - bbox[1]:.1f}" font-family="Arial Rounded MT Bold, Arial Rounded Bold, Arial, sans-serif" font-size="575" font-weight="700" fill="{ORANGE}">EVA</text>
  <path d="{svg_path}" fill="none" stroke="{GREEN}" stroke-width="15" stroke-linecap="round" stroke-linejoin="round"/>
  <g transform="translate(1582 600) scale(.86)">
    <ellipse cx="0" cy="0" rx="220" ry="118" fill="#24c82d" stroke="#0d8f18" stroke-width="10"/>
    <path d="M-165 0 C-100 -60 -10 -27 45 -18 M-136 40 C-50 3 30 31 88 26 M-58 -54 C10 -88 80 -54 140 -50 M25 -10 C103 -60 162 -17 200 -12 M50 50 C130 24 190 56 220 55 M-125 83 C-30 67 65 99 130 90" fill="none" stroke="{DARK_GREEN}" stroke-width="24" stroke-linecap="round"/>
    <path d="M-165 0 C-100 -60 -10 -27 45 -18 M-136 40 C-50 3 30 31 88 26 M-58 -54 C10 -88 80 -54 140 -50 M25 -10 C103 -60 162 -17 200 -12 M50 50 C130 24 190 56 220 55 M-125 83 C-30 67 65 99 130 90" fill="none" stroke="{LIGHT_GREEN}" stroke-width="10" stroke-linecap="round"/>
  </g>
</svg>
''',
    encoding="utf-8",
)

print(PNG_OUT)
print(SVG_OUT)
