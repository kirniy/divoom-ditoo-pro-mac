#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import math
import subprocess
from dataclasses import dataclass
from pathlib import Path

from PIL import Image, ImageDraw


SIZE = 16
FRAME_COUNT = 24


@dataclass
class UsageSnapshot:
    provider: str
    primary_used: int | None
    secondary_used: int | None
    tertiary_used: int | None


THEMES = {
    "codex": {
        "bg": (5, 8, 12),
        "base": (20, 36, 46),
        "ring": (56, 205, 186),
        "accent": (140, 255, 214),
        "glow": (78, 130, 255),
    },
    "claude": {
        "bg": (17, 8, 5),
        "base": (48, 27, 17),
        "ring": (247, 137, 59),
        "accent": (255, 208, 124),
        "glow": (255, 90, 54),
    },
}


def load_usage(provider: str) -> UsageSnapshot:
    cmd = [
        "codexbar",
        "usage",
        "--provider",
        provider,
        "--source",
        "cli",
        "--format",
        "json",
        "--json-only",
    ]
    raw = subprocess.check_output(cmd, text=True)
    payload = json.loads(raw)[0]
    usage = payload.get("usage", {})
    primary_payload = usage.get("primary") or {}
    secondary_payload = usage.get("secondary") or {}
    tertiary_payload = usage.get("tertiary") or {}
    primary = primary_payload.get("usedPercent")
    secondary = secondary_payload.get("usedPercent")
    tertiary = tertiary_payload.get("usedPercent")
    return UsageSnapshot(
        provider=provider,
        primary_used=primary,
        secondary_used=secondary,
        tertiary_used=tertiary,
    )


def perimeter_points() -> list[tuple[int, int]]:
    points: list[tuple[int, int]] = []
    for x in range(1, 15):
        points.append((x, 1))
    for y in range(2, 15):
        points.append((14, y))
    for x in range(13, 0, -1):
        points.append((x, 14))
    for y in range(13, 1, -1):
        points.append((1, y))
    return points


RING_POINTS = perimeter_points()


def mix(a: tuple[int, int, int], b: tuple[int, int, int], t: float) -> tuple[int, int, int]:
    return tuple(round(a[i] + (b[i] - a[i]) * t) for i in range(3))


def draw_frame(snapshot: UsageSnapshot, frame_index: int) -> Image.Image:
    theme = THEMES[snapshot.provider]
    img = Image.new("RGB", (SIZE, SIZE), theme["bg"])
    draw = ImageDraw.Draw(img)

    secondary_used = snapshot.secondary_used or 0
    primary_used = snapshot.primary_used or 0
    tertiary_used = snapshot.tertiary_used or 0

    secondary_fill = max(0, min(len(RING_POINTS), round(len(RING_POINTS) * secondary_used / 100)))
    orbit = frame_index % len(RING_POINTS)
    pulse = (math.sin(frame_index / FRAME_COUNT * math.tau) + 1) / 2

    for index, point in enumerate(RING_POINTS):
        color = theme["base"]
        if index < secondary_fill:
            glow_mix = 0.35 + 0.45 * pulse
            color = mix(theme["ring"], theme["accent"], glow_mix)
        if index == orbit:
            color = theme["glow"]
        draw.point(point, fill=color)

    # Inner capsule shows primary window
    capsule_height = max(1, round(8 * max(0, 100 - primary_used) / 100))
    for y in range(4, 12):
        for x in range(6, 10):
            draw.point((x, y), fill=(18, 18, 20))
    for y in range(12 - capsule_height, 12):
        for x in range(6, 10):
            color = mix(theme["ring"], theme["accent"], (y - (12 - capsule_height)) / max(1, capsule_height))
            draw.point((x, y), fill=color)

    # Tertiary window appears as bottom sparks when present.
    if tertiary_used:
        spark_count = max(1, round(4 * (100 - tertiary_used) / 100))
        for i in range(spark_count):
            x = 5 + i * 2
            draw.point((x, 13), fill=theme["accent"])

    # Center pulse
    center = 7.5
    radius = 1.5 + pulse * 1.2
    color = mix(theme["glow"], theme["accent"], pulse)
    for y in range(SIZE):
        for x in range(SIZE):
            dx = x - center
            dy = y - center
            if dx * dx + dy * dy <= radius * radius:
                draw.point((x, y), fill=color)

    return img


def render(snapshot: UsageSnapshot, output_path: Path) -> None:
    frames = [draw_frame(snapshot, i) for i in range(FRAME_COUNT)]
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
    parser = argparse.ArgumentParser(description="Render a 16x16 animated GIF from live CodexBar usage")
    parser.add_argument("--provider", choices=sorted(THEMES.keys()), required=True)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()

    snapshot = load_usage(args.provider)
    render(snapshot, Path(args.output))
    print(
        json.dumps(
            {
                "provider": snapshot.provider,
                "primaryUsed": snapshot.primary_used,
                "secondaryUsed": snapshot.secondary_used,
                "tertiaryUsed": snapshot.tertiary_used,
                "output": args.output,
            },
            indent=2,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
