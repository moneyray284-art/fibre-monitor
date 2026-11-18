"""Generate only the five new LinkWave alternate icon sets.

The primary AppIcon and the existing color alternate icons are deliberately
left untouched. Artwork is drawn from vector bezier paths at 3x resolution and
downsampled with Lanczos filtering for clean, antialiased 1024px PNGs.
"""

from __future__ import annotations

import json
import math
from pathlib import Path

from PIL import Image, ImageDraw


ROOT = Path(__file__).resolve().parents[1] / "FibreMonitor/Resources/Assets.xcassets"
SIZE = 1024
SCALE = 3
ICON_VARIANTS = {
    "AppIconLaunchArcs": ("#22D3EE", "arcs"),
    "AppIconMonogramI": ("#38BDF8", "i"),
    "AppIconArcsI": ("#22D3EE", "arcs_i"),
    "AppIconLinkRing": ("#2DD4BF", "ring"),
    "AppIconWavefrontW": ("#38BDF8", "wave_w"),
}


def rgb(hex_value: str) -> tuple[int, int, int]:
    value = hex_value.removeprefix("#")
    return tuple(int(value[index:index + 2], 16) for index in (0, 2, 4))


def blend(top: tuple[int, int, int], bottom: tuple[int, int, int], t: float) -> tuple[int, int, int]:
    return tuple(round(top[index] + (bottom[index] - top[index]) * t) for index in range(3))


def bezier_points(
    start: tuple[float, float],
    control_1: tuple[float, float],
    control_2: tuple[float, float],
    end: tuple[float, float],
    steps: int = 128,
) -> list[tuple[float, float]]:
    points: list[tuple[float, float]] = []
    for index in range(steps + 1):
        t = index / steps
        inverse = 1 - t
        x = inverse**3 * start[0] + 3 * inverse**2 * t * control_1[0] + 3 * inverse * t**2 * control_2[0] + t**3 * end[0]
        y = inverse**3 * start[1] + 3 * inverse**2 * t * control_1[1] + 3 * inverse * t**2 * control_2[1] + t**3 * end[1]
        points.append((x, y))
    return points


def draw_polyline(draw: ImageDraw.ImageDraw, points: list[tuple[float, float]], color, width: float) -> None:
    scaled_points = [(round(x * SCALE), round(y * SCALE)) for x, y in points]
    scaled_width = max(1, round(width * SCALE))
    draw.line(scaled_points, fill=color, width=scaled_width, joint="curve")
    radius = scaled_width / 2
    for x, y in (scaled_points[0], scaled_points[-1]):
        draw.ellipse((x - radius, y - radius, x + radius, y + radius), fill=color)


def draw_curve(draw: ImageDraw.ImageDraw, points, color, width: float) -> None:
    draw_polyline(draw, bezier_points(*points), color, width)


def launch_arcs(draw: ImageDraw.ImageDraw, color, x: float = 152, y: float = 212, width: float = 610, height: float = 600) -> None:
    """The three launch-screen arcs, using the same normalized bezier geometry."""
    def p(px: float, py: float) -> tuple[float, float]:
        return x + px * width, y + py * height

    stroke = width * (3.4 / 58.0)
    curves = (
        (p(0.61, 0.04), p(1.02, 0.24), p(1.02, 0.76), p(0.61, 0.96)),
        (p(0.39, 0.20), p(0.72, 0.34), p(0.72, 0.66), p(0.39, 0.80)),
        (p(0.18, 0.35), p(0.39, 0.43), p(0.39, 0.57), p(0.18, 0.65)),
    )
    for curve in curves:
        draw_curve(draw, curve, color, stroke)


def harmonic_i(draw: ImageDraw.ImageDraw, color, stem_color, x: float = 406, y: float = 212, height: float = 600) -> None:
    """The launch wordmark's 11x31 harmonic-node lowercase i proportions."""
    scale = height / 31.0
    center_x = x + 5.5 * scale
    ring_y = y + 5.5 * scale
    dot_y = y + 7.75 * scale
    stem_top = y + 13.0 * scale
    stem_height = 17.0 * scale
    ring_radius = 3.0 * scale
    dot_radius = 2.25 * scale
    line_width = 3.2 * scale

    draw.ellipse(
        (
            round((center_x - ring_radius) * SCALE),
            round((ring_y - ring_radius) * SCALE),
            round((center_x + ring_radius) * SCALE),
            round((ring_y + ring_radius) * SCALE),
        ),
        outline=color,
        width=max(1, round(1.0 * scale * SCALE)),
    )
    draw.ellipse(
        (
            round((center_x - dot_radius) * SCALE),
            round((dot_y - dot_radius) * SCALE),
            round((center_x + dot_radius) * SCALE),
            round((dot_y + dot_radius) * SCALE),
        ),
        fill=color,
    )
    half = line_width / 2
    draw.rounded_rectangle(
        (
            round((center_x - half) * SCALE),
            round(stem_top * SCALE),
            round((center_x + half) * SCALE),
            round((stem_top + stem_height) * SCALE),
        ),
        radius=round(half * SCALE),
        fill=stem_color,
    )


