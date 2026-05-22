#!/usr/bin/env python3
"""Split a 3x3 chroma-key pet sprite sheet into Nibbi pet frames."""

from __future__ import annotations

import argparse
from collections import Counter, deque
from pathlib import Path

from PIL import Image, ImageDraw


FRAME_NAMES = [
    "idle",
    "blink",
    "look_left",
    "look_right",
    "happy",
    "thinking",
    "worried",
    "sleepy",
    "celebrate",
]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", required=True, help="Generated 3x3 sprite sheet")
    parser.add_argument("--out-dir", required=True, help="Directory for frame PNGs")
    parser.add_argument("--preview", required=True, help="White-background preview PNG")
    parser.add_argument("--still", help="Optional idle-frame copy path")
    parser.add_argument("--canvas-size", type=int, default=192)
    parser.add_argument("--transparent-threshold", type=float, default=46.0)
    parser.add_argument("--opaque-threshold", type=float, default=120.0)
    return parser.parse_args()


def border_key(image: Image.Image) -> tuple[int, int, int]:
    rgb = image.convert("RGB")
    width, height = rgb.size
    samples = []
    pix = rgb.load()
    for x in range(width):
        samples.append(pix[x, 0])
        samples.append(pix[x, height - 1])
    for y in range(height):
        samples.append(pix[0, y])
        samples.append(pix[width - 1, y])
    return Counter(samples).most_common(1)[0][0]


def color_distance(a: tuple[int, int, int], b: tuple[int, int, int]) -> float:
    return sum((a[i] - b[i]) ** 2 for i in range(3)) ** 0.5


def remove_key(image: Image.Image, key: tuple[int, int, int], transparent: float, opaque: float) -> Image.Image:
    rgba = image.convert("RGBA")
    pix = rgba.load()
    for y in range(rgba.height):
        for x in range(rgba.width):
            r, g, b, a = pix[x, y]
            distance = color_distance((r, g, b), key)
            if distance <= transparent:
                pix[x, y] = (r, g, b, 0)
            elif distance < opaque:
                alpha = int(255 * (distance - transparent) / max(1, opaque - transparent))
                pix[x, y] = (r, g, b, min(a, alpha))
    return rgba


def visible_bbox(image: Image.Image) -> tuple[int, int, int, int]:
    alpha = image.getchannel("A")
    bbox = alpha.point(lambda a: 255 if a > 20 else 0).getbbox()
    if not bbox:
        raise ValueError("cell has no visible pixels")
    return bbox


def strip_noise(image: Image.Image) -> Image.Image:
    pix = image.load()
    width, height = image.size
    seen = [[False] * width for _ in range(height)]
    components = []
    for y in range(height):
        for x in range(width):
            if seen[y][x] or pix[x, y][3] <= 20:
                continue
            queue = deque([(x, y)])
            seen[y][x] = True
            points = []
            totals = [0, 0, 0]
            while queue:
                cx, cy = queue.popleft()
                points.append((cx, cy))
                r, g, b, _ = pix[cx, cy]
                totals[0] += r
                totals[1] += g
                totals[2] += b
                for nx in (cx - 1, cx, cx + 1):
                    for ny in (cy - 1, cy, cy + 1):
                        if nx < 0 or ny < 0 or nx >= width or ny >= height or seen[ny][nx]:
                            continue
                        if pix[nx, ny][3] > 20:
                            seen[ny][nx] = True
                            queue.append((nx, ny))
            area = len(points)
            avg = tuple(total / area for total in totals)
            components.append((area, avg, points))

    if not components:
        return image

    largest = max(area for area, _, _ in components)
    keep = set()
    for area, avg, points in components:
        bright = max(avg) > 145
        saturated = max(avg) - min(avg) > 35
        if area == largest or area >= largest * 0.01 or (area >= 6 and bright and saturated):
            keep.update(points)

    cleaned = Image.new("RGBA", image.size, (0, 0, 0, 0))
    cleaned_pix = cleaned.load()
    for x, y in keep:
        cleaned_pix[x, y] = pix[x, y]
    return cleaned


def main() -> None:
    args = parse_args()
    source = Image.open(args.input).convert("RGBA")
    key = border_key(source)
    sheet = remove_key(source, key, args.transparent_threshold, args.opaque_threshold)

    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    for old in out_dir.glob("*.png"):
        old.unlink()

    cols = rows = 3
    xs = [round(sheet.width * i / cols) for i in range(cols + 1)]
    ys = [round(sheet.height * i / rows) for i in range(rows + 1)]

    canvas_size = args.canvas_size
    rendered = []
    for index, name in enumerate(FRAME_NAMES):
        col = index % cols
        row = index // cols
        cell = sheet.crop((xs[col], ys[row], xs[col + 1], ys[row + 1]))
        crop = cell.crop(visible_bbox(cell))
        crop = strip_noise(crop)
        crop = crop.crop(visible_bbox(crop))
        scale = min(canvas_size * 0.94 / crop.width, canvas_size * 0.94 / crop.height)
        size = (max(1, round(crop.width * scale)), max(1, round(crop.height * scale)))
        resized = crop.resize(size, Image.Resampling.NEAREST)
        canvas = Image.new("RGBA", (canvas_size, canvas_size), (0, 0, 0, 0))
        canvas.alpha_composite(resized, ((canvas_size - size[0]) // 2, canvas_size - size[1] - 4))
        out_path = out_dir / f"{name}.png"
        canvas.save(out_path)
        rendered.append((name, canvas))

    if args.still:
        Image.open(out_dir / "idle.png").save(args.still)

    preview = Image.new("RGB", (3 * 220, 3 * (canvas_size + 44)), "white")
    draw = ImageDraw.Draw(preview)
    for index, (name, frame) in enumerate(rendered):
        x = (index % 3) * 220 + 14
        y = (index // 3) * (canvas_size + 44) + 8
        tile = Image.new("RGB", frame.size, "white")
        tile.paste(frame, mask=frame.getchannel("A"))
        preview.paste(tile, (x, y))
        draw.text((x, y + frame.height + 4), name, fill=(40, 40, 40))
    preview.save(args.preview)

    print(f"Key color: #{key[0]:02x}{key[1]:02x}{key[2]:02x}")
    print(f"Wrote {len(FRAME_NAMES)} frames to {out_dir}")
    print(f"Preview: {args.preview}")


if __name__ == "__main__":
    main()
