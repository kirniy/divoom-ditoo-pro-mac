#!/usr/bin/env python3
from __future__ import annotations

import argparse
import glob
import hashlib
import io
import json
import math
import os
import subprocess
import sys
import tempfile
import time
import uuid
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable
from urllib.request import Request, urlopen

from PIL import Image, ImageColor, ImageOps, ImageSequence
import serial

from render_status_gif import (
    display_label,
    display_percent,
    render as render_status_gif,
    render_pair as render_status_pair_gif,
    resolved_metric,
    load_usage,
)
from render_generative_gif import render as render_art_gif


CHUNK_SIZE = 256
DEFAULT_BAUDRATE = 115200
ROOT = Path(__file__).resolve().parents[1]
APP_QUERY_PATH = ROOT / "out" / "iphone" / "divoom-app-query.json"
DEFAULT_ROUTE_RESULTS_DIR = ROOT / "out" / "iphone" / "route-tests"
DEFAULT_SHORTCUT_RESULTS_DIR = ROOT / "out" / "iphone" / "shortcut-tests"
DEFAULT_IOS_DEVICE_IDENTIFIER = "CCED4E96-3418-5051-A1F7-9B3BAA89D4C1"
DEFAULT_IOS_UDID = "00008150-000828191141401C"
DEFAULT_IOS_BUNDLE_ID = "com.divoom.Smart"
DEFAULT_IOS_SCHEME = "divoomapp://"
DEFAULT_SHORTCUTS_BUNDLE_ID = "com.apple.shortcuts"
DEFAULT_SHORTCUTS_SCHEME = "shortcuts://"
DEFAULT_AUDIO_DISABLE_FILE = Path(
    os.environ.get("DIVOOM_AUDIO_DISABLE_FILE", "/tmp/divoom-audio-hooks.disabled")
)
DEFAULT_NATIVE_APP_BUNDLE = ROOT / "build" / "DivoomMenuBar.app"
DEFAULT_NATIVE_APP_BINARY = DEFAULT_NATIVE_APP_BUNDLE / "Contents" / "MacOS" / "DivoomMenuBar"
DEFAULT_NATIVE_APP_LOG = Path.home() / "Library" / "Logs" / "DivoomMenuBar.log"
DEFAULT_NATIVE_IPC_ROOT = Path(tempfile.gettempdir()) / "divoom-menubar-ipc"
DEFAULT_NATIVE_IPC_REQUESTS = DEFAULT_NATIVE_IPC_ROOT / "requests"
DEFAULT_NATIVE_IPC_RESULTS = DEFAULT_NATIVE_IPC_ROOT / "results"
DEFAULT_IP_FLAG_CACHE_DIR = ROOT / ".cache" / "ip-flag"
DEFAULT_IP_LOOKUP_CACHE = DEFAULT_IP_FLAG_CACHE_DIR / "lookup.json"
DEFAULT_PALETTE_RENDER_CACHE_DIR = ROOT / ".cache" / "palette-renders"


def discover_ports() -> list[str]:
    return sorted(path for path in glob.glob("/dev/cu.*Ditoo*") if Path(path).exists())


def choose_any_port(explicit: str | None = None) -> str:
    if explicit:
        if Path(explicit).exists():
            return explicit
        raise FileNotFoundError(f"port not found: {explicit}")
    ports = discover_ports()
    if not ports:
        raise FileNotFoundError("no Ditoo serial ports found under /dev/cu.*Ditoo*")
    return ports[-1]


def choose_display_port(explicit: str | None = None) -> str:
    if explicit:
        if Path(explicit).exists():
            return explicit
        raise FileNotFoundError(f"display port not found: {explicit}")
    ports = discover_ports()
    light_ports = [path for path in ports if "Light" in path]
    if light_ports:
        return light_ports[-1]
    audio_ports = [path for path in ports if "Audio" in path]
    if audio_ports:
        return audio_ports[-1]
    raise FileNotFoundError(
        "no Ditoo serial ports found. Pair/connect DitooPro-Audio or DitooPro-Light first."
    )


def choose_audio_port(explicit: str | None = None) -> str:
    if explicit:
        if Path(explicit).exists():
            return explicit
        raise FileNotFoundError(f"audio port not found: {explicit}")
    ports = [path for path in discover_ports() if "Audio" in path]
    if not ports:
        raise FileNotFoundError(
            "no DitooPro-Audio serial port found. Pair/connect the audio-side Bluetooth device first."
        )
    return ports[-1]


def checksum(command: int, payload: bytes) -> int:
    length = len(payload) + 3
    return sum((length & 0xFF, (length >> 8) & 0xFF, command, *payload)) & 0xFFFF


def build_packet(command: int, payload: bytes = b"") -> bytes:
    length = len(payload) + 3
    crc = checksum(command, payload)
    return bytes([0x01, length & 0xFF, (length >> 8) & 0xFF, command, *payload, crc & 0xFF, (crc >> 8) & 0xFF, 0x02])


@dataclass
class Response:
    original_command: int
    ack: bool
    data: bytes


def parse_response(raw: bytes) -> Response:
    if len(raw) < 7:
        raise ValueError("response too short")
    if raw[0] != 0x01 or raw[-1] != 0x02:
        raise ValueError("bad response framing")
    if raw[3] != 0x04:
        raise ValueError(f"unexpected response command byte 0x{raw[3]:02x}")
    return Response(original_command=raw[4], ack=raw[5] == 0x55, data=raw[6:-3])


def read_frame(ser: serial.Serial, timeout_s: float) -> bytes:
    deadline = time.monotonic() + timeout_s
    buf = bytearray()
    while time.monotonic() < deadline:
        chunk = ser.read(1)
        if not chunk:
            continue
        buf.extend(chunk)
        if len(buf) >= 3 and buf[0] == 0x01:
            payload_len = int.from_bytes(buf[1:3], "little")
            frame_len = payload_len + 4
            while len(buf) < frame_len and time.monotonic() < deadline:
                more = ser.read(frame_len - len(buf))
                if not more:
                    continue
                buf.extend(more)
            return bytes(buf)
    return bytes(buf)


class DivoomClient:
    def __init__(
        self,
        port: str | None = None,
        baudrate: int = DEFAULT_BAUDRATE,
        timeout: float = 2.0,
        endpoint: str = "display",
    ):
        if endpoint == "display":
            resolved_port = choose_display_port(port)
        elif endpoint == "audio":
            resolved_port = choose_audio_port(port)
        else:
            resolved_port = choose_any_port(port)
        self.port = resolved_port
        self.baudrate = baudrate
        self.timeout = timeout
        self.serial = serial.Serial(port=self.port, baudrate=self.baudrate, timeout=self.timeout, write_timeout=self.timeout)

    def close(self) -> None:
        if self.serial.is_open:
            self.serial.close()

    def __enter__(self) -> "DivoomClient":
        return self

    def __exit__(self, exc_type, exc, tb) -> None:
        self.close()

    def send(self, command: int, payload: bytes = b"", expect_response: bool = False) -> Response | None:
        packet = build_packet(command, payload)
        self.serial.reset_input_buffer()
        self.serial.write(packet)
        self.serial.flush()
        time.sleep(0.05)
        if not expect_response:
            return None
        raw = read_frame(self.serial, self.timeout)
        if not raw:
            raise TimeoutError(f"no response for command 0x{command:02x}")
        parsed = parse_response(raw)
        if parsed.original_command != command:
            raise RuntimeError(
                f"response command mismatch: expected 0x{command:02x}, got 0x{parsed.original_command:02x}"
            )
        return parsed

    def get_volume(self) -> int:
        response = self.send(0x09, expect_response=True)
        if response is None or not response.data:
            raise RuntimeError("volume response was empty")
        return response.data[0]

    def set_volume(self, value: int) -> None:
        self.send(0x08, bytes([value]))

    def set_brightness(self, value: int) -> None:
        self.send(0x74, bytes([value]))

    def set_playing(self, playing: bool) -> None:
        self.send(0x0A, bytes([1 if playing else 0]))

    def query_light_effect_control(self) -> None:
        self.send(0xBD, bytes([0x33, 0x00]))

    def get_box_mode(self, expect_response: bool = False) -> Response | None:
        return self.send(0x46, expect_response=expect_response)

    def set_light_mode(
        self,
        red: int,
        green: int,
        blue: int,
        brightness: int = 100,
        light_mode: int = 0,
        on: bool = True,
        app_sequence: bool = False,
    ) -> bytes:
        if app_sequence:
            self.query_light_effect_control()
            self.get_box_mode(expect_response=False)
        payload = bytes(
            [
                0x01,
                red & 0xFF,
                green & 0xFF,
                blue & 0xFF,
                brightness & 0xFF,
                light_mode & 0xFF,
                0x01 if on else 0x00,
                0x00,
                0x00,
                0x00,
            ]
        )
        self.send(0x45, payload)
        return payload

    def show_design(self, slot: int = 0) -> None:
        # Community integrations switch to the design channel after working with custom art.
        self.send(0x45, bytes([0x05]))
        self.send(0xBD, bytes([0x17, slot & 0xFF]))

    def upload_animation_bytes(self, payload: bytes, terminate: bool = False) -> dict[str, int]:
        sent_packets = 0
        self.send(0x8B, bytes([0, *len(payload).to_bytes(4, "little")]))
        sent_packets += 1
        for offset, chunk_start in enumerate(range(0, len(payload), CHUNK_SIZE)):
            chunk = payload[chunk_start : chunk_start + CHUNK_SIZE]
            data = bytes([1, *len(payload).to_bytes(4, "little"), *offset.to_bytes(2, "little"), *chunk])
            self.send(0x8B, data)
            sent_packets += 1
            time.sleep(0.04)
        if terminate:
            self.send(0x8B, bytes([2]))
            sent_packets += 1
        return {"bytes": len(payload), "packets": sent_packets}


