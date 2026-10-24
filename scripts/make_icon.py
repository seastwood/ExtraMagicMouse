#!/usr/bin/env python3
"""Draws the Extra Magic Mouse app icon.

A graphite Magic Mouse, seen from above, on a full-bleed graphite background,
with a gold four-way arrow on its touch surface: push your fingers and it pans.
Same look as MainMic and Extra Mission Controls: dark graphite, grey surfaces lit
from the top, and one mark in metallic gold.

Writes Resources/AppIcon.icns (the app) and Resources/AppIcon.png (the README,
with the macOS rounded shape baked in, since GitHub shows the file as-is).

    pip install pillow
    python3 scripts/make_icon.py
"""
import math
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parent.parent
S = 4                     # supersampling factor
N = 1024 * S              # canvas, designed on a 1024 grid

# The mouse body: a stadium (pill), taller than wide, centred.
MOUSE_W, MOUSE_H = 440, 740
MOUSE_Y = 512             # centre
# The arrow: four chevrons around a centre dot, on the mouse's upper half where
# your fingers rest.
ARROW_CY = 420            # centre of the arrow
ARROW_REACH = 150         # centre to the tip of each chevron
CHEVRON = 58              # length of each chevron arm, tip to end
STROKE = 46               # line weight, as in Extra Mission Controls' letters
DOT = 30                  # radius of the centre dot (the touch)
GOLD = ((255, 230, 150), (196, 128, 26))   # light at the top, deep at the foot


def lerp(a, b, t):
    return tuple(round(x + (y - x) * t) for x, y in zip(a, b))


def grad_span(c1, c2, a, b):
    """c1 -> c2 from y=a to y=b (1024 grid), flat outside."""
    g = Image.new("RGBA", (1, 1024))
    for i in range(1024):
        t = min(1.0, max(0.0, (i - a) / (b - a)))
        g.putpixel((0, i), lerp(c1, c2, t) + (255,))
    return g.resize((N, N), Image.BICUBIC)


def diagonal(c1, c2):
    """Top-left -> bottom-right gradient."""
    small = Image.new("RGBA", (256, 256))
    px = small.load()
    for y in range(256):
        for x in range(256):
            px[x, y] = lerp(c1, c2, (x + y) / 510) + (255,)
    return small.resize((N, N), Image.BICUBIC)


def mask(draw_fn):
    m = Image.new("L", (N, N), 0)
    draw_fn(ImageDraw.Draw(m))
    return m


