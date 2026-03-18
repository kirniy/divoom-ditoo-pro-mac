#!/usr/bin/env python3
from __future__ import annotations

import argparse
import asyncio
import json
import pathlib
from typing import Iterable

from pymobiledevice3.lockdown import create_using_usbmux
from pymobiledevice3.services.accessibilityaudit import AccessibilityAudit, Direction, deserialize_object


DEFAULT_UDID = "00008150-000828191141401C"


async def dump_items(udid: str) -> list[dict]:
    lockdown = await create_using_usbmux(udid)
    async with lockdown:
        async with AccessibilityAudit(lockdown) as service:
            await service.set_app_monitoring_enabled(True)
            await service.set_monitored_event_type()
            await service.move_focus(Direction.First)

            items: list[dict] = []
            visited: set[str] = set()
            consecutive_timeouts = 0

            while True:
                try:
                    assert service._event_queue is not None
                    name, args = await asyncio.wait_for(service._event_queue.get(), timeout=1.0)
                    consecutive_timeouts = 0
                except asyncio.TimeoutError:
                    consecutive_timeouts += 1
                    if consecutive_timeouts >= 5:
                        break
                    await service.move_focus(Direction.Next)
                    continue

                payload = service._extract_event_payload(args)
                if payload is None or name != "hostInspectorCurrentElementChanged:":
                    continue

                event_data = deserialize_object(payload)
                current_item = event_data[0] if isinstance(event_data, list) else event_data
                platform_identifier = current_item.platform_identifier

                if platform_identifier in visited:
                    break

                items.append(current_item.to_dict())
                visited.add(platform_identifier)
                await service.move_focus(Direction.Next)

    return items


async def press_platform_identifier(udid: str, platform_identifier: str) -> None:
    identifier = bytes.fromhex(platform_identifier)
    lockdown = await create_using_usbmux(udid)
    async with lockdown:
        async with AccessibilityAudit(lockdown) as service:
            await service.perform_press(identifier)


def filter_items(items: Iterable[dict], needle: str) -> list[dict]:
    needle_lower = needle.lower()
    return [item for item in items if needle_lower in item.get("caption", "").lower()]


def command_dump(args: argparse.Namespace) -> int:
    items = asyncio.run(dump_items(args.udid))

    if args.contains:
        items = filter_items(items, args.contains)

    if args.json:
        args.json.parent.mkdir(parents=True, exist_ok=True)
        args.json.write_text(json.dumps(items, indent=2))

    if args.captions_only:
        for item in items:
            print(item["caption"])
    else:
        print(json.dumps(items, indent=2))

    return 0


def command_press(args: argparse.Namespace) -> int:
    items = asyncio.run(dump_items(args.udid))
    matches = filter_items(items, args.contains)
    if not matches:
        print(f"no-match: {args.contains}")
        return 1

    target = matches[0]
    print(f"pressing: {target['caption']}")
    asyncio.run(press_platform_identifier(args.udid, target["platform_identifier"]))
    return 0


def command_press_id(args: argparse.Namespace) -> int:
    asyncio.run(press_platform_identifier(args.udid, args.platform_identifier))
    print(f"press-sent: {args.platform_identifier}")
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description=(
            "Inspect and best-effort automate the official Divoom iPhone app over USB "
            "using Apple's accessibility developer service. This is for the Divoom "
            "Ditoo Pro's 16x16 pixel RGB display workflow on iPhone."
        )
    )
    parser.add_argument(
        "--udid",
        default=DEFAULT_UDID,
        help="Connected iPhone UDID.",
    )

    subparsers = parser.add_subparsers(dest="command", required=True)

    dump_parser = subparsers.add_parser(
        "dump",
        help="Dump focus-first accessibility items from the current Divoom iPhone app screen.",
    )
    dump_parser.add_argument("--contains", help="Filter captions by substring.")
    dump_parser.add_argument("--json", type=pathlib.Path, help="Write the dump to a JSON file.")
    dump_parser.add_argument(
        "--captions-only",
        action="store_true",
        help="Print only captions instead of full JSON objects.",
    )
    dump_parser.set_defaults(func=command_dump)

    press_parser = subparsers.add_parser(
        "press",
        help="Best-effort press the first accessibility element whose caption contains the given text.",
    )
    press_parser.add_argument("contains", help="Substring to match in the caption.")
    press_parser.set_defaults(func=command_press)

    press_id_parser = subparsers.add_parser(
        "press-id",
        help="Best-effort press a known accessibility platform identifier.",
    )
    press_id_parser.add_argument("platform_identifier", help="Hex platform identifier from a dump.")
    press_id_parser.set_defaults(func=command_press_id)

    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