def resize_rgb(image: Image.Image) -> Image.Image:
    rgb = image.convert("RGBA")
    if rgb.getbbox() is None:
        rgb = Image.new("RGBA", rgb.size, (0, 0, 0, 255))
    flattened = Image.alpha_composite(Image.new("RGBA", rgb.size, (0, 0, 0, 255)), rgb).convert("RGB")
    return ImageOps.fit(flattened, (16, 16), method=Image.Resampling.LANCZOS)


def reduce_palette(image: Image.Image) -> Image.Image:
    rgb = resize_rgb(image)
    colors = rgb.getcolors(maxcolors=257)
    if colors is None:
        return rgb.quantize(colors=256, method=Image.Quantize.MEDIANCUT, dither=Image.Dither.NONE).convert("RGB")
    return rgb


def iter_frames(path: Path) -> Iterable[tuple[Image.Image, int]]:
    with Image.open(path) as image:
        if getattr(image, "is_animated", False):
            for frame in ImageSequence.Iterator(image):
                duration = int(frame.info.get("duration", 70))
                yield reduce_palette(frame), max(20, duration)
        else:
            yield reduce_palette(image), 0


def bits_per_pixel(color_count: int) -> int:
    return max(1, math.ceil(math.log2(max(2, color_count))))


def palette_from_image(image: Image.Image) -> list[tuple[int, int, int]]:
    seen: set[tuple[int, int, int]] = set()
    ordered: list[tuple[int, int, int]] = []
    for y in range(16):
        for x in range(16):
            color = image.getpixel((x, y))
            if color not in seen:
                seen.add(color)
                ordered.append(color)
    return ordered


def pack_indices(indices: Iterable[int], bit_width: int) -> bytes:
    output = bytearray()
    current = 0
    bit_pos = 0
    for value in indices:
        tmp = value
        for _ in range(bit_width):
            if tmp & 1:
                current |= 1 << bit_pos
            tmp >>= 1
            bit_pos += 1
            if bit_pos == 8:
                output.append(current)
                current = 0
                bit_pos = 0
    if bit_pos:
        output.append(current)
    return bytes(output)


def serialize_frame(image: Image.Image, duration_ms: int) -> bytes:
    palette = palette_from_image(image)
    if len(palette) > 256:
        raise ValueError(f"frame has too many colors: {len(palette)}")
    bit_width = bits_per_pixel(len(palette))
    palette_index = {color: index for index, color in enumerate(palette)}
    indices = [palette_index[image.getpixel((x, y))] for y in range(16) for x in range(16)]
    pixel_data = pack_indices(indices, bit_width)
    color_count_byte = 0 if len(palette) == 256 else len(palette)
    frame_length = 7 + len(palette) * 3 + len(pixel_data)
    header = bytearray([0xAA, frame_length & 0xFF, (frame_length >> 8) & 0xFF])
    header.extend(int(duration_ms).to_bytes(2, "little"))
    header.append(0)
    header.append(color_count_byte)
    payload = bytearray(header)
    for r, g, b in palette:
        payload.extend((r, g, b))
    payload.extend(pixel_data)
    return bytes(payload)


def serialize_path(path: Path) -> bytes:
    frames = [serialize_frame(frame, duration_ms) for frame, duration_ms in iter_frames(path)]
    return b"".join(frames)


def render_status(provider: str) -> tuple[Path, dict[str, object]]:
    output = Path(tempfile.gettempdir()) / f"divoom-{provider}-status.gif"
    snapshot = load_usage(provider)
    render_status_gif(snapshot, output)
    selected_metric = resolved_metric(snapshot)
    raw_used = getattr(snapshot, f"{selected_metric}_used", 0) or 0
    display_mode = "used" if snapshot.show_used else "remaining"
    current_display_percent = display_percent(snapshot)
    info = {
        "provider": snapshot.provider,
        "primaryUsed": snapshot.primary_used,
        "secondaryUsed": snapshot.secondary_used,
        "tertiaryUsed": snapshot.tertiary_used,
        "selectedMetric": selected_metric,
        "displayMode": display_mode,
        "displayPercent": current_display_percent,
        "label": display_label(snapshot),
        "output": str(output),
    }
    return output, info


def render_status_pair() -> tuple[Path, dict[str, object]]:
    output = Path(tempfile.gettempdir()) / "divoom-codex-claude-status.gif"

    codex_snapshot = load_usage("codex")
    claude_snapshot = load_usage("claude")
    render_status_pair_gif(codex_snapshot, claude_snapshot, output)
    codex_display_percent = display_percent(codex_snapshot)
    claude_display_percent = display_percent(claude_snapshot)

    info = {
        "provider": "codex+claude",
        "codexPrimaryUsed": codex_snapshot.primary_used,
        "codexSecondaryUsed": codex_snapshot.secondary_used,
        "codexTertiaryUsed": codex_snapshot.tertiary_used,
        "codexSelectedMetric": resolved_metric(codex_snapshot),
        "codexDisplayMode": "used" if codex_snapshot.show_used else "remaining",
        "codexDisplayPercent": codex_display_percent,
        "claudePrimaryUsed": claude_snapshot.primary_used,
        "claudeSecondaryUsed": claude_snapshot.secondary_used,
        "claudeTertiaryUsed": claude_snapshot.tertiary_used,
        "claudeSelectedMetric": resolved_metric(claude_snapshot),
        "claudeDisplayMode": "used" if claude_snapshot.show_used else "remaining",
        "claudeDisplayPercent": claude_display_percent,
        "label": f"Codex {codex_display_percent}% / Claude {claude_display_percent}%",
        "output": str(output),
    }
    return output, info


def read_json_url(url: str, timeout: float = 2.5) -> dict[str, object]:
    request = Request(url, headers={"User-Agent": "DivoomDitooProMac/1.0"})
    with urlopen(request, timeout=timeout) as response:
        return json.loads(response.read().decode("utf-8"))


def normalize_country_code(value: object) -> str:
    country = str(value or "").strip().upper()
    return country if len(country) == 2 else ""