def draw_circle_arc(draw: ImageDraw.ImageDraw, cx: float, cy: float, rx: float, ry: float,
                    start: float, end: float, color, width: float) -> None:
    points = []
    for index in range(181):
        angle = math.radians(start + (end - start) * index / 180)
        points.append((cx + math.cos(angle) * rx, cy + math.sin(angle) * ry))
    draw_polyline(draw, points, color, width)


def link_ring(draw: ImageDraw.ImageDraw, accent, white) -> None:
    # Two offset open rings meet as a compact chain/link emblem.
    width = 36
    draw_circle_arc(draw, 438, 512, 185, 220, 44, 316, accent, width)
    draw_circle_arc(draw, 586, 512, 185, 220, -136, 136, white, width)
    for x, y, color in ((568, 348, accent), (456, 676, white)):
        radius = 19
        draw.ellipse(
            (round((x - radius) * SCALE), round((y - radius) * SCALE),
             round((x + radius) * SCALE), round((y + radius) * SCALE)),
            fill=color,
        )


def wavefront_w(draw: ImageDraw.ImageDraw, accent, white) -> None:
    width = 42
    points = [
        ((246, 337), (295, 337), (300, 682), (368, 682)),
        ((368, 682), (430, 682), (438, 366), (512, 366)),
        ((512, 366), (586, 366), (594, 682), (656, 682)),
        ((656, 682), (724, 682), (729, 337), (778, 337)),
    ]
    for curve in points:
        draw_curve(draw, curve, accent, width)
    radius = 18
    draw.ellipse(
        (round((512 - radius) * SCALE), round((366 - radius) * SCALE),
         round((512 + radius) * SCALE), round((366 + radius) * SCALE)),
        fill=white,
    )


def make_artwork(kind: str, draw: ImageDraw.ImageDraw, accent, white) -> None:
    if kind == "arcs":
        launch_arcs(draw, accent)
    elif kind == "i":
        harmonic_i(draw, accent, white, x=406, y=212, height=600)
    elif kind == "arcs_i":
        launch_arcs(draw, accent, x=62, y=236, width=510, height=548)
        harmonic_i(draw, white, white, x=682, y=236, height=548)
    elif kind == "ring":
        link_ring(draw, accent, white)
    elif kind == "wave_w":
        wavefront_w(draw, accent, white)
    else:
        raise ValueError(f"Unknown icon artwork: {kind}")


def render_icon(kind: str, accent_hex: str, appearance: str) -> Image.Image:
    if appearance == "tinted":
        image = Image.new("RGBA", (SIZE * SCALE, SIZE * SCALE), (0, 0, 0, 0))
        accent = (255, 255, 255, 255)
        white = (255, 255, 255, 255)
    else:
        if appearance == "dark":
            top, bottom = rgb("#060B14"), rgb("#0B1628")
        else:
            top, bottom = rgb("#10243A"), rgb("#060C17")
        base = Image.new("RGB", (SIZE, SIZE))
        background = ImageDraw.Draw(base)
        for y in range(SIZE):
            background.line((0, y, SIZE, y), fill=blend(top, bottom, y / (SIZE - 1)))
        image = base.resize((SIZE * SCALE, SIZE * SCALE), Image.Resampling.BICUBIC).convert("RGBA")
        accent = (*rgb(accent_hex), 255)
        white = (255, 255, 255, 255)

    draw = ImageDraw.Draw(image)
    make_artwork(kind, draw, accent, white)
    result = image.resize((SIZE, SIZE), Image.Resampling.LANCZOS)
    if appearance == "tinted":
        # Keep antialiased edges in alpha while ensuring every painted pixel is pure white.
        white = Image.new("RGBA", (SIZE, SIZE), (255, 255, 255, 0))
        white.putalpha(result.getchannel("A"))
        return white
    return result.convert("RGB")


def save_icon_set(set_name: str, accent: str, artwork: str) -> None:
    folder = ROOT / f"{set_name}.appiconset"
    folder.mkdir(parents=True, exist_ok=True)
    entries = []
    variants = (
        (set_name + ".png", "any"),
        (set_name + "-Dark.png", "dark"),
        (set_name + "-Tinted.png", "tinted"),
    )
    for filename, appearance in variants:
        render_icon(artwork, accent, appearance).save(folder / filename, format="PNG", optimize=True)
        image_entry = {
            "filename": filename,
            "idiom": "universal",
            "platform": "ios",
            "size": "1024x1024",
        }
        if appearance != "any":
            image_entry["appearances"] = [{"appearance": "luminosity", "value": appearance}]
        entries.append(image_entry)

    (folder / "Contents.json").write_text(
        json.dumps({"images": entries, "info": {"author": "xcode", "version": 1}}, indent=2) + "\n",
        encoding="utf-8",
    )


def main() -> None:
    for set_name, (accent, artwork) in ICON_VARIANTS.items():
        save_icon_set(set_name, accent, artwork)


if __name__ == "__main__":
    main()
