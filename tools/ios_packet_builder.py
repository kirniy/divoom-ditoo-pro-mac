#!/usr/bin/env python3
"""Build Divoom packets to match the reversed iOS Aurabox binary.

This tool does not talk to the device. It only packages bytes exactly the way
the iOS app does, so transport code can reuse it without re-guessing framing.
"""

from __future__ import annotations

import argparse
from dataclasses import dataclass


def checksum16(data: bytes) -> int:
    return sum(data) & 0xFFFF


def escape_old_mode(data: bytes) -> bytes:
    out = bytearray()
    for value in data:
        if value == 0x01:
            out.extend((0x03, 0x04))
        elif value == 0x02:
            out.extend((0x03, 0x05))
        elif value == 0x03:
            out.extend((0x03, 0x06))
        else:
            out.append(value)
    return bytes(out)


def build_old_mode(command: int, data: bytes) -> bytes:
    inner = bytearray()
    inner.extend((len(data) + 3).to_bytes(2, "little"))
    inner.append(command & 0xFF)
    inner.extend(data)
    inner.extend(checksum16(inner).to_bytes(2, "little"))
    return b"\x01" + escape_old_mode(bytes(inner)) + b"\x02"


def build_new_mode(command: int, data: bytes, *, transmit_mode: int = 0, packet_id: int = 0) -> bytes:
    payload = bytes((command & 0xFF,)) + data
    body = bytearray()
    if transmit_mode == 1:
        length = len(payload) + 7
    else:
        length = len(payload) + 3
    body.extend(length.to_bytes(2, "little"))
    body.append(transmit_mode & 0xFF)
    if transmit_mode == 1:
        body.extend(packet_id.to_bytes(4, "little"))
    body.extend(payload)
    body.extend(checksum16(body).to_bytes(2, "little"))
    return bytes.fromhex("feefaa55") + bytes(body)


@dataclass(frozen=True)
class PacketSpec:
    mode: str
    command: int
    data: bytes
    transmit_mode: int = 0
    packet_id: int = 0


def parse_hex_blob(value: str) -> bytes:
    normalized = value.replace(" ", "").replace("_", "")
    if normalized.startswith("0x"):
        normalized = normalized[2:]
    if not normalized:
        return b""
    return bytes.fromhex(normalized)


def parse_int(value: str) -> int:
    return int(value, 0)


def build(spec: PacketSpec) -> bytes:
    if spec.mode == "old":
        return build_old_mode(spec.command, spec.data)
    if spec.mode == "new":
        return build_new_mode(
            spec.command,
            spec.data,
            transmit_mode=spec.transmit_mode,
            packet_id=spec.packet_id,
        )
    raise ValueError(f"unsupported mode: {spec.mode}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("old", "new"))
    parser.add_argument("command", help="Command byte, e.g. 0x45")
    parser.add_argument("data", nargs="?", default="", help="Hex payload bytes without the command")
    parser.add_argument("--transmit-mode", default="0", help="New-mode transmit mode, default 0")
    parser.add_argument("--packet-id", default="0", help="New-mode packet id, used when transmit mode is 1")
    args = parser.parse_args()

    spec = PacketSpec(
        mode=args.mode,
        command=parse_int(args.command),
        data=parse_hex_blob(args.data),
        transmit_mode=parse_int(args.transmit_mode),
        packet_id=parse_int(args.packet_id),
    )
    packet = build(spec)
    print(packet.hex())
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
