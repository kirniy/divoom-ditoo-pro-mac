#!/usr/bin/env python3
"""Convert images and GIFs to the Divoom 16x16 animation format.

Usage:
    python tools/convert_to_divoom16.py input.gif -o output.divoom16
    python tools/convert_to_divoom16.py input.png -o output.divoom16
    python tools/convert_to_divoom16.py input.gif  # writes to input.divoom16
    python tools/convert_to_divoom16.py --info existing.divoom16

The output is a raw binary blob that can be uploaded to a Divoom Ditoo Pro
16x16 RGB display using the 0x8B animation upload command sequence.
"""
from __future__ import annotations

import argparse
import math
import struct
import sys
from pathlib import Path
from typing import Iterable

from PIL import Image, ImageOps, ImageSequence


def resize_rgb(image: Image.Image) -> Image.Image:
    rgb = image.convert("RGBA")
    if rgb.getbbox() is None:
        rgb = Image.new("RGBA", rgb.size, (0, 0, 0, 255))
    flattened = Image.alpha_composite(
        Image.new("RGBA", rgb.size, (0, 0, 0, 255)), rgb
    ).convert("RGB")
    return ImageOps.fit(flattened, (16, 16), method=Image.Resampling.LANCZOS)


def reduce_palette(image: Image.Image) -> Image.Image:
    rgb = resize_rgb(image)
    colors = rgb.getcolors(maxcolors=257)
    if colors is None:
        return (
            rgb.quantize(colors=256, method=Image.Quantize.MEDIANCUT, dither=Image.Dither.NONE)
            .convert("RGB")
        )
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


def serialize_path(path: Path, duration_override_ms: int | None = None) -> bytes:
    frames = []
    for frame, duration_ms in iter_frames(path):
        effective = duration_override_ms if duration_override_ms is not None else duration_ms
        frames.append(serialize_frame(frame, effective))
    return b"".join(frames)


def inspect_divoom16(data: bytes) -> list[dict]:
    """Parse a .divoom16 binary and return per-frame info."""
    frames = []
    offset = 0
    while offset + 7 <= len(data) and data[offset] == 0xAA:
        frame_length = struct.unpack_from("<H", data, offset + 1)[0]
        if frame_length < 7 or offset + frame_length > len(data):
            break
        duration_ms = struct.unpack_from("<H", data, offset + 3)[0]
        local_palette_count = data[offset + 6]
        frames.append({
            "offset": offset,
            "length": frame_length,
            "duration_ms": duration_ms,
            "local_palette_count": local_palette_count,
        })
        offset += frame_length
    return frames


def process_single(input_path: Path, output_path: Path | None, info: bool, duration: int | None) -> int:
    is_divoom16 = input_path.suffix == ".divoom16"

    if info:
        if is_divoom16:
            raw = input_path.read_bytes()
            frames = inspect_divoom16(raw)
            if not frames:
                print("error: no valid frames found in .divoom16 file", file=sys.stderr)
                return 1
            for i, f in enumerate(frames):
                print(f"  frame {i}: {f['local_palette_count']} local colors, {f['duration_ms']}ms, {f['length']} bytes (offset 0x{f['offset']:x})")
            total_duration = sum(f["duration_ms"] for f in frames)
            print(f"total: {len(frames)} frames, {len(raw)} bytes, {total_duration}ms")
        else:
            frame_count = 0
            total_bytes = 0
            for frame, duration_ms in iter_frames(input_path):
                palette = palette_from_image(frame)
                data = serialize_frame(frame, duration_ms)
                print(f"  frame {frame_count}: {len(palette)} colors, {duration_ms}ms, {len(data)} bytes")
                total_bytes += len(data)
                frame_count += 1
            print(f"total: {frame_count} frames, {total_bytes} bytes")
        return 0

    if is_divoom16:
        print("error: input is already a .divoom16 file; use --info to inspect it", file=sys.stderr)
        return 1

    resolved_output = output_path if output_path else input_path.with_suffix(".divoom16")
    payload = serialize_path(input_path, duration_override_ms=duration)
    resolved_output.write_bytes(payload)
    print(f"wrote {len(payload)} bytes to {resolved_output}")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Convert images and GIFs to Divoom 16x16 animation format."
    )
    parser.add_argument("input", nargs="+", help="Input image(s), GIF(s), or .divoom16 file(s)")
    parser.add_argument(
        "-o", "--output",
        help="Output .divoom16 file (only valid with a single input)",
    )
    parser.add_argument(
        "--info", action="store_true",
        help="Print frame info without writing output",
    )
    parser.add_argument(
        "--duration", type=int, default=None,
        help="Override frame duration in milliseconds for all frames",
    )
    args = parser.parse_args()

    inputs = []
    for raw in args.input:
        p = Path(raw).expanduser().resolve()
        if p.is_dir():
            inputs.extend(sorted(p.glob("*.gif")) + sorted(p.glob("*.png")) + sorted(p.glob("*.jpg")))
        elif "*" in raw or "?" in raw:
            import glob as globmod
            inputs.extend(Path(m).resolve() for m in sorted(globmod.glob(raw)))
        else:
            inputs.append(p)

    if not inputs:
        print("error: no input files found", file=sys.stderr)
        return 1

    if args.output and len(inputs) > 1:
        print("error: -o/--output cannot be used with multiple inputs", file=sys.stderr)
        return 1

    exit_code = 0
    for input_path in inputs:
        if not input_path.exists():
            print(f"error: input file not found: {input_path}", file=sys.stderr)
            exit_code = 1
            continue
        if len(inputs) > 1:
            print(f"--- {input_path.name} ---")
        output_path = Path(args.output) if args.output else None
        result = process_single(input_path, output_path, args.info, args.duration)
        if result != 0:
            exit_code = result
    return exit_code


if __name__ == "__main__":
    sys.exit(main())