def load_cached_ip_lookup(max_age: float | None = None) -> dict[str, str] | None:
    if not DEFAULT_IP_LOOKUP_CACHE.exists():
        return None
    try:
        cached = json.loads(DEFAULT_IP_LOOKUP_CACHE.read_text())
        cached_at = float(cached.get("cachedAt", 0))
        if max_age is not None and time.time() - cached_at > max_age:
            return None
        return {
            "ip": str(cached.get("ip") or "").strip(),
            "country": str(cached.get("country") or "").strip().upper(),
            "city": str(cached.get("city") or "").strip(),
            "region": str(cached.get("region") or "").strip(),
            "source": str(cached.get("source") or "cache"),
        }
    except Exception:
        return None


def lookup_public_ip_country() -> dict[str, str]:
    cached = load_cached_ip_lookup(max_age=30)
    if cached is not None:
        return cached

    providers = [
        (
            "cloudflare-trace",
            "https://www.cloudflare.com/cdn-cgi/trace",
            lambda payload: {
                "ip": str(payload.get("ip") or "").strip(),
                "country": normalize_country_code(payload.get("loc")),
                "city": "",
                "region": "",
            },
        ),
        (
            "ipinfo",
            "https://ipinfo.io/json",
            lambda payload: {
                "ip": str(payload.get("ip") or "").strip(),
                "country": normalize_country_code(payload.get("country")),
                "city": str(payload.get("city") or "").strip(),
                "region": str(payload.get("region") or "").strip(),
            },
        ),
        (
            "ipapi",
            "https://ipapi.co/json/",
            lambda payload: {
                "ip": str(payload.get("ip") or "").strip(),
                "country": normalize_country_code(payload.get("country_code")),
                "city": str(payload.get("city") or "").strip(),
                "region": str(payload.get("region") or "").strip(),
            },
        ),
        (
            "ip-api",
            "http://ip-api.com/json/",
            lambda payload: {
                "ip": str(payload.get("query") or "").strip(),
                "country": normalize_country_code(payload.get("countryCode")),
                "city": str(payload.get("city") or "").strip(),
                "region": str(payload.get("regionName") or "").strip(),
            },
        ),
    ]

    errors: list[str] = []
    for name, url, parser in providers:
        try:
            if name == "cloudflare-trace":
                request = Request(url, headers={"User-Agent": "DivoomDitooProMac/1.0"})
                with urlopen(request, timeout=1.2) as response:
                    body = response.read().decode("utf-8")
                payload = dict(
                    line.split("=", 1)
                    for line in body.splitlines()
                    if "=" in line
                )
                resolved = parser(payload)
            else:
                resolved = parser(read_json_url(url, timeout=1.2))
        except Exception as exc:
            errors.append(f"{name}: {exc}")
            continue
        if resolved["country"]:
            resolved["source"] = name
            return resolved
        errors.append(f"{name}: invalid country code")

    stale_cached = load_cached_ip_lookup(max_age=None)
    if stale_cached is not None and stale_cached.get("country"):
        stale_cached["source"] = f"{stale_cached.get('source', 'cache')} (stale)"
        return stale_cached

    raise RuntimeError("Could not determine public IP country. " + "; ".join(errors))


def render_ip_flag() -> tuple[Path, dict[str, object]]:
    lookup = lookup_public_ip_country()
    country = lookup["country"].lower()
    DEFAULT_IP_FLAG_CACHE_DIR.mkdir(parents=True, exist_ok=True)
    try:
        DEFAULT_IP_LOOKUP_CACHE.write_text(
            json.dumps({"cachedAt": time.time(), **lookup}),
            encoding="utf-8",
        )
    except Exception:
        pass

    output = DEFAULT_IP_FLAG_CACHE_DIR / f"{country}.gif"
    if output.exists():
        info = {
            "provider": "ip-flag",
            "ip": lookup["ip"],
            "country": lookup["country"],
            "city": lookup["city"],
            "region": lookup["region"],
            "source": lookup.get("source", ""),
            "label": f"IP Flag {lookup['country']}",
            "output": str(output),
        }
        return output, info

    png_cache = DEFAULT_IP_FLAG_CACHE_DIR / f"{country}.png"
    if png_cache.exists():
        raw = png_cache.read_bytes()
    else:
        flag_url = f"https://flagcdn.com/w80/{country}.png"
        request = Request(flag_url, headers={"User-Agent": "DivoomDitooProMac/1.0"})
        with urlopen(request, timeout=3.0) as response:
            raw = response.read()
        png_cache.write_bytes(raw)

    source = Image.open(io.BytesIO(raw)).convert("RGB")
    fitted = ImageOps.fit(source, (16, 12), method=Image.Resampling.BILINEAR, centering=(0.5, 0.5))
    fitted = lift_ditoo_black(fitted)

    frames: list[Image.Image] = []
    for index in range(12):
        frame = Image.new("RGB", (16, 16), (6, 8, 12))
        wave = index / 12.0 * math.tau
        for y in range(12):
            row = fitted.crop((0, y, 16, y + 1))
            offset = round(math.sin(wave + y * 0.45) * 1.6)
            frame.paste(row, (offset, y + 2))
        shine_x = (index * 2) % 20 - 2
        for x in range(max(0, shine_x), min(16, shine_x + 3)):
            for y in range(2, 14):
                base = frame.getpixel((x, y))
                frame.putpixel((x, y), tuple(min(255, channel + 28) for channel in base))
        frames.append(frame)

    frames[0].save(
        output,
        save_all=True,
        append_images=frames[1:],
        duration=80,
        loop=0,
        disposal=2,
    )
    info = {
        "provider": "ip-flag",
        "ip": lookup["ip"],
        "country": lookup["country"],
        "city": lookup["city"],
        "region": lookup["region"],
        "source": lookup.get("source", ""),
        "label": f"IP Flag {lookup['country']}",
        "output": str(output),
    }
    return output, info


def lerp_channel(left: int, right: int, fraction: float) -> int:
    return max(0, min(255, round(left + (right - left) * fraction)))


def sample_palette(colors: list[tuple[int, int, int]], t: float) -> tuple[int, int, int]:
    if len(colors) == 1:
        return colors[0]
    clamped = max(0.0, min(0.999999, t))
    scaled = clamped * (len(colors) - 1)
    index = int(math.floor(scaled))
    fraction = scaled - index
    left = colors[index]
    right = colors[min(index + 1, len(colors) - 1)]
    return (
        lerp_channel(left[0], right[0], fraction),
        lerp_channel(left[1], right[1], fraction),
        lerp_channel(left[2], right[2], fraction),
    )


def brighten(color: tuple[int, int, int], amount: int) -> tuple[int, int, int]:
    return tuple(min(255, channel + amount) for channel in color)


