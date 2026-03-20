#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import plistlib
import subprocess
from dataclasses import dataclass
from pathlib import Path

from PIL import Image, ImageDraw


SIZE = 16
FRAME_COUNT = 1
CODEXBAR_PREFERENCES_PATH = Path.home() / "Library" / "Preferences" / "com.steipete.codexbar.plist"
CODEXBAR_WIDGET_SNAPSHOT_PATH = (
    Path.home()
    / "Library"
    / "Group Containers"
    / "group.com.steipete.codexbar"
    / "widget-snapshot.json"
)


@dataclass
class UsageSnapshot:
    provider: str
    primary_used: int | None
    secondary_used: int | None
    tertiary_used: int | None
    selected_metric: str
    show_used: bool


THEMES = {
    "codex": {
        "bg": (4, 8, 12),
        "panel": (11, 20, 28),
        "base": (23, 47, 54),
        "ring": (59, 196, 177),
        "accent": (175, 255, 233),
        "glow": (74, 121, 255),
        "shadow": (7, 16, 22),
    },
    "claude": {
        "bg": (18, 8, 5),
        "panel": (31, 16, 10),
        "base": (68, 37, 18),
        "ring": (243, 134, 59),
        "accent": (255, 216, 148),
        "glow": (255, 92, 55),
        "shadow": (21, 11, 7),
    },
}

DIGITS_3X5 = {
    "0": ("111", "101", "101", "101", "111"),
    "1": ("010", "110", "010", "010", "111"),
    "2": ("111", "001", "111", "100", "111"),
    "3": ("111", "001", "111", "001", "111"),
    "4": ("101", "101", "111", "001", "001"),
    "5": ("111", "100", "111", "001", "111"),
    "6": ("111", "100", "111", "101", "111"),
    "7": ("111", "001", "010", "010", "010"),
    "8": ("111", "101", "111", "101", "111"),
    "9": ("111", "101", "111", "001", "111"),
    "-": ("000", "000", "111", "000", "000"),
}


def load_codexbar_menu_preferences() -> tuple[dict[str, str], bool]:
    if not CODEXBAR_PREFERENCES_PATH.exists():
        return {}, True
    try:
        with CODEXBAR_PREFERENCES_PATH.open("rb") as handle:
            payload = plistlib.load(handle)
    except Exception:
        return {}, True

    raw_preferences = payload.get("menuBarMetricPreferences") or {}
    preferences = {
        str(provider): str(metric)
        for provider, metric in raw_preferences.items()
        if str(metric) in {"primary", "secondary", "tertiary"}
    }
    show_used = bool(payload.get("usageBarsShowUsed", True))
    return preferences, show_used


def load_usage_from_widget_snapshot(provider: str) -> UsageSnapshot | None:
    if not CODEXBAR_WIDGET_SNAPSHOT_PATH.exists():
        return None
    try:
        payload = json.loads(CODEXBAR_WIDGET_SNAPSHOT_PATH.read_text())
    except Exception:
        return None

    entries = payload.get("entries")
    if not isinstance(entries, list):
        return None

    selected_entry = None
    for entry in entries:
        if isinstance(entry, dict) and str(entry.get("provider") or "").strip().lower() == provider:
            selected_entry = entry
            break

    if not isinstance(selected_entry, dict):
        return None

    def metric_used_percent(key: str) -> int | None:
        metric = selected_entry.get(key)
        if not isinstance(metric, dict):
            return None
        value = metric.get("usedPercent")
        if value is None:
            return None
        return int(round(float(value)))

    preferences, show_used = load_codexbar_menu_preferences()
    return UsageSnapshot(
        provider=provider,
        primary_used=metric_used_percent("primary"),
        secondary_used=metric_used_percent("secondary"),
        tertiary_used=metric_used_percent("tertiary"),
        selected_metric=preferences.get(provider, "primary"),
        show_used=show_used,
    )


def metric_value(snapshot: UsageSnapshot, metric: str) -> int | None:
    if metric == "primary":
        return snapshot.primary_used
    if metric == "secondary":
        return snapshot.secondary_used
    if metric == "tertiary":
        return snapshot.tertiary_used
    return None


def resolved_metric(snapshot: UsageSnapshot) -> str:
    preferred = snapshot.selected_metric if snapshot.selected_metric in {"primary", "secondary", "tertiary"} else "primary"
    if metric_value(snapshot, preferred) is not None:
        return preferred
    for fallback in ("primary", "secondary", "tertiary"):
        if metric_value(snapshot, fallback) is not None:
            return fallback
    return "primary"


def display_percent(snapshot: UsageSnapshot) -> int:
    used = normalized_percent(metric_value(snapshot, resolved_metric(snapshot)))
    if snapshot.show_used:
        return used
    return max(0, 100 - used)


