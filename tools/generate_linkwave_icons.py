"""Generate LinkWave 1024px app icons and iOS asset-catalog manifests."""

from pathlib import Path

from PIL import Image, ImageDraw


ROOT = Path(__file__).resolve().parents[1] / "FibreMonitor/Resources/Assets.xcassets"
SIZE = 1024
SCALE = 3


def color(hex_value):
    value = hex_value.removeprefix("#")
    return tuple(int(value[index:index + 2], 16) for index in (0, 2, 4))


def render(background_top, background_bottom, accent, tinted=False):
    size = SIZE * SCALE
    if tinted:
        image = Image.new("RGBA", (size, size), (0, 0, 0, 0))
        foreground = (255, 255, 255, 255)
    else:
        top = color(background_top)
        bottom = color(background_bottom)
        image = Image.new("RGB", (size, size))
        draw = ImageDraw.Draw(image)
        for y in range(size):
            t = y / max(1, size - 1)
            row = tuple(round(top[i] + (bottom[i] - top[i]) * t) for i in range(3))
            draw.line((0, y, size, y), fill=row)
        foreground = (*color(accent), 255)

    draw = ImageDraw.Draw(image)
    cx, cy = 512 * SCALE, 650 * SCALE
    # Three rising fibre / Wi-Fi wave arcs and a bright terminal dot.
    for radius, width, alpha in ((270, 30, 170), (190, 30, 215), (110, 28, 255)):
        extent = radius * SCALE
        box = (cx - extent, cy - extent, cx + extent, cy + extent)
        arc_color = (*foreground[:3], alpha if not tinted else 255)
        draw.arc(box, start=222, end=318, fill=arc_color, width=width * SCALE)
    dot = 32 * SCALE
    draw.ellipse((cx - dot, cy - dot, cx + dot, cy + dot), fill=foreground)

    image = image.resize((SIZE, SIZE), Image.Resampling.LANCZOS)
    return image if tinted else image.convert("RGB")


def save_set(name, variants):
    folder = ROOT / f"{name}.appiconset"
    folder.mkdir(parents=True, exist_ok=True)
    images = []
    for filename, image, appearance in variants:
        image.save(folder / filename, format="PNG", optimize=True)
        item = {
            "filename": filename,
            "idiom": "universal",
            "platform": "ios",
            "size": "1024x1024",
        }
        if appearance:
            item["appearances"] = [{"appearance": "luminosity", "value": appearance}]
        images.append(item)

    import json

    (folder / "Contents.json").write_text(
        json.dumps({"images": images, "info": {"author": "xcode", "version": 1}}, indent=2) + "\n",
        encoding="utf-8",
    )


def main():
    accents = {
        "Orange": ("#FFB34F", "#E34A20"),
        "Blue": ("#5DE1FF", "#1758D4"),
        "Purple": ("#E08EFF", "#6726C9"),
        "Green": ("#71F2A7", "#08775B"),
    }
    primary_accent = accents["Blue"][0]
    save_set(
        "AppIcon",
        [
            ("AppIcon.png", render("#14334A", "#07131F", primary_accent), None),
            ("AppIcon-Dark.png", render("#090E18", "#020407", "#83E7FF"), "dark"),
            ("AppIcon-Tinted.png", render("#000000", "#000000", "#FFFFFF", tinted=True), "tinted"),
        ],
    )
    for name, (accent, _) in accents.items():
        top, bottom = accent
        save_set(f"AppIcon{name}", [(f"AppIcon{name}.png", render(top, bottom, "#FFFFFF"), None)])


if __name__ == "__main__":
    main()
