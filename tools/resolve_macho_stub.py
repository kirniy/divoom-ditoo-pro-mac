#!/usr/bin/env python3
from __future__ import annotations

import argparse
import struct
import sys
from dataclasses import dataclass
from pathlib import Path


MH_MAGIC_64 = 0xFEEDFACF
LC_SEGMENT_64 = 0x19
LC_SYMTAB = 0x2
LC_DYSYMTAB = 0xB
INDIRECT_SYMBOL_LOCAL = 0x80000000
INDIRECT_SYMBOL_ABS = 0x40000000


@dataclass
class Section64:
    segname: str
    sectname: str
    addr: int
    size: int
    offset: int
    reserved1: int
    reserved2: int


@dataclass
class Segment64:
    segname: str
    vmaddr: int
    vmsize: int
    fileoff: int
    filesize: int


@dataclass
class Symtab:
    symoff: int
    nsyms: int
    stroff: int
    strsize: int


@dataclass
class Dysymtab:
    indirectsymoff: int
    nindirectsyms: int


def read_c_string(buf: bytes, offset: int) -> str:
    if offset < 0 or offset >= len(buf):
        return f"<bad-string-offset:{offset}>"
    end = buf.find(b"\x00", offset)
    if end == -1:
        end = len(buf)
    return buf[offset:end].decode("utf-8", errors="replace")


def parse_macho(path: Path) -> tuple[list[Segment64], list[Section64], Symtab, Dysymtab, bytes]:
    data = path.read_bytes()
    if len(data) < 32:
        raise ValueError("file too small for Mach-O header")

    magic, cputype, cpusubtype, filetype, ncmds, sizeofcmds, flags, reserved = struct.unpack_from(
        "<IiiIIIII", data, 0
    )
    if magic != MH_MAGIC_64:
        raise ValueError(f"unsupported Mach-O magic 0x{magic:08x}")

    segments: list[Segment64] = []
    sections: list[Section64] = []
    symtab: Symtab | None = None
    dysymtab: Dysymtab | None = None

    cursor = 32
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from("<II", data, cursor)
        if cmdsize == 0:
            raise ValueError("encountered load command with cmdsize=0")

        if cmd == LC_SEGMENT_64:
            segname_raw, vmaddr, vmsize, fileoff, filesize, maxprot, initprot, nsects, segflags = struct.unpack_from(
                "<16sQQQQiiII", data, cursor + 8
            )
            segname = segname_raw.split(b"\x00", 1)[0].decode("utf-8", errors="replace")
            segments.append(
                Segment64(
                    segname=segname,
                    vmaddr=vmaddr,
                    vmsize=vmsize,
                    fileoff=fileoff,
                    filesize=filesize,
                )
            )
            section_cursor = cursor + 72
            for _section_index in range(nsects):
                (
                    sectname_raw,
                    sect_segname_raw,
                    addr,
                    size,
                    offset,
                    align,
                    reloff,
                    nreloc,
                    flags_value,
                    reserved1,
                    reserved2,
                    reserved3,
                ) = struct.unpack_from("<16s16sQQIIIIIIII", data, section_cursor)
                sections.append(
                    Section64(
                        segname=sect_segname_raw.split(b"\x00", 1)[0].decode("utf-8", errors="replace"),
                        sectname=sectname_raw.split(b"\x00", 1)[0].decode("utf-8", errors="replace"),
                        addr=addr,
                        size=size,
                        offset=offset,
                        reserved1=reserved1,
                        reserved2=reserved2,
                    )
                )
                section_cursor += 80

        elif cmd == LC_SYMTAB:
            symoff, nsyms, stroff, strsize = struct.unpack_from("<IIII", data, cursor + 8)
            symtab = Symtab(symoff=symoff, nsyms=nsyms, stroff=stroff, strsize=strsize)

        elif cmd == LC_DYSYMTAB:
            values = struct.unpack_from("<" + "I" * 18, data, cursor + 8)
            indirectsymoff = values[14]
            nindirectsyms = values[15]
            dysymtab = Dysymtab(indirectsymoff=indirectsymoff, nindirectsyms=nindirectsyms)

        cursor += cmdsize

    if symtab is None:
        raise ValueError("LC_SYMTAB not found")
    if dysymtab is None:
        raise ValueError("LC_DYSYMTAB not found")

    return segments, sections, symtab, dysymtab, data


def load_symbol_name(data: bytes, symtab: Symtab, symbol_index: int) -> str:
    if symbol_index < 0 or symbol_index >= symtab.nsyms:
        return f"<bad-symbol-index:{symbol_index}>"
    entry_off = symtab.symoff + symbol_index * 16
    strx, n_type, n_sect, n_desc, n_value = struct.unpack_from("<IbbHQ", data, entry_off)
    return read_c_string(data[symtab.stroff : symtab.stroff + symtab.strsize], strx)