def shadow(img, m, dy, blur, alpha):
    sh = Image.new("RGBA", (N, N), (0, 0, 0, 0))
    sh.putalpha(m.point(lambda v: v * alpha // 255))
    sh = sh.transform((N, N), Image.AFFINE, (1, 0, 0, 0, 1, -dy * S))
    img.alpha_composite(sh.filter(ImageFilter.GaussianBlur(blur * S)))


def capsule(d, start, end, r):
    (x1, y1), (x2, y2) = [(x * S, y * S) for x, y in (start, end)]
    r *= S
    length = math.hypot(x2 - x1, y2 - y1)
    nx, ny = -(y2 - y1) / length * r, (x2 - x1) / length * r
    d.polygon([(x1 + nx, y1 + ny), (x2 + nx, y2 + ny), (x2 - nx, y2 - ny), (x1 - nx, y1 - ny)], fill=255)
    for x, y in ((x1, y1), (x2, y2)):
        d.ellipse([x - r, y - r, x + r, y + r], fill=255)


def draw_arrow(d):
    cx, cy = 512, ARROW_CY
    arm = CHEVRON / math.sqrt(2)
    for dx, dy in ((0, -1), (0, 1), (-1, 0), (1, 0)):
        tip = (cx + dx * ARROW_REACH, cy + dy * ARROW_REACH)
        # The chevron's two arms run back from the tip at 45° either side.
        px, py = -dy, dx  # perpendicular
        for side in (1, -1):
            end = (tip[0] - dx * arm + side * px * arm, tip[1] - dy * arm + side * py * arm)
            capsule(d, tip, end, STROKE / 2)
    d.ellipse([(cx - DOT) * S, (cy - DOT) * S, (cx + DOT) * S, (cy + DOT) * S], fill=255)


def draw_icon():
    # Full-bleed: macOS 26 applies its own rounded-square mask to app icons, and
    # shrinks artwork that has its own rounded body onto a grey plate.
    img = diagonal((62, 63, 70), (16, 16, 20))

    # The mouse: solid grey lit from the top, a soft shadow and a light top edge.
    x1, y1 = 512 - MOUSE_W / 2, MOUSE_Y - MOUSE_H / 2
    x2, y2 = x1 + MOUSE_W, y1 + MOUSE_H
    body = mask(lambda d: d.rounded_rectangle([x1 * S, y1 * S, x2 * S, y2 * S], radius=MOUSE_W / 2 * S, fill=255))
    shadow(img, body, dy=16, blur=22, alpha=130)
    surface = Image.new("RGBA", (N, N), (0, 0, 0, 0))
    surface.paste(grad_span((92, 92, 100), (52, 52, 59), y1, y2), (0, 0), body)
    img.alpha_composite(surface)
    edge = Image.new("RGBA", (N, N), (0, 0, 0, 0))
    ImageDraw.Draw(edge).rounded_rectangle(
        [(x1 + 2) * S, (y1 + 2) * S, (x2 - 2) * S, (y2 - 2) * S], radius=(MOUSE_W / 2 - 2) * S,
        outline=(255, 255, 255, 70), width=3 * S)
    fade = mask(lambda d: d.rectangle([x1 * S, y1 * S, x2 * S, (y1 + 160) * S], fill=255))
    edge.putalpha(ImageChops.multiply(edge.getchannel("A"), fade.filter(ImageFilter.GaussianBlur(40 * S))))
    img.alpha_composite(edge)

    # The gold arrow, with a drop shadow, a faint glow and a sheen on its top half.
    arrow = mask(draw_arrow)
    top, bottom = ARROW_CY - ARROW_REACH - STROKE / 2, ARROW_CY + ARROW_REACH + STROKE / 2
    shadow(img, arrow, dy=8, blur=10, alpha=140)
    glow = Image.new("RGBA", (N, N), (230, 170, 50, 0))
    glow.putalpha(arrow.point(lambda v: v * 70 // 255))
    img.alpha_composite(glow.filter(ImageFilter.GaussianBlur(24 * S)))
    gold = Image.new("RGBA", (N, N), (0, 0, 0, 0))
    gold.paste(grad_span(*GOLD, top, bottom), (0, 0), arrow)
    img.alpha_composite(gold)
    sheen = Image.new("RGBA", (N, N), (255, 255, 255, 0))
    upper = mask(lambda d: d.rectangle([0, top * S, N, ARROW_CY * S], fill=60))
    sheen.putalpha(ImageChops.multiply(arrow, upper.filter(ImageFilter.GaussianBlur(30 * S))))
    img.alpha_composite(sheen)

    return img.resize((1024, 1024), Image.LANCZOS)


def squircle_mask(size, k=4):
    """macOS's app-icon shape: a superellipse (|x|^5 + |y|^5 = 1)."""
    n = size * k
    small = Image.new("L", (n, n), 0)
    px = small.load()
    half = n / 2.0
    for y in range(n):
        dy = abs((y + 0.5 - half) / half) ** 5
        if dy >= 1.0:
            continue
        span = (1.0 - dy) ** 0.2 * half
        for x in range(max(0, int(round(half - span))), min(n, int(round(half + span)))):
            px[x, y] = 255
    return small.resize((size, size), Image.LANCZOS)


if __name__ == "__main__":
    icon = draw_icon()
    icon.save(ROOT / "Resources" / "AppIcon.icns",
              sizes=[(16, 16), (32, 32), (64, 64), (128, 128), (256, 256), (512, 512), (1024, 1024)])
    rounded = Image.new("RGBA", icon.size, (0, 0, 0, 0))
    rounded.paste(icon, (0, 0), squircle_mask(icon.size[0]))
    rounded.resize((256, 256), Image.LANCZOS).save(ROOT / "Resources" / "AppIcon.png")
    print("Wrote Resources/AppIcon.icns and Resources/AppIcon.png")
