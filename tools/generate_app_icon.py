#!/usr/bin/env python3
from __future__ import annotations

from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter


ROOT = Path(__file__).resolve().parents[1]
ICONSET = ROOT / "build" / "Icon.iconset"


def lerp(a: float, b: float, t: float) -> float:
    return a + (b - a) * t


def gradient_fill(size: int) -> Image.Image:
    image = Image.new("RGBA", (size, size))
    pixels = image.load()

    top_left = (13, 20, 42)
    top_right = (33, 87, 214)
    bottom_left = (23, 31, 63)
    bottom_right = (241, 105, 66)

    for y in range(size):
        ty = y / max(1, size - 1)
        for x in range(size):
            tx = x / max(1, size - 1)
            r_top = lerp(top_left[0], top_right[0], tx)
            g_top = lerp(top_left[1], top_right[1], tx)
            b_top = lerp(top_left[2], top_right[2], tx)
            r_bottom = lerp(bottom_left[0], bottom_right[0], tx)
            g_bottom = lerp(bottom_left[1], bottom_right[1], tx)
            b_bottom = lerp(bottom_left[2], bottom_right[2], tx)
            pixels[x, y] = (
                int(lerp(r_top, r_bottom, ty)),
                int(lerp(g_top, g_bottom, ty)),
                int(lerp(b_top, b_bottom, ty)),
                255,
            )

    return image


def draw_icon(size: int) -> Image.Image:
    image = gradient_fill(size)
    draw = ImageDraw.Draw(image)

    margin = int(size * 0.12)
    card = (margin, margin, size - margin, size - margin)
    shadow = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    shadow_draw = ImageDraw.Draw(shadow)
    shadow_draw.rounded_rectangle(card, radius=int(size * 0.18), fill=(0, 0, 0, 180))
    shadow = shadow.filter(ImageFilter.GaussianBlur(radius=size * 0.025))
    image.alpha_composite(shadow)

    draw.rounded_rectangle(card, radius=int(size * 0.18), fill=(18, 26, 46, 230))
    draw.rounded_rectangle(card, radius=int(size * 0.18), outline=(255, 255, 255, 42), width=max(2, size // 128))

    screen_margin_x = int(size * 0.24)
    screen_margin_top = int(size * 0.23)
    screen_height = int(size * 0.26)
    screen = (
        screen_margin_x,
        screen_margin_top,
        size - screen_margin_x,
        screen_margin_top + screen_height,
    )
    draw.rounded_rectangle(screen, radius=int(size * 0.06), fill=(7, 12, 22, 255))
    draw.rounded_rectangle(screen, radius=int(size * 0.06), outline=(255, 255, 255, 28), width=max(2, size // 160))

    pixel_palette = [
        (255, 255, 255),
        (68, 255, 186),
        (255, 83, 126),
        (84, 184, 255),
    ]
    grid_origin_x = screen[0] + int(size * 0.06)
    grid_origin_y = screen[1] + int(size * 0.055)
    dot_size = max(8, int(size * 0.034))
    gap = max(6, int(size * 0.016))
    for row in range(3):
        for col in range(4):
            color = pixel_palette[(row + col) % len(pixel_palette)]
            left = grid_origin_x + col * (dot_size + gap)
            top = grid_origin_y + row * (dot_size + gap)
            draw.rounded_rectangle(
                (left, top, left + dot_size, top + dot_size),
                radius=max(3, dot_size // 4),
                fill=color + (255,),
            )

    speaker_left = screen[0] + int(size * 0.11)
    speaker_top = screen[3] + int(size * 0.11)
    knob_size = int(size * 0.095)
    knob_gap = int(size * 0.05)
    for index in range(3):
        left = speaker_left + index * (knob_size + knob_gap)
        top = speaker_top
        draw.ellipse((left, top, left + knob_size, top + knob_size), fill=(235, 241, 255, 230))
        inner = int(knob_size * 0.34)
        inner_left = left + (knob_size - inner) // 2
        inner_top = top + (knob_size - inner) // 2
        draw.ellipse((inner_left, inner_top, inner_left + inner, inner_top + inner), fill=(18, 26, 46, 255))

    accent = [
        (int(size * 0.74), int(size * 0.16), int(size * 0.87), int(size * 0.29)),
        (int(size * 0.72), int(size * 0.72), int(size * 0.88), int(size * 0.88)),
    ]
    for shape in accent:
        draw.rounded_rectangle(shape, radius=int(size * 0.04), fill=(255, 255, 255, 28))

    return image


def build_iconset() -> None:
    ICONSET.mkdir(parents=True, exist_ok=True)
    targets = {
        "icon_16x16.png": 16,
        "icon_16x16@2x.png": 32,
        "icon_32x32.png": 32,
        "icon_32x32@2x.png": 64,
        "icon_128x128.png": 128,
        "icon_128x128@2x.png": 256,
        "icon_256x256.png": 256,
        "icon_256x256@2x.png": 512,
        "icon_512x512.png": 512,
        "icon_512x512@2x.png": 1024,
    }

    master = draw_icon(1024)
    for filename, size in targets.items():
        output = ICONSET / filename
        master.resize((size, size), Image.Resampling.LANCZOS).save(output)


if __name__ == "__main__":
    build_iconset()
