#!/usr/bin/env python3
from __future__ import annotations

import argparse
import glob
import sys
import time
from dataclasses import dataclass
from pathlib import Path

import serial


def checksum(command: int, payload: bytes) -> int:
    length = len(payload) + 3
    parts = [length & 0xFF, (length >> 8) & 0xFF, command, *payload]
    return sum(parts) & 0xFFFF


def build_packet(command: int, payload: bytes = b"") -> bytes:
    length = len(payload) + 3
    crc = checksum(command, payload)
    return bytes(
        [
            0x01,
            length & 0xFF,
            (length >> 8) & 0xFF,
            command,
            *payload,
            crc & 0xFF,
            (crc >> 8) & 0xFF,
            0x02,
        ]
    )


@dataclass
class Response:
    original_command: int
    ack: bool
    data: bytes


def parse_response(raw: bytes) -> Response:
    if len(raw) < 7:
        raise ValueError("response too short")
    if raw[0] != 0x01 or raw[-1] != 0x02:
        raise ValueError("bad framing")
    if raw[3] != 0x04:
        raise ValueError(f"unexpected response command byte 0x{raw[3]:02x}")
    return Response(original_command=raw[4], ack=raw[5] == 0x55, data=raw[6:-3])


def read_frame(ser: serial.Serial, timeout_s: float) -> bytes:
    deadline = time.monotonic() + timeout_s
    buf = bytearray()
    while time.monotonic() < deadline:
        try:
            chunk = ser.read(1)
        except serial.SerialException:
            return bytes(buf)
        if not chunk:
            continue
        buf.extend(chunk)
        if len(buf) >= 3 and buf[0] == 0x01:
            payload_len = int.from_bytes(buf[1:3], "little")
            frame_len = payload_len + 4
            while len(buf) < frame_len and time.monotonic() < deadline:
                try:
                    more = ser.read(frame_len - len(buf))
                except serial.SerialException:
                    return bytes(buf)
                if not more:
                    continue
                buf.extend(more)
            return bytes(buf)
    return bytes(buf)


def main() -> int:
    parser = argparse.ArgumentParser(description="Low-level Divoom serial probe for macOS")
    parser.add_argument("--port", default="/dev/cu.DitooPro-Audio")
    parser.add_argument("--baudrate", type=int, default=115200)
    parser.add_argument("--timeout", type=float, default=2.0)
    parser.add_argument(
        "--command",
        default="09",
        help="Hex command byte without 0x prefix, default 09 (get volume)",
    )
    parser.add_argument(
        "--payload",
        default="",
        help="Optional payload bytes as hex, for example '32' or '06 00 00'",
    )
    args = parser.parse_args()

    port = args.port
    if not Path(port).exists():
        matches = sorted(glob.glob("/dev/cu.*Ditoo*"))
        if matches:
            port = matches[0]
        else:
            print(f"port_not_found={port}")
            return 2

    command = int(args.command, 16)
    payload = bytes.fromhex(args.payload) if args.payload.strip() else b""
    packet = build_packet(command, payload)

    print(f"port={port}")
    print(f"tx={packet.hex()}")

    ser = serial.Serial(
        port=port,
        baudrate=args.baudrate,
        timeout=args.timeout,
        write_timeout=args.timeout,
    )
    try:
        ser.reset_input_buffer()
        ser.reset_output_buffer()
        ser.write(packet)
        ser.flush()
        time.sleep(0.2)
        raw = read_frame(ser, args.timeout)
        print(f"rx={raw.hex()}")
        if raw:
            try:
                decoded = parse_response(raw)
                print(
                    "decoded="
                    f"cmd=0x{decoded.original_command:02x} "
                    f"ack={decoded.ack} data={decoded.data.hex()}"
                )
            except Exception as exc:
                print(f"decode_error={exc}")
    finally:
        ser.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
