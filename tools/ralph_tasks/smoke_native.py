#!/usr/bin/env python3

from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Run a native Divoom smoke test through the menu bar app IPC path."
    )
    parser.add_argument(
        "action",
        choices=[
            "diagnostics",
            "scene-red",
            "scene-color",
            "purity-red",
            "purity-color",
            "pixel-test",
            "battery-status",
            "system-status",
            "network-status",
        ],
    )
    parser.add_argument(
        "--color",
        help="Hex color such as #247cff for scene-color or purity-color.",
    )
    return parser


def main() -> int:
    args = build_parser().parse_args()
    command = [
        str(ROOT / "bin" / "divoom-display"),
        "native-headless",
        args.action,
    ]
    if args.color:
        command.extend(["--color", args.color])
    completed = subprocess.run(command, cwd=ROOT)
    return completed.returncode


if __name__ == "__main__":
    sys.exit(main())