def display_label(snapshot: UsageSnapshot) -> str:
    metric = resolved_metric(snapshot)
    mode = "used" if snapshot.show_used else "remaining"
    return f"{snapshot.provider} {metric} {mode} {display_percent(snapshot)}%"


def load_usage(provider: str) -> UsageSnapshot:
    snapshot = load_usage_from_widget_snapshot(provider)
    if snapshot is not None:
        return snapshot

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
    raw = subprocess.check_output(cmd, text=True, timeout=8)
    payload = json.loads(raw)[0]
    usage = payload.get("usage", {})
    primary_payload = usage.get("primary") or {}
    secondary_payload = usage.get("secondary") or {}
    tertiary_payload = usage.get("tertiary") or {}
    primary = primary_payload.get("usedPercent")
    secondary = secondary_payload.get("usedPercent")
    tertiary = tertiary_payload.get("usedPercent")
    preferences, show_used = load_codexbar_menu_preferences()
    return UsageSnapshot(
        provider=provider,
        primary_used=primary,
        secondary_used=secondary,
        tertiary_used=tertiary,
        selected_metric=preferences.get(provider, "primary"),
        show_used=show_used,
    )


def mix(a: tuple[int, int, int], b: tuple[int, int, int], t: float) -> tuple[int, int, int]:
    return tuple(round(a[i] + (b[i] - a[i]) * t) for i in range(3))


def draw_pixel_block(draw: ImageDraw.ImageDraw, x: int, y: int, color: tuple[int, int, int], size: int = 1) -> None:
    for yy in range(y, y + size):
        for xx in range(x, x + size):
            if 0 <= xx < SIZE and 0 <= yy < SIZE:
                draw.point((xx, yy), fill=color)


def normalized_percent(value: int | None) -> int:
    if value is None:
        return 0
    return max(0, min(100, int(value)))


def text_width(text: str, scale: int = 1) -> int:
    if not text:
        return 0
    return len(text) * 3 * scale + (len(text) - 1) * scale


def draw_background(draw: ImageDraw.ImageDraw, theme: dict[str, tuple[int, int, int]], frame_index: int) -> None:
    for y in range(SIZE):
        row = mix(theme["bg"], theme["panel"], y / max(1, SIZE - 1))
        for x in range(SIZE):
            draw.point((x, y), fill=row)

    sweep_x = (frame_index * 2) % 18 - 2
    for x in range(max(1, sweep_x), min(15, sweep_x + 4)):
        draw.point((x, 1), fill=mix(theme["accent"], theme["glow"], 0.16))


def draw_text(
    draw: ImageDraw.ImageDraw,
    text: str,
    x: int,
    y: int,
    color: tuple[int, int, int],
    scale: int = 1,
    shadow: tuple[int, int, int] | None = None,
) -> None:
    cursor_x = x
    for char in text:
        glyph = DIGITS_3X5.get(char, DIGITS_3X5["-"])
        if shadow is not None:
            for row_index, row in enumerate(glyph):
                for col_index, bit in enumerate(row):
                    if bit == "1":
                        draw_pixel_block(
                            draw,
                            cursor_x + col_index * scale + 1,
                            y + row_index * scale + 1,
                            shadow,
                            size=scale,
                        )
        for row_index, row in enumerate(glyph):
            for col_index, bit in enumerate(row):
                if bit == "1":
                    draw_pixel_block(
                        draw,
                        cursor_x + col_index * scale,
                        y + row_index * scale,
                        color,
                        size=scale,
                    )
        cursor_x += 3 * scale + scale


def draw_meter(
    draw: ImageDraw.ImageDraw,
    theme: dict[str, tuple[int, int, int]],
    used: int,
    frame_index: int,
    x: int,
    y: int,
    width: int,
    height: int,
) -> None:
    fill = max(0, min(width, round(width * used / 100)))
    for row in range(height):
        for col in range(width):
            draw.point((x + col, y + row), fill=theme["shadow"])
    for row in range(height):
        for col in range(fill):
            ratio = col / max(1, width - 1)
            color = mix(theme["ring"], theme["accent"], ratio)
            if col == (frame_index + row) % max(1, fill):
                color = theme["glow"]
            draw.point((x + col, y + row), fill=color)


def rect_perimeter_points(x: int, y: int, width: int, height: int) -> list[tuple[int, int]]:
    points: list[tuple[int, int]] = []
    if width < 2 or height < 2:
        return points
    for px in range(x, x + width):
        points.append((px, y))
    for py in range(y + 1, y + height):
        points.append((x + width - 1, py))
    for px in range(x + width - 2, x - 1, -1):
        points.append((px, y + height - 1))
    for py in range(y + height - 2, y, -1):
        points.append((x, py))
    return points


