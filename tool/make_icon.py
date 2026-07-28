#!/usr/bin/env python3
"""Generates the DroidDeck app icon: a command-deck motif on a dark rounded
square.

    python3 tool/make_icon.py [--sizes 16,32,48,64,128,256,512,1024]
                               [--out-dir assets/icon]

Design (flat, no text):
  - 1024x1024 rounded square (corner radius ~180 at that scale), background
    a dark charcoal-green (#10140f) with a subtle radial darkening toward
    the edges (the only "gradient" — everything else is flat fill).
  - Centered android-green (#3DDC84) terminal chevron '>' plus a short
    horizontal cursor underscore, evoking a command prompt ("command deck").
  - A thin green arc across the top, hinting at the Android antenna/signal
    without drawing the bugdroid mascot.

Renders at a supersampled resolution and downsamples with LANCZOS so edges
and the arc/chevron strokes stay smooth at every exported size. Requires
Pillow (this repo has been verified against 10.2.0).
"""

from __future__ import annotations

import argparse
from pathlib import Path

from PIL import Image, ImageDraw

BG = (16, 20, 15, 255)  # #10140f
GREEN = (61, 220, 132, 255)  # #3DDC84
TRANSPARENT = (0, 0, 0, 0)

BASE = 1024  # design canvas the geometry below is tuned for
RADIUS = 180  # corner radius at BASE scale
SS = 8  # supersample factor — draw big, downscale for antialiasing


def _s(v: float, scale: int) -> float:
    """Scales a BASE-relative measurement into the supersampled canvas."""
    return v * scale / BASE


def rounded_mask(size: int, radius: float) -> Image.Image:
    mask = Image.new("L", (size, size), 0)
    d = ImageDraw.Draw(mask)
    d.rounded_rectangle([0, 0, size - 1, size - 1], radius=radius, fill=255)
    return mask


def vignette(size: int, strength: int = 120) -> Image.Image:
    """A soft radial-darkening mask: 0 near the centre, rising toward the
    corners. Computed on a coarse grid and upscaled — the falloff is smooth
    enough that this is indistinguishable from a per-pixel computation."""
    grid = 128
    small = Image.new("L", (grid, grid), 0)
    px = small.load()
    cx = cy = (grid - 1) / 2
    max_d = (cx**2 + cy**2) ** 0.5
    for y in range(grid):
        for x in range(grid):
            d = ((x - cx) ** 2 + (y - cy) ** 2) ** 0.5 / max_d
            t = max(0.0, (d - 0.30) / 0.70)
            t = min(1.0, t)
            px[x, y] = int((t**1.7) * strength)
    return small.resize((size, size), Image.BILINEAR)


def draw_antenna_arc(draw: ImageDraw.ImageDraw, scale: int) -> None:
    """A single thin arch hugging the top edge — a light hint of a
    signal/antenna sweep rather than the literal bugdroid antennae. Drawn as
    a shallow parabola (visually identical to a circular arc at this depth)
    so the sagitta is easy to reason about directly."""
    cx = scale / 2
    peak_y = _s(96, scale)
    half_w = _s(230, scale)
    depth = _s(50, scale)

    steps = 48
    pts = []
    for i in range(steps + 1):
        t = -1.0 + 2.0 * i / steps
        pts.append((cx + t * half_w, peak_y + depth * (t * t)))

    width = max(1, round(_s(9, scale)))
    arc_color = (*GREEN[:3], 160)
    draw.line(pts, fill=arc_color, width=width, joint="curve")
    r = width / 2
    _cap(draw, pts[0][0], pts[0][1], r, arc_color)
    _cap(draw, pts[-1][0], pts[-1][1], r, arc_color)


def _cap(draw: ImageDraw.ImageDraw, x: float, y: float, r: float, fill) -> None:
    draw.ellipse([x - r, y - r, x + r, y + r], fill=fill)


def draw_chevron_and_cursor(draw: ImageDraw.ImageDraw, scale: int) -> None:
    """The '>' chevron plus a trailing cursor underscore — a minimal command
    prompt, i.e. the icon's "command deck" motif."""
    stroke = _s(84, scale)
    r = stroke / 2

    # Chevron '>' — apex on the right, arms opening to the upper/lower left.
    apex_x, apex_y = _s(556, scale), _s(512, scale)
    back_x = _s(392, scale)
    top_y = _s(360, scale)
    bot_y = _s(664, scale)

    pts = [(back_x, top_y), (apex_x, apex_y), (back_x, bot_y)]
    draw.line(pts, fill=GREEN, width=round(stroke), joint="curve")
    for x, y in pts:
        _cap(draw, x, y, r, GREEN)

    # Cursor underscore — a rounded bar continuing the prompt's baseline.
    bar_y = bot_y
    bar_x0, bar_x1 = _s(616, scale), _s(772, scale)
    draw.rounded_rectangle(
        [bar_x0, bar_y - r, bar_x1, bar_y + r], radius=r, fill=GREEN
    )


def build(size: int) -> Image.Image:
    scale = size * SS
    radius = _s(RADIUS, scale)

    canvas = Image.new("RGBA", (scale, scale), TRANSPARENT)
    bg = Image.new("RGBA", (scale, scale), BG)
    canvas.paste(bg, (0, 0), rounded_mask(scale, radius))

    # Subtle radial darkening toward the corners, clipped to the rounded
    # square so the transparent corners outside it stay untouched.
    dark = Image.new("RGBA", (scale, scale), (0, 0, 0, 255))
    vmask = vignette(scale)
    shape_mask = rounded_mask(scale, radius)
    combined = Image.composite(vmask, Image.new("L", (scale, scale), 0), shape_mask)
    canvas.paste(dark, (0, 0), combined)

    draw = ImageDraw.Draw(canvas)
    draw_antenna_arc(draw, scale)
    draw_chevron_and_cursor(draw, scale)

    return canvas.resize((size, size), Image.LANCZOS)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sizes", default="16,32,48,64,128,256,512,1024")
    parser.add_argument(
        "--out-dir",
        type=Path,
        default=Path(__file__).resolve().parents[1] / "assets/icon",
    )
    args = parser.parse_args()

    sizes = [int(s) for s in args.sizes.split(",") if s.strip()]
    args.out_dir.mkdir(parents=True, exist_ok=True)

    for size in sizes:
        icon = build(size)
        out = args.out_dir / f"droiddeck_{size}.png"
        icon.save(out, "PNG", optimize=True)
        print(f"wrote {out} ({size}x{size})")


if __name__ == "__main__":
    main()