def vmaddr_to_fileoff(segments: list[Segment64], address: int) -> int:
    for segment in segments:
        if segment.vmaddr <= address < segment.vmaddr + segment.filesize:
            return segment.fileoff + (address - segment.vmaddr)
    raise ValueError(f"address 0x{address:x} not found in any file-backed segment")


def decode_adrp_target(instruction: int, pc: int) -> int:
    immlo = (instruction >> 29) & 0x3
    immhi = (instruction >> 5) & 0x7FFFF
    imm = (immhi << 2) | immlo
    if imm & (1 << 20):
        imm -= 1 << 21
    return ((pc >> 12) << 12) + (imm << 12)


def decode_ldr_uimm_target(instruction: int, base: int) -> int:
    size = (instruction >> 30) & 0x3
    scale = {0: 1, 1: 2, 2: 4, 3: 8}[size]
    imm12 = (instruction >> 10) & 0xFFF
    return base + imm12 * scale


def read_u64_at_vmaddr(data: bytes, segments: list[Segment64], address: int) -> int:
    offset = vmaddr_to_fileoff(segments, address)
    return struct.unpack_from("<Q", data, offset)[0]


def resolve_objc_stub(
    *,
    data: bytes,
    segments: list[Segment64],
    section: Section64,
    address: int,
) -> dict[str, object]:
    stub_size = 32
    stub_index = (address - section.addr) // stub_size
    fileoff = vmaddr_to_fileoff(segments, address)
    adrp_word, ldr_word = struct.unpack_from("<II", data, fileoff)

    selector_page = decode_adrp_target(adrp_word, address)
    selector_ref_addr = decode_ldr_uimm_target(ldr_word, selector_page)
    selector_cstr_addr = read_u64_at_vmaddr(data, segments, selector_ref_addr)
    selector_string = read_c_string(data, vmaddr_to_fileoff(segments, selector_cstr_addr))

    return {
        "address": f"0x{address:x}",
        "section": f"{section.segname},{section.sectname}",
        "stubSize": stub_size,
        "stubIndex": int(stub_index),
        "selectorRef": f"0x{selector_ref_addr:x}",
        "selectorCString": f"0x{selector_cstr_addr:x}",
        "symbol": f"objc::{selector_string}",
    }


def resolve_stub(path: Path, address: int) -> dict[str, object]:
    segments, sections, symtab, dysymtab, data = parse_macho(path)
    stub_section = next(
        (
            section
            for section in sections
            if section.addr <= address < section.addr + section.size
        ),
        None,
    )
    if stub_section is None:
        raise ValueError(f"no section contains address 0x{address:x}")

    if stub_section.sectname == "__objc_stubs":
        return resolve_objc_stub(data=data, segments=segments, section=stub_section, address=address)

    if stub_section.reserved2 <= 0:
        raise ValueError(f"section {stub_section.segname},{stub_section.sectname} is not a symbol-stub section")

    stub_size = stub_section.reserved2
    stub_index = (address - stub_section.addr) // stub_size
    indirect_index = stub_section.reserved1 + stub_index
    if indirect_index < 0 or indirect_index >= dysymtab.nindirectsyms:
        raise ValueError(f"indirect symbol index {indirect_index} out of range")

    symbol_table_off = dysymtab.indirectsymoff + indirect_index * 4
    symbol_index = struct.unpack_from("<I", data, symbol_table_off)[0]

    result: dict[str, object] = {
        "address": f"0x{address:x}",
        "section": f"{stub_section.segname},{stub_section.sectname}",
        "stubSize": stub_size,
        "stubIndex": int(stub_index),
        "indirectIndex": int(indirect_index),
    }

    if symbol_index & INDIRECT_SYMBOL_LOCAL:
        result["symbol"] = "<local>"
        result["symbolIndex"] = int(symbol_index)
        return result
    if symbol_index & INDIRECT_SYMBOL_ABS:
        result["symbol"] = "<absolute>"
        result["symbolIndex"] = int(symbol_index)
        return result

    result["symbolIndex"] = int(symbol_index)
    result["symbol"] = load_symbol_name(data, symtab, symbol_index)
    return result


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Resolve an arm64 Mach-O stub address to an imported symbol name")
    parser.add_argument("macho", type=Path)
    parser.add_argument("addresses", nargs="+", help="Stub addresses like 0x10109a4e0")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    for raw_address in args.addresses:
        address = int(raw_address, 16)
        result = resolve_stub(args.macho, address)
        parts = [
            str(result["address"]),
            str(result["symbol"]),
            f"section={result['section']}",
            f"stub_index={result['stubIndex']}",
        ]
        if "indirectIndex" in result:
            parts.append(f"indirect_index={result['indirectIndex']}")
        if "selectorRef" in result:
            parts.append(f"selector_ref={result['selectorRef']}")
        if "selectorCString" in result:
            parts.append(f"selector_cstr={result['selectorCString']}")
        print(" ".join(parts))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