def draw_perimeter_meter(
    draw: ImageDraw.ImageDraw,
    theme: dict[str, tuple[int, int, int]],
    percent: int,
    x: int,
    y: int,
    width: int,
    height: int,
) -> None:
    points = rect_perimeter_points(x, y, width, height)
    fill_count = max(0, min(len(points), round(len(points) * percent / 100)))
    for index, point in enumerate(points):
        if index < fill_count:
            ratio = index / max(1, len(points) - 1)
            color = mix(theme["ring"], theme["accent"], ratio)
        else:
            color = mix(theme["base"], theme["panel"], 0.35)
        draw.point(point, fill=color)


def draw_single_frame(snapshot: UsageSnapshot, frame_index: int) -> Image.Image:
    theme = THEMES[snapshot.provider]
    img = Image.new("RGB", (SIZE, SIZE), theme["bg"])
    draw = ImageDraw.Draw(img)
    draw_background(draw, theme, frame_index)

    percent = display_percent(snapshot)
    label = str(percent)
    scale = 1
    inner_width = 14
    text_x = 1 + (inner_width - text_width(label, scale=scale)) // 2
    text_y = 6

    draw_perimeter_meter(draw, theme, percent, x=0, y=0, width=16, height=16)
    draw_text(
        draw,
        label,
        x=text_x,
        y=text_y,
        color=theme["accent"],
        scale=scale,
        shadow=None,
    )
    return img


def draw_vertical_meter(
    draw: ImageDraw.ImageDraw,
    snapshot: UsageSnapshot,
    x: int,
    y: int,
    width: int,
    height: int,
) -> None:
    theme = THEMES[snapshot.provider]
    percent = display_percent(snapshot)
    fill_rows = max(0, min(height, round(height * percent / 100)))
    for row in range(height):
        for col in range(width):
            row_from_bottom = height - row
            if row_from_bottom <= fill_rows:
                ratio = row / max(1, height - 1)
                color = mix(theme["ring"], theme["accent"], ratio)
            else:
                color = mix(theme["base"], theme["panel"], 0.3)
            draw.point((x + col, y + row), fill=color)


def draw_pair_frame(codex_snapshot: UsageSnapshot, claude_snapshot: UsageSnapshot, frame_index: int) -> Image.Image:
    img = Image.new("RGB", (SIZE, SIZE), (10, 12, 18))
    draw = ImageDraw.Draw(img)

    for y in range(SIZE):
        row = mix((10, 12, 18), (18, 20, 28), y / max(1, SIZE - 1))
        for x in range(SIZE):
            draw.point((x, y), fill=row)

    for y in range(1, 15):
        draw.point((7, y), fill=(40, 44, 58))
        draw.point((8, y), fill=(30, 34, 46))

    draw_vertical_meter(draw, claude_snapshot, x=0, y=0, width=3, height=16)
    draw_vertical_meter(draw, codex_snapshot, x=13, y=0, width=3, height=16)

    codex_label = str(display_percent(codex_snapshot))
    claude_label = str(display_percent(claude_snapshot))
    center_lane_x = 3
    center_lane_width = 10
    codex_x = center_lane_x + (center_lane_width - text_width(codex_label, scale=1)) // 2
    claude_x = center_lane_x + (center_lane_width - text_width(claude_label, scale=1)) // 2

    draw_text(
        draw,
        codex_label,
        x=codex_x,
        y=3,
        color=THEMES["codex"]["accent"],
        scale=1,
        shadow=None,
    )
    draw_text(
        draw,
        claude_label,
        x=claude_x,
        y=9,
        color=THEMES["claude"]["accent"],
        scale=1,
        shadow=None,
    )
    return img


def shift_canvas_right(img: Image.Image, pixels: int = 1) -> Image.Image:
    if pixels <= 0:
        return img
    shifted = Image.new(img.mode, img.size, (0, 0, 0))
    shifted.paste(img, (pixels, 0))
    return shifted


def render(snapshot: UsageSnapshot, output_path: Path) -> None:
    frames = [draw_single_frame(snapshot, i) for i in range(FRAME_COUNT)]
    output_path.parent.mkdir(parents=True, exist_ok=True)
    frames[0].save(
        output_path,
        save_all=True,
        append_images=frames[1:],
        duration=70,
        loop=0,
        disposal=2,
    )


def render_pair(codex_snapshot: UsageSnapshot, claude_snapshot: UsageSnapshot, output_path: Path) -> None:
    frames = [draw_pair_frame(codex_snapshot, claude_snapshot, i) for i in range(FRAME_COUNT)]
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
                "selectedMetric": resolved_metric(snapshot),
                "displayMode": "used" if snapshot.show_used else "remaining",
                "displayPercent": display_percent(snapshot),
                "label": display_label(snapshot),
                "output": args.output,
            },
            indent=2,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
