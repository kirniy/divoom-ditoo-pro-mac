#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import math
import random
from pathlib import Path

from PIL import Image, ImageDraw


SIZE = 16
FRAME_COUNT = 32


PALETTES: dict[str, list[tuple[int, int, int]]] = {
    "plasma": [(8, 6, 20), (28, 18, 64), (89, 50, 190), (255, 120, 72), (255, 236, 150)],
    "orbit": [(2, 12, 18), (14, 48, 74), (40, 124, 166), (182, 247, 255), (255, 214, 94)],
    "ripple": [(9, 12, 26), (22, 46, 84), (46, 91, 161), (111, 199, 232), (243, 251, 255)],
}


def lerp_color(a: tuple[int, int, int], b: tuple[int, int, int], t: float) -> tuple[int, int, int]:
    return tuple(round(a[i] + (b[i] - a[i]) * t) for i in range(3))


def palette_sample(colors: list[tuple[int, int, int]], value: float) -> tuple[int, int, int]:
    value = max(0.0, min(0.999, value))
    scaled = value * (len(colors) - 1)
    index = int(scaled)
    frac = scaled - index
    return lerp_color(colors[index], colors[min(index + 1, len(colors) - 1)], frac)


def render_frame(style: str, seed: int, frame_index: int) -> Image.Image:
    rng = random.Random(seed)
    img = Image.new("RGB", (SIZE, SIZE), PALETTES[style][0])
    draw = ImageDraw.Draw(img)
    t = frame_index / FRAME_COUNT * math.tau

    ax = rng.uniform(0.15, 0.42)
    ay = rng.uniform(0.18, 0.46)
    bx = rng.uniform(0.14, 0.37)
    by = rng.uniform(0.16, 0.39)
    cx = rng.uniform(0.08, 0.31)
    cy = rng.uniform(0.08, 0.31)
    phase = rng.uniform(0.0, math.tau)

    for y in range(SIZE):
        for x in range(SIZE):
            nx = (x - 7.5) / 7.5
            ny = (y - 7.5) / 7.5
            radius = math.hypot(nx, ny)
            angle = math.atan2(ny, nx)

            if style == "plasma":
                value = (
                    math.sin(x * ax + t + phase)
                    + math.sin(y * ay - t * 1.7)
                    + math.sin((x + y) * cx + t * 0.6)
                    + math.sin(radius * 8 - t * 2.4)
                ) / 4
                value = (value + 1) / 2
            elif style == "orbit":
                rings = math.sin(radius * 11 - t * 2.1 + phase) * 0.5 + 0.5
                spiral = math.sin(angle * 3 + radius * 7 - t * 1.3) * 0.5 + 0.5
                sweep = math.sin(x * bx - y * by + t * 2.2) * 0.5 + 0.5
                value = 0.2 + 0.45 * rings + 0.25 * spiral + 0.1 * sweep
            else:
                wave_a = math.sin(x * ax + t * 1.4)
                wave_b = math.cos(y * ay - t * 0.9 + phase)
                wave_c = math.sin((x - y) * cy + t * 1.8)
                envelope = math.cos(radius * 6 - t * 1.2) * 0.5 + 0.5
                value = ((wave_a + wave_b + wave_c) / 3 + 1) / 2
                value = value * 0.65 + envelope * 0.35

            draw.point((x, y), fill=palette_sample(PALETTES[style], value))

    # Add a restrained highlight pass so the motion feels deliberate on 16x16.
    orbit_x = round(7.5 + math.cos(t * 1.7 + phase) * 4.8)
    orbit_y = round(7.5 + math.sin(t * 1.2 + phase * 0.7) * 4.8)
    for oy in range(-1, 2):
        for ox in range(-1, 2):
            px = orbit_x + ox
            py = orbit_y + oy
            if 0 <= px < SIZE and 0 <= py < SIZE:
                falloff = max(0.0, 1 - (abs(ox) + abs(oy)) * 0.35)
                current = img.getpixel((px, py))
                img.putpixel((px, py), lerp_color(current, PALETTES[style][-1], falloff * 0.7))

    return img


def render(style: str, seed: int, output_path: Path) -> None:
    frames = [render_frame(style, seed, i) for i in range(FRAME_COUNT)]
    output_path.parent.mkdir(parents=True, exist_ok=True)
    frames[0].save(
        output_path,
        save_all=True,
        append_images=frames[1:],
        duration=70,
        loop=0,
        disposal=2,
    )


def main() -> int:
    parser = argparse.ArgumentParser(description="Render a seeded 16x16 generative animation GIF")
    parser.add_argument("--style", choices=sorted(PALETTES.keys()), default="orbit")
    parser.add_argument("--seed", type=int, default=17)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()

    output = Path(args.output)
    render(args.style, args.seed, output)
    print(json.dumps({"style": args.style, "seed": args.seed, "output": str(output)}, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