def render_palette_animation(mode: str, colors: list[tuple[int, int, int]]) -> tuple[Path, dict[str, object]]:
    if not colors:
        raise ValueError("at least one color is required")

    DEFAULT_PALETTE_RENDER_CACHE_DIR.mkdir(parents=True, exist_ok=True)
    normalized = [f"{red:02x}{green:02x}{blue:02x}" for red, green, blue in colors]
    cache_key = hashlib.sha1(f"{mode}|{'-'.join(normalized)}".encode("utf-8")).hexdigest()[:16]
    output = DEFAULT_PALETTE_RENDER_CACHE_DIR / f"{mode}-{cache_key}.gif"

    if output.exists():
        return output, {
            "provider": "palette",
            "mode": mode,
            "colors": [f"#{value.upper()}" for value in normalized],
            "label": f"{mode.replace('-', ' ').title()} · {' '.join(f'#{value.upper()}' for value in normalized[:4])}",
            "output": str(output),
        }

    frames: list[Image.Image] = []
    durations: list[int] = []
    frame_count = 24 if mode != "palette-steps" else max(len(colors) * 4, 12)

    for frame_index in range(frame_count):
        image = Image.new("RGB", (16, 16), (0, 0, 0))
        if mode == "gradient-sweep":
            offset = frame_index / frame_count
            for y in range(16):
                for x in range(16):
                    t = ((x / 15.0) + offset + (y / 15.0) * 0.18) % 1.0
                    image.putpixel((x, y), sample_palette(colors, t))
            durations.append(70)
        elif mode == "ribbon-wave":
            offset = frame_index / frame_count * math.tau
            for y in range(16):
                band = (math.sin(offset + y * 0.46) + 1.0) / 2.0
                band_color = sample_palette(colors, band)
                for x in range(16):
                    shimmer = (math.sin(offset * 1.4 + x * 0.72 + y * 0.2) + 1.0) / 2.0
                    image.putpixel((x, y), brighten(band_color, round(shimmer * 26)))
            durations.append(72)
        elif mode == "diamond-bloom":
            center = 7.5
            phase = (math.sin(frame_index / frame_count * math.tau) + 1.0) / 2.0
            for y in range(16):
                for x in range(16):
                    distance = (abs(x - center) + abs(y - center)) / 15.0
                    t = (phase + distance * 0.82) % 1.0
                    color = sample_palette(colors, t)
                    boost = max(0, 24 - round(distance * 18))
                    image.putpixel((x, y), brighten(color, boost))
            durations.append(76)
        elif mode == "pulse":
            base_t = frame_index / frame_count
            base_color = sample_palette(colors, base_t)
            pulse = 0.58 + 0.42 * ((math.sin(frame_index / frame_count * math.tau) + 1.0) / 2.0)
            for y in range(16):
                for x in range(16):
                    distance = abs(x - 7.5) + abs(y - 7.5)
                    falloff = max(0.55, 1.0 - distance / 24.0)
                    scale = pulse * falloff
                    image.putpixel(
                        (x, y),
                        (
                            round(base_color[0] * scale),
                            round(base_color[1] * scale),
                            round(base_color[2] * scale),
                        ),
                    )
            durations.append(80)
        elif mode == "aurora":
            offset = frame_index / frame_count * math.tau
            for y in range(16):
                for x in range(16):
                    wave = math.sin(offset + x * 0.38 + y * 0.16) * 0.5 + 0.5
                    drift = math.sin(offset * 0.7 + y * 0.42) * 0.12
                    t = (wave + drift) % 1.0
                    color = sample_palette(colors, t)
                    image.putpixel((x, y), brighten(color, 10 if y < 5 else 0))
            durations.append(75)
        elif mode == "checker-shift":
            offset = frame_index / frame_count
            for y in range(16):
                for x in range(16):
                    cell = (x + y + frame_index) % 2
                    diagonal = ((x + y) / 30.0 + offset) % 1.0
                    base = sample_palette(colors, diagonal if cell == 0 else (diagonal + 0.33) % 1.0)
                    image.putpixel((x, y), brighten(base, 18 if cell == 0 else 0))
            durations.append(82)
        elif mode == "palette-steps":
            palette_index = (frame_index // 4) % len(colors)
            color = colors[palette_index]
            accent = brighten(color, 36)
            image.paste(color, (0, 0, 16, 16))
            for x in range(16):
                image.putpixel((x, 0), accent)
                image.putpixel((x, 15), accent)
            for y in range(16):
                image.putpixel((0, y), accent)
                image.putpixel((15, y), accent)
            durations.append(110)
        else:
            raise ValueError(f"unsupported palette mode: {mode}")
        frames.append(image)

    frames[0].save(
        output,
        save_all=True,
        append_images=frames[1:],
        loop=0,
        duration=durations,
        optimize=False,
        disposal=2,
    )

    label_mode = mode.replace("-", " ").title()
    info = {
        "provider": "palette",
        "mode": mode,
        "colors": [f"#{value.upper()}" for value in normalized],
        "label": f"{label_mode} · {' '.join(f'#{value.upper()}' for value in normalized[:4])}",
        "output": str(output),
    }
    return output, info


def lift_ditoo_black(image: Image.Image) -> Image.Image:
    lifted = image.copy()
    for y in range(lifted.height):
        for x in range(lifted.width):
            red, green, blue = lifted.getpixel((x, y))
            if max(red, green, blue) <= 24:
                lifted.putpixel((x, y), (44, 48, 60))
            elif max(red, green, blue) <= 42:
                lifted.putpixel((x, y), (58, 64, 78))
    return lifted


def render_art(style: str, seed: int) -> tuple[Path, dict[str, object]]:
    output = Path(tempfile.gettempdir()) / f"divoom-art-{style}-{seed}.gif"
    render_art_gif(style, seed, output)
    return output, {"style": style, "seed": seed, "output": str(output)}


def current_output_device() -> str:
    return subprocess.check_output(
        ["/opt/homebrew/bin/SwitchAudioSource", "-c", "-t", "output"],
        text=True,
    ).strip()


def switch_output_device(name: str) -> None:
    subprocess.check_call(["/opt/homebrew/bin/SwitchAudioSource", "-t", "output", "-s", name])


def available_output_devices() -> list[str]:
    output = subprocess.check_output(
        ["/opt/homebrew/bin/SwitchAudioSource", "-a", "-t", "output"],
        text=True,
    )
    return [line.strip() for line in output.splitlines() if line.strip()]


def sound_path_for_profile(profile: str) -> str:
    sounds_dir = ROOT / "assets" / "sounds" / "openpeon-cute-minimal"
    candidates = {
        "attention": sounds_dir / "hover-sound-low.wav",
        "complete": sounds_dir / "confirm-sound.wav",
        "color-set": sounds_dir / "confirm-sound.wav",
        "animation": sounds_dir / "pause-sound.wav",
        "error": sounds_dir / "cancel-sound-low.wav",
    }
    path = candidates[profile]
    if path.exists():
        return str(path)
    raise FileNotFoundError(f"no sound found for profile {profile}: {path}")


def audio_is_disabled() -> bool:
    return DEFAULT_AUDIO_DISABLE_FILE.exists()


def default_volume_for_profile(profile: str) -> float:
    volumes = {
        "attention": 0.10,
        "complete": 0.13,
        "color-set": 0.12,
        "animation": 0.14,
        "error": 0.09,
    }
    return volumes[profile]


def play_sound_via_divoom(profile: str, volume: float | None = None) -> dict[str, str]:
    if audio_is_disabled():
        return {
            "profile": profile,
            "skipped": "audio-disabled",
            "disableFile": str(DEFAULT_AUDIO_DISABLE_FILE),
        }
    sound_path = sound_path_for_profile(profile)
    resolved_volume = default_volume_for_profile(profile) if volume is None else volume
    subprocess.check_call(["/usr/bin/afplay", "-v", f"{resolved_volume:.2f}", sound_path])
    return {"profile": profile, "soundPath": sound_path, "volume": f"{resolved_volume:.2f}", "output": "current-default"}


def parse_color_triplet(color: str) -> tuple[int, int, int]:
    red, green, blue = ImageColor.getrgb(color)
    return int(red), int(green), int(blue)


def load_iphone_activity_types(path: Path = APP_QUERY_PATH) -> list[str]:
    if not path.exists():
        raise FileNotFoundError(f"app query JSON not found: {path}")
    data = json.loads(path.read_text())
    app_info = data.get(DEFAULT_IOS_BUNDLE_ID, {})
    items = app_info.get("NSUserActivityTypes", [])
    routes = [str(item).strip() for item in items if str(item).strip()]
    return sorted(set(routes))


def run_iphone_route(
    *,
    route: str,
    device: str,
    udid: str,
    bundle_id: str,
    scheme: str,
    results_dir: Path,
    activate: bool,
    terminate_existing: bool,
    capture_syslog: bool,
    syslog_seconds: float,
) -> dict[str, object]:
    script = ROOT / "tools" / "test_divoomapp_routes.py"
    if not script.exists():
        raise FileNotFoundError(f"route script not found: {script}")

    command = [
        sys.executable,
        str(script),
        route,
        "--device",
        device,
        "--udid",
        udid,
        "--bundle-id",
        bundle_id,
        "--scheme",
        scheme,
        "--results-dir",
        str(results_dir),
        "--syslog-seconds",
        str(syslog_seconds),
    ]
    command.append("--activate" if activate else "--no-activate")
    command.append("--terminate-existing" if terminate_existing else "--no-terminate-existing")
    if capture_syslog:
        command.append("--capture-syslog")

    completed = subprocess.run(command, check=False, text=True, capture_output=True)

    route_stem = "".join(ch if ch.isalnum() or ch in ("-", "_", ".") else "_" for ch in route)
    launch_json = results_dir / f"{route_stem}-launch.json"
    syslog_path = results_dir / f"{route_stem}-syslog.txt"

    result: dict[str, object] = {
        "route": route,
        "display": {"type": "RGB", "pixels": "16x16"},
        "bundleId": bundle_id,
        "device": device,
        "udid": udid,
        "scheme": scheme,
        "activate": activate,
        "terminateExisting": terminate_existing,
        "captureSyslog": capture_syslog,
        "syslogSeconds": syslog_seconds,
        "exitCode": completed.returncode,
        "stdout": completed.stdout.strip(),
        "stderr": completed.stderr.strip(),
        "launchJson": str(launch_json),
    }
    if syslog_path.exists():
        result["syslogPath"] = str(syslog_path)
    if launch_json.exists():
        try:
            launch_data = json.loads(launch_json.read_text())
        except json.JSONDecodeError:
            pass
        else:
            result["launchResult"] = launch_data
    return result


def build_shortcuts_url(
    *,
    action: str,
    name: str | None = None,
    text: str | None = None,
    use_clipboard: bool = False,
) -> str:
    from urllib.parse import urlencode

    if action == "open":
        return DEFAULT_SHORTCUTS_SCHEME
    if action == "create":
        return f"{DEFAULT_SHORTCUTS_SCHEME}create-shortcut"
    if action == "open-shortcut":
        if not name:
            raise ValueError("shortcut name is required for open-shortcut")
        return f"{DEFAULT_SHORTCUTS_SCHEME}open-shortcut?{urlencode({'name': name})}"
    if action == "run":
        if not name:
            raise ValueError("shortcut name is required for run")
        query: dict[str, str] = {"name": name}
        if use_clipboard:
            query["input"] = "clipboard"
        elif text is not None:
            query["input"] = "text"
            query["text"] = text
        return f"{DEFAULT_SHORTCUTS_SCHEME}run-shortcut?{urlencode(query)}"
    raise ValueError(f"unsupported shortcuts action: {action}")


def run_ios_payload_url(
    *,
    bundle_id: str,
    payload_url: str,
    device: str,
    results_dir: Path,
    result_name: str,
    activate: bool,
    terminate_existing: bool,
) -> dict[str, object]:
    results_dir.mkdir(parents=True, exist_ok=True)
    launch_json = results_dir / f"{result_name}.json"
    command = [
        "xcrun",
        "devicectl",
        "device",
        "process",
        "launch",
        "--device",
        device,
        "--payload-url",
        payload_url,
        "--activate" if activate else "--no-activate",
    ]
    if terminate_existing:
        command.append("--terminate-existing")
    command.extend(["--json-output", str(launch_json), bundle_id])
    completed = subprocess.run(command, check=False, text=True, capture_output=True)

    result: dict[str, object] = {
        "display": {"type": "RGB", "pixels": "16x16"},
        "bundleId": bundle_id,
        "device": device,
        "payloadUrl": payload_url,
        "activate": activate,
        "terminateExisting": terminate_existing,
        "exitCode": completed.returncode,
        "stdout": completed.stdout.strip(),
        "stderr": completed.stderr.strip(),
        "launchJson": str(launch_json),
    }
    if launch_json.exists():
        try:
            launch_data = json.loads(launch_json.read_text())
        except json.JSONDecodeError:
            pass
        else:
            result["launchResult"] = launch_data
            error_info = launch_data.get("error")
            if error_info:
                result["launchError"] = {
                    "domain": error_info.get("domain"),
                    "code": error_info.get("code"),
                    "description": (
                        error_info.get("userInfo", {})
                        .get("NSLocalizedDescription", {})
                        .get("string")
                    ),
                    "failureReason": (
                        error_info.get("userInfo", {})
                        .get("NSUnderlyingError", {})
                        .get("error", {})
                        .get("userInfo", {})
                        .get("NSLocalizedFailureReason", {})
                        .get("string")
                    ),
                }
    return result


def cmd_ports(_args: argparse.Namespace) -> int:
    print(json.dumps({"ports": discover_ports()}, indent=2))
    return 0


def cmd_probe(args: argparse.Namespace) -> int:
    endpoint = args.endpoint
    if endpoint == "display":
        port = choose_display_port(args.port)
    elif endpoint == "audio":
        port = choose_audio_port(args.port)
    else:
        port = choose_any_port(args.port)
    with DivoomClient(port=port, baudrate=args.baudrate, timeout=args.timeout, endpoint=endpoint if endpoint != "any" else "any") as client:
        payload = bytes.fromhex(args.payload) if args.payload.strip() else b""
        response = client.send(int(args.command, 16), payload, expect_response=args.expect_response)
        result = {"port": port, "command": args.command, "payload": payload.hex()}
        if response:
            result["response"] = {
                "originalCommand": f"0x{response.original_command:02x}",
                "ack": response.ack,
                "dataHex": response.data.hex(),
            }
        print(json.dumps(result, indent=2))
    return 0


def cmd_volume_get(args: argparse.Namespace) -> int:
    with DivoomClient(port=args.port, endpoint="audio") as client:
        print(json.dumps({"port": client.port, "volume": client.get_volume()}, indent=2))
    return 0


def cmd_volume_set(args: argparse.Namespace) -> int:
    with DivoomClient(port=args.port, endpoint="audio") as client:
        client.set_volume(args.value)
        print(json.dumps({"port": client.port, "volumeSet": args.value}, indent=2))
    return 0


def cmd_brightness(args: argparse.Namespace) -> int:
    with DivoomClient(port=args.port, endpoint="display") as client:
        client.set_brightness(args.value)
        print(json.dumps({"port": client.port, "brightnessSet": args.value}, indent=2))
    return 0


def cmd_light_mode(args: argparse.Namespace) -> int:
    red, green, blue = parse_color_triplet(args.color)
    with DivoomClient(port=args.port, endpoint="display") as client:
        payload = client.set_light_mode(
            red=red,
            green=green,
            blue=blue,
            brightness=args.brightness,
            light_mode=args.light_mode,
            on=args.on,
            app_sequence=args.app_sequence,
        )
        print(
            json.dumps(
                {
                    "port": client.port,
                    "display": {"type": "RGB", "pixels": "16x16"},
                    "color": f"#{red:02X}{green:02X}{blue:02X}",
                    "brightness": args.brightness,
                    "lightMode": args.light_mode,
                    "on": args.on,
                    "appSequence": args.app_sequence,
                    "payload": payload.hex(),
                },
                indent=2,
            )
        )
    return 0


def cmd_send_file(args: argparse.Namespace) -> int:
    path = Path(args.path).expanduser().resolve()
    payload = serialize_path(path)
    with DivoomClient(port=args.port, endpoint="display") as client:
        result = client.upload_animation_bytes(payload, terminate=args.terminate)
        client.show_design()
        result.update({"port": client.port, "path": str(path)})
        print(json.dumps(result, indent=2))
    return 0


def cmd_send_divoom16(args: argparse.Namespace) -> int:
    path = Path(args.path).expanduser().resolve()
    payload = path.read_bytes()
    with DivoomClient(port=args.port, endpoint="display") as client:
        result = client.upload_animation_bytes(payload, terminate=args.terminate)
        client.show_design()
        result.update({"port": client.port, "path": str(path), "format": "divoom16"})
        print(json.dumps(result, indent=2))
    return 0


def cmd_send_status(args: argparse.Namespace) -> int:
    output, info = render_status(args.provider)
    payload = serialize_path(output)
    with DivoomClient(port=args.port, endpoint="display") as client:
        result = client.upload_animation_bytes(payload, terminate=args.terminate)
        client.show_design()
        result.update({"port": client.port, **info})
        print(json.dumps(result, indent=2))
    return 0


def cmd_send_status_pair(args: argparse.Namespace) -> int:
    output, info = render_status_pair()
    payload = serialize_path(output)
    with DivoomClient(port=args.port, endpoint="display") as client:
        result = client.upload_animation_bytes(payload, terminate=args.terminate)
        client.show_design()
        result.update({"port": client.port, **info})
        print(json.dumps(result, indent=2))
    return 0


def cmd_send_ip_flag(args: argparse.Namespace) -> int:
    output, info = render_ip_flag()
    payload = serialize_path(output)
    with DivoomClient(port=args.port, endpoint="display") as client:
        result = client.upload_animation_bytes(payload, terminate=args.terminate)
        client.show_design()
        result.update({"port": client.port, **info})
        print(json.dumps(result, indent=2))
    return 0


def cmd_render_feed(args: argparse.Namespace) -> int:
    if args.feed == "pair":
        output, info = render_status_pair()
    elif args.feed == "ip-flag":
        output, info = render_ip_flag()
    else:
        output, info = render_status(args.feed)
    serialized_output = Path(tempfile.gettempdir()) / f"divoom-render-feed-{args.feed}.divoom16"
    serialized_output.write_bytes(serialize_path(output))
    print(json.dumps({"output": str(output), "serializedOutput": str(serialized_output), **info}, indent=2))
    return 0


def cmd_render_palette(args: argparse.Namespace) -> int:
    if len(args.color) < 3 or len(args.color) > 10:
        raise ValueError("render-palette requires between 3 and 10 colors")
    colors = [parse_color_triplet(value) for value in args.color]
    output, info = render_palette_animation(args.mode, colors)
    print(json.dumps({"output": str(output), **info}, indent=2))
    return 0


def cmd_send_art(args: argparse.Namespace) -> int:
    output, info = render_art(args.style, args.seed)
    payload = serialize_path(output)
    with DivoomClient(port=args.port, endpoint="display") as client:
        result = client.upload_animation_bytes(payload, terminate=args.terminate)
        client.show_design()
        result.update({"port": client.port, **info})
        print(json.dumps(result, indent=2))
    return 0


def cmd_send_text(args: argparse.Namespace) -> int:
    output = Path(tempfile.gettempdir()) / "divoom-text.png"
    subprocess.check_call(
        [
            sys.executable,
            "-c",
            (
                "from PIL import Image, ImageDraw, ImageFont;"
                "img=Image.new('RGB',(16,16),(0,0,0));"
                "draw=ImageDraw.Draw(img);"
                "font=ImageFont.load_default();"
                f"text={args.text!r};"
                "bbox=draw.multiline_textbbox((0,0), text, font=font, spacing=0);"
                "w=bbox[2]-bbox[0]; h=bbox[3]-bbox[1];"
                "x=(16-w)//2; y=(16-h)//2;"
                "draw.multiline_text((x,y), text, font=font, fill=(255,220,150), spacing=0, align='center');"
                f"img.save({str(output)!r})"
            ),
        ]
    )
    payload = serialize_path(output)
    with DivoomClient(port=args.port, endpoint="display") as client:
        result = client.upload_animation_bytes(payload, terminate=args.terminate)
        client.show_design()
        result.update({"port": client.port, "text": args.text, "output": str(output)})
        print(json.dumps(result, indent=2))
    return 0


def cmd_show_design(args: argparse.Namespace) -> int:
    with DivoomClient(port=args.port, endpoint="display") as client:
        client.show_design(args.slot)
        print(json.dumps({"port": client.port, "designSlot": args.slot}, indent=2))
    return 0


def cmd_play_sound(args: argparse.Namespace) -> int:
    result = play_sound_via_divoom(args.profile, volume=args.volume)
    print(json.dumps(result, indent=2))
    return 0


def cmd_ios_routes(_args: argparse.Namespace) -> int:
    print(
        json.dumps(
            {
                "bundleId": DEFAULT_IOS_BUNDLE_ID,
                "display": {"type": "RGB", "pixels": "16x16"},
                "routes": load_iphone_activity_types(),
            },
            indent=2,
        )
    )
    return 0


def cmd_ios_route(args: argparse.Namespace) -> int:
    result = run_iphone_route(
        route=args.route,
        device=args.device,
        udid=args.udid,
        bundle_id=args.bundle_id,
        scheme=args.scheme,
        results_dir=args.results_dir,
        activate=args.activate,
        terminate_existing=args.terminate_existing,
        capture_syslog=args.capture_syslog,
        syslog_seconds=args.syslog_seconds,
    )
    print(json.dumps(result, indent=2))
    return 0


def cmd_ios_shortcut(args: argparse.Namespace) -> int:
    payload_url = build_shortcuts_url(
        action=args.action,
        name=args.name,
        text=args.text,
        use_clipboard=args.input == "clipboard",
    )
    suffix_parts = [args.action]
    if args.name:
        suffix_parts.append("".join(ch if ch.isalnum() or ch in ("-", "_", ".") else "_" for ch in args.name))
    if args.input == "clipboard":
        suffix_parts.append("clipboard")
    elif args.text is not None:
        suffix_parts.append("text")
    result = run_ios_payload_url(
        bundle_id=args.bundle_id,
        payload_url=payload_url,
        device=args.device,
        results_dir=args.results_dir,
        result_name="-".join(suffix_parts),
        activate=args.activate,
        terminate_existing=args.terminate_existing,
    )
    result["shortcutAction"] = args.action
    if args.name:
        result["shortcutName"] = args.name
    if args.text is not None:
        result["text"] = args.text
    if args.input != "none":
        result["input"] = args.input
    print(json.dumps(result, indent=2))
    return 0


def open_native_app() -> dict[str, object]:
    if not DEFAULT_NATIVE_APP_BUNDLE.exists():
        raise FileNotFoundError(f"native app bundle not found: {DEFAULT_NATIVE_APP_BUNDLE}")
    ensure_single_native_app_instance()
    return {
        "bundle": str(DEFAULT_NATIVE_APP_BUNDLE),
        "display": {"type": "RGB", "pixels": "16x16"},
        "status": "opened",
    }


def running_native_app_pids() -> list[int]:
    result = subprocess.run(
        ["pgrep", "-f", str(DEFAULT_NATIVE_APP_BINARY)],
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode not in (0, 1):
        return []
    pids: list[int] = []
    for line in result.stdout.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            pids.append(int(line))
        except ValueError:
            continue
    return sorted(set(pids))


def ensure_single_native_app_instance(force_restart: bool = False) -> None:
    if not DEFAULT_NATIVE_APP_BUNDLE.exists():
        raise FileNotFoundError(f"native app bundle not found: {DEFAULT_NATIVE_APP_BUNDLE}")

    pids = running_native_app_pids()
    should_restart = force_restart or len(pids) != 1
    if should_restart:
        if pids:
            subprocess.run(["pkill", "-f", str(DEFAULT_NATIVE_APP_BINARY)], check=False)
            time.sleep(0.8)
        subprocess.run(["open", "-a", str(DEFAULT_NATIVE_APP_BUNDLE)], check=True)
        time.sleep(1.5)
        return
    return


def run_native_headless(mode: str, parameter: str | None = None) -> dict[str, object]:
    if not DEFAULT_NATIVE_APP_BUNDLE.exists():
        raise FileNotFoundError(f"native app bundle not found: {DEFAULT_NATIVE_APP_BUNDLE}")
    DEFAULT_NATIVE_IPC_REQUESTS.mkdir(parents=True, exist_ok=True)
    DEFAULT_NATIVE_IPC_RESULTS.mkdir(parents=True, exist_ok=True)
    DEFAULT_NATIVE_APP_LOG.parent.mkdir(parents=True, exist_ok=True)
    DEFAULT_NATIVE_APP_LOG.touch(exist_ok=True)
    start_offset = DEFAULT_NATIVE_APP_LOG.stat().st_size
    ensure_single_native_app_instance()

    def dispatch_request() -> tuple[dict[str, object] | None, str]:
        request_id = str(uuid.uuid4())
        request_path = DEFAULT_NATIVE_IPC_REQUESTS / f"{request_id}.json"
        result_path = DEFAULT_NATIVE_IPC_RESULTS / f"{request_id}.json"
        request_payload = {
            "id": request_id,
            "mode": mode,
            "parameter": parameter,
            "createdAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        }
        request_path.write_text(json.dumps(request_payload), encoding="utf-8")

        deadline = time.time() + 45
        result_payload: dict[str, object] | None = None
        while time.time() < deadline:
            if result_path.exists():
                result_payload = json.loads(result_path.read_text(encoding="utf-8"))
                break
            time.sleep(0.25)

        with DEFAULT_NATIVE_APP_LOG.open("rb") as handle:
            handle.seek(start_offset)
            log_tail = handle.read().decode("utf-8", errors="replace").strip()

        try:
            request_path.unlink(missing_ok=True)
            result_path.unlink(missing_ok=True)
        except OSError:
            pass

        return result_payload, log_tail

    result_payload, log_tail = dispatch_request()
    if result_payload is not None and not bool(result_payload.get("success")):
        details = str(result_payload.get("details", ""))
        if "BLE light transport not ready" in details:
            time.sleep(6)
            result_payload, log_tail = dispatch_request()

    if result_payload is None:
        ensure_single_native_app_instance(force_restart=True)
        result_payload, log_tail = dispatch_request()

    if result_payload is None:
        return {
            "bundle": str(DEFAULT_NATIVE_APP_BUNDLE),
            "binary": str(DEFAULT_NATIVE_APP_BINARY),
            "log": str(DEFAULT_NATIVE_APP_LOG),
            "display": {"type": "RGB", "pixels": "16x16"},
            "mode": mode,
            "parameter": parameter,
            "success": False,
            "returncode": 2,
            "stdout": log_tail,
            "stderr": "Timed out waiting for the running Divoom Menu Bar app to process the IPC request.",
        }

    success = bool(result_payload.get("success"))
    exit_code = int(result_payload.get("exitCode", 1))
    return {
        "bundle": str(DEFAULT_NATIVE_APP_BUNDLE),
        "binary": str(DEFAULT_NATIVE_APP_BINARY),
        "log": str(DEFAULT_NATIVE_APP_LOG),
        "display": {"type": "RGB", "pixels": "16x16"},
        "mode": mode,
        "parameter": parameter,
        "returncode": exit_code,
        "stdout": result_payload.get("details", log_tail),
        "stderr": "",
        "success": success,
    }


def cmd_native_open_app(_args: argparse.Namespace) -> int:
    print(json.dumps(open_native_app(), indent=2))
    return 0


def cmd_native_headless(args: argparse.Namespace) -> int:
    mode_map = {
        "diagnostics": "--headless-diagnostics",
        "probe": "--headless-native-probe",
        "scene-red": "--headless-native-solid-red",
        "scene-color": "--headless-native-scene-color",
        "purity-red": "--headless-native-purity-red",
        "purity-color": "--headless-native-purity-color",
        "pixel-test": "--headless-native-pixel-test",
        "battery-status": "--headless-native-battery-status",
        "system-status": "--headless-native-system-status",
        "memory-status": "--headless-native-memory-status",
        "thermal-status": "--headless-native-thermal-status",
        "network-status": "--headless-native-network-status",
        "animation-sample": "--headless-native-animation-sample",
        "sample": "--headless-native-sample",
        "animation-upload": "--headless-native-animation-upload",
        "animated-monitor": "--headless-native-animated-monitor",
        "clock-face": "--headless-native-clock-face",
        "animated-clock": "--headless-native-animated-clock",
        "pomodoro-timer": "--headless-native-pomodoro-timer",
        "read-key-config": "--headless-native-read-optional-key-config",
        "reset-key-config": "--headless-native-reset-optional-key-config",
    }
    parameter = None
    if args.action == "light-mode":
        mode = "--headless-native-light-mode"
        parameter = str(args.value)
    elif args.action in {"scene-color", "purity-color"}:
        red, green, blue = ImageColor.getrgb(args.color)
        parameter = f"{red:02x}{green:02x}{blue:02x}"
        mode = mode_map[args.action]
    elif args.action == "animation-upload":
        mode = mode_map[args.action]
        parameter = str(Path(args.path).expanduser().resolve()) if args.path else None
    elif args.action in {"send-gif", "animation-verify", "animation-upload-oldmode"}:
        input_path = Path(args.path).expanduser().resolve()
        if not input_path.exists():
            print(json.dumps({"error": "FileNotFoundError", "message": f"file not found: {input_path}"}, indent=2), file=sys.stderr)
            return 1
        if input_path.suffix == ".divoom16":
            divoom16_path = input_path
        else:
            divoom16_path = Path(tempfile.gettempdir()) / f"divoom-{args.action}-{input_path.stem}.divoom16"
            payload = serialize_path(input_path)
            divoom16_path.write_bytes(payload)
        headless_flags = {
            "send-gif": "--headless-native-send-gif",
            "animation-verify": "--headless-native-animation-verify",
            "animation-upload-oldmode": "--headless-native-animation-upload-oldmode",
        }
        mode = headless_flags[args.action]
        if args.action == "send-gif":
            parameter = json.dumps({"path": str(divoom16_path), "loopCount": args.loops})
        else:
            parameter = str(divoom16_path)
    elif args.action == "pomodoro-timer":
        mode = mode_map[args.action]
        parameter = str(args.minutes)
    else:
        mode = mode_map[args.action]
    print(json.dumps(run_native_headless(mode=mode, parameter=parameter), indent=2))
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="macOS Divoom controller using the paired serial port")
    sub = parser.add_subparsers(dest="command", required=True)

    ports = sub.add_parser("ports", help="List detected Ditoo serial ports")
    ports.set_defaults(func=cmd_ports)

    probe = sub.add_parser("probe", help="Send a raw command packet")
    probe.add_argument("--port")
    probe.add_argument("--baudrate", type=int, default=DEFAULT_BAUDRATE)
    probe.add_argument("--timeout", type=float, default=2.0)
    probe.add_argument("--endpoint", choices=["any", "display", "audio"], default="any")
    probe.add_argument("--command", required=True, help="Hex command byte, for example 09 or bd")
    probe.add_argument("--payload", default="", help="Optional payload hex bytes")
    probe.add_argument("--expect-response", action="store_true")
    probe.set_defaults(func=cmd_probe)

    volume = sub.add_parser("volume-get", help="Query device volume")
    volume.add_argument("--port")
    volume.set_defaults(func=cmd_volume_get)

    volume_set = sub.add_parser("volume-set", help="Set device volume")
    volume_set.add_argument("value", type=int)
    volume_set.add_argument("--port")
    volume_set.set_defaults(func=cmd_volume_set)

    brightness = sub.add_parser("brightness", help="Set device brightness")
    brightness.add_argument("value", type=int)
    brightness.add_argument("--port")
    brightness.set_defaults(func=cmd_brightness)

    light_mode = sub.add_parser("light-mode", help="Set a persistent light-mode color on the 16x16 RGB display")
    light_mode.add_argument("--color", default="#ff0000", help="Named color or hex triplet, for example red or #ff0000")
    light_mode.add_argument("--brightness", type=int, default=100)
    light_mode.add_argument("--light-mode", type=int, default=0, help="Vendor app light_mode field")
    light_mode.add_argument("--on", dest="on", action="store_true", default=True)
    light_mode.add_argument("--off", dest="on", action="store_false")
    light_mode.add_argument("--app-sequence", action="store_true", help="Prepend the vendor app's 0xbd/0x46 light-mode query sequence")
    light_mode.add_argument("--port")
    light_mode.set_defaults(func=cmd_light_mode)

    send_file = sub.add_parser("send-file", help="Upload an image or GIF")
    send_file.add_argument("path")
    send_file.add_argument("--port")
    send_file.add_argument("--terminate", action="store_true")
    send_file.set_defaults(func=cmd_send_file)

    send_divoom16 = sub.add_parser("send-divoom16", help="Upload a prebuilt Divoom 16x16 animation file")
    send_divoom16.add_argument("path")
    send_divoom16.add_argument("--port")
    send_divoom16.add_argument("--terminate", action="store_true")
    send_divoom16.set_defaults(func=cmd_send_divoom16)

    send_status = sub.add_parser("send-status", help="Render live CodexBar status and upload it")
    send_status.add_argument("--provider", choices=["codex", "claude"], required=True)
    send_status.add_argument("--port")
    send_status.add_argument("--terminate", action="store_true")
    send_status.set_defaults(func=cmd_send_status)

    send_status_pair = sub.add_parser("send-status-pair", help="Render combined Codex + Claude status and upload it")
    send_status_pair.add_argument("--port")
    send_status_pair.add_argument("--terminate", action="store_true")
    send_status_pair.set_defaults(func=cmd_send_status_pair)

    send_ip_flag = sub.add_parser("send-ip-flag", help="Render the animated flag for the current public IP country and upload it")
    send_ip_flag.add_argument("--port")
    send_ip_flag.add_argument("--terminate", action="store_true")
    send_ip_flag.set_defaults(func=cmd_send_ip_flag)

    render_feed = sub.add_parser("render-feed", help="Render a feed animation to a local file without uploading it")
    render_feed.add_argument("--feed", choices=["codex", "claude", "pair", "ip-flag"], required=True)
    render_feed.set_defaults(func=cmd_render_feed)

    render_palette = sub.add_parser("render-palette", help="Render a palette-based 16x16 animation to a local GIF file")
    render_palette.add_argument("--mode", choices=["gradient-sweep", "ribbon-wave", "diamond-bloom", "palette-steps", "checker-shift", "pulse", "aurora"], required=True)
    render_palette.add_argument("--color", action="append", required=True, help="Hex color triplet like #FF3B30; repeat 3-10 times")
    render_palette.set_defaults(func=cmd_render_palette)

    send_art = sub.add_parser("send-art", help="Render a seeded generative animation and upload it")
    send_art.add_argument("--style", choices=["orbit", "plasma", "ripple"], default="orbit")
    send_art.add_argument("--seed", type=int, default=17)
    send_art.add_argument("--port")
    send_art.add_argument("--terminate", action="store_true")
    send_art.set_defaults(func=cmd_send_art)

    send_text = sub.add_parser("send-text", help="Render simple centered text and upload it")
    send_text.add_argument("text")
    send_text.add_argument("--port")
    send_text.add_argument("--terminate", action="store_true")
    send_text.set_defaults(func=cmd_send_text)

    show_design = sub.add_parser("show-design", help="Switch the device into the custom design view")
    show_design.add_argument("--slot", type=int, default=0)
    show_design.add_argument("--port")
    show_design.set_defaults(func=cmd_show_design)

    play_sound = sub.add_parser("play-sound", help="Play an OpenPeon cute-minimal feedback sound on the current output")
    play_sound.add_argument("--profile", choices=["attention", "complete", "color-set", "animation", "error"], default="attention")
    play_sound.add_argument("--volume", type=float, default=None, help="Override playback volume between 0.0 and 1.0")
    play_sound.set_defaults(func=cmd_play_sound)

    native_open_app = sub.add_parser(
        "native-open-app",
        help="Open the native macOS Divoom menu bar app for the Ditoo Pro 16x16 RGB display",
    )
    native_open_app.set_defaults(func=cmd_native_open_app)

    native_headless = sub.add_parser(
        "native-headless",
        help="Run a native macOS BLE headless action for the Ditoo Pro 16x16 RGB display",
    )
    native_headless.add_argument(
        "action",
        choices=["diagnostics", "probe", "scene-red", "scene-color", "purity-red", "purity-color", "light-mode", "pixel-test", "battery-status", "system-status", "memory-status", "thermal-status", "network-status", "animation-sample", "sample", "animation-upload", "send-gif", "animation-verify", "animation-upload-oldmode", "animated-monitor", "clock-face", "animated-clock", "pomodoro-timer", "read-key-config", "reset-key-config"],
    )
    native_headless.add_argument(
        "--color",
        default="#ff0000",
        help="Named color or hex triplet for scene-color or purity-color",
    )
    native_headless.add_argument(
        "--value",
        type=int,
        default=0,
        help="Mode byte for action=light-mode",
    )
    native_headless.add_argument(
        "--path",
        help="File path for action=animation-upload (a .divoom16 or pre-serialized animation file)",
    )
    native_headless.add_argument(
        "--loops",
        type=int,
        default=0,
        help="Loop count for action=send-gif. Use 0 for infinite.",
    )
    native_headless.add_argument(
        "--minutes",
        type=int,
        default=25,
        help="Timer duration in minutes for action=pomodoro-timer (default: 25)",
    )
    native_headless.set_defaults(func=cmd_native_headless)

    ios_routes = sub.add_parser(
        "ios-routes",
        help="List the official Divoom iPhone app routes for the Ditoo Pro 16x16 RGB display",
    )
    ios_routes.set_defaults(func=cmd_ios_routes)

    ios_route = sub.add_parser(
        "ios-route",
        help="Trigger an official Divoom iPhone app route via devicectl for the Ditoo Pro 16x16 RGB display",
    )
    ios_route.add_argument("route", help="NSUserActivity route name, for example TimeChannelIntent")
    ios_route.add_argument("--device", default=DEFAULT_IOS_DEVICE_IDENTIFIER)
    ios_route.add_argument("--udid", default=DEFAULT_IOS_UDID)
    ios_route.add_argument("--bundle-id", default=DEFAULT_IOS_BUNDLE_ID)
    ios_route.add_argument("--scheme", default=DEFAULT_IOS_SCHEME)
    ios_route.add_argument("--results-dir", type=Path, default=DEFAULT_ROUTE_RESULTS_DIR)
    ios_route.add_argument("--activate", action=argparse.BooleanOptionalAction, default=True)
    ios_route.add_argument("--terminate-existing", action=argparse.BooleanOptionalAction, default=False)
    ios_route.add_argument("--capture-syslog", action="store_true")
    ios_route.add_argument("--syslog-seconds", type=float, default=12.0)
    ios_route.set_defaults(func=cmd_ios_route)

    ios_shortcut = sub.add_parser(
        "ios-shortcut",
        help="Launch the iPhone Shortcuts app on-device for the Ditoo Pro 16x16 RGB display bridge",
    )
    ios_shortcut.add_argument(
        "action",
        choices=["open", "create", "open-shortcut", "run"],
        help="Shortcuts URL action to launch on the connected iPhone",
    )
    ios_shortcut.add_argument("--name", help="Shortcut name for open-shortcut or run")
    ios_shortcut.add_argument(
        "--input",
        choices=["none", "text", "clipboard"],
        default="none",
        help="Optional shortcut input mode when running a shortcut",
    )
    ios_shortcut.add_argument("--text", help="Text payload for input=text")
    ios_shortcut.add_argument("--device", default=DEFAULT_IOS_DEVICE_IDENTIFIER)
    ios_shortcut.add_argument("--bundle-id", default=DEFAULT_SHORTCUTS_BUNDLE_ID)
    ios_shortcut.add_argument("--results-dir", type=Path, default=DEFAULT_SHORTCUT_RESULTS_DIR)
    ios_shortcut.add_argument("--activate", action=argparse.BooleanOptionalAction, default=True)
    ios_shortcut.add_argument("--terminate-existing", action=argparse.BooleanOptionalAction, default=True)
    ios_shortcut.set_defaults(func=cmd_ios_shortcut)

    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    try:
        return args.func(args)
    except Exception as error:
        print(
            json.dumps(
                {
                    "error": type(error).__name__,
                    "message": str(error),
                },
                indent=2,
            ),
            file=sys.stderr,
        )
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
