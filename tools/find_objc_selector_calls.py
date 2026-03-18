#!/usr/bin/env python3
from __future__ import annotations

import argparse
import re
import struct
import sys
from pathlib import Path

from resolve_macho_stub import Section64, Segment64, parse_macho, resolve_objc_stub


def decode_branch_target(instruction: int, pc: int) -> tuple[str, int] | None:
    opcode = (instruction >> 26) & 0x3F
    if opcode not in (0b000101, 0b100101):
        return None

    imm26 = instruction & 0x03FFFFFF
    if imm26 & (1 << 25):
        imm26 -= 1 << 26
    target = pc + (imm26 << 2)
    mnemonic = "bl" if opcode == 0b100101 else "b"
    return mnemonic, target


def iter_code_sections(sections: list[Section64]) -> list[Section64]:
    return [
        section
        for section in sections
        if section.segname == "__TEXT" and section.sectname in {"__text", "__stubs", "__objc_stubs"}
    ]


def iter_objc_stubs(segments: list[Segment64], sections: list[Section64], data: bytes):
    objc_stubs = next(
        (section for section in sections if section.segname == "__TEXT" and section.sectname == "__objc_stubs"),
        None,
    )
    if objc_stubs is None:
        return

    stub_size = 32
    for address in range(objc_stubs.addr, objc_stubs.addr + objc_stubs.size, stub_size):
        yield resolve_objc_stub(data=data, segments=segments, section=objc_stubs, address=address)


def scan_callers(data: bytes, segments: list[Segment64], sections: list[Section64], targets: set[int]) -> list[tuple[int, str, int]]:
    callers: list[tuple[int, str, int]] = []
    for section in iter_code_sections(sections):
        if section.sectname != "__text":
            continue
        section_bytes = data[section.offset : section.offset + section.size]
        for index in range(0, len(section_bytes), 4):
            instruction = struct.unpack_from("<I", section_bytes, index)[0]
            pc = section.addr + index
            decoded = decode_branch_target(instruction, pc)
            if decoded is None:
                continue
            mnemonic, target = decoded
            if target in targets:
                callers.append((pc, mnemonic, target))
    return callers


def main() -> int:
    parser = argparse.ArgumentParser(description="Find Objective-C selector stub addresses and direct ARM64 callers")
    parser.add_argument("macho", type=Path)
    parser.add_argument("selector_pattern", help="Regex matched against selector names, e.g. 'sppSetFullColorR:G:B:'")
    parser.add_argument("--callers", action="store_true", help="Also scan __text for direct b/bl callers of matching stubs")
    args = parser.parse_args()

    segments, sections, _symtab, _dysymtab, data = parse_macho(args.macho)
    pattern = re.compile(args.selector_pattern)

    matches = [stub for stub in iter_objc_stubs(segments, sections, data) if pattern.search(str(stub["symbol"]))]
    if not matches:
        return 1

    for match in matches:
        print(f"{match['address']} {match['symbol']} section={match['section']} selector_ref={match['selectorRef']}")

    if args.callers:
        targets = {int(match["address"], 16) for match in matches}
        callers = scan_callers(data, segments, sections, targets)
        for caller_addr, mnemonic, target in callers:
            print(f"caller 0x{caller_addr:x} {mnemonic} -> 0x{target:x}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
