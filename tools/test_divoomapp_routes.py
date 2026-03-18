#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import pathlib
import shlex
import subprocess
import sys
import time
from typing import Iterable


ROOT = pathlib.Path(__file__).resolve().parents[1]
APP_QUERY_PATH = ROOT / "out" / "iphone" / "divoom-app-query.json"
DEFAULT_RESULTS_DIR = ROOT / "out" / "iphone" / "route-tests"
DEFAULT_DEVICE_IDENTIFIER = "CCED4E96-3418-5051-A1F7-9B3BAA89D4C1"
DEFAULT_BUNDLE_ID = "com.divoom.Smart"
DEFAULT_SCHEME = "divoomapp://"
DEFAULT_SYSLOG_PATTERN = (
    "Aurabox|divoomapp|TimeChannelIntent|DisplayIcon|PushChannelIntent|"
    "IncreaseBrightnessIntent|LowerBrightnessIntent|bad URL|unsupported URL|"
    "NSUserActivity|continueUserActivity|openURL"
)


def load_activity_types(path: pathlib.Path) -> list[str]:
    data = json.loads(path.read_text())
    app_info = data.get(DEFAULT_BUNDLE_ID, {})
    items = app_info.get("NSUserActivityTypes", [])
    routes = [str(item).strip() for item in items if str(item).strip()]
    return sorted(set(routes))


def sanitize_name(value: str) -> str:
    return "".join(ch if ch.isalnum() or ch in ("-", "_", ".") else "_" for ch in value)


def build_payload_url(route: str, scheme: str) -> str:
    return f"{scheme}{route}"


def build_launch_command(
    *,
    device: str,
    bundle_id: str,
    payload_url: str,
    json_output: pathlib.Path,
    activate: bool,
    terminate_existing: bool,
) -> list[str]:
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
    ]
    command.append("--activate" if activate else "--no-activate")
    if terminate_existing:
        command.append("--terminate-existing")
    command.extend(["--json-output", str(json_output), bundle_id])
    return command


def run_route(
    *,
    route: str,
    device: str,
    bundle_id: str,
    scheme: str,
    results_dir: pathlib.Path,
    activate: bool,
    terminate_existing: bool,
    dry_run: bool,
    capture_syslog: bool,
    syslog_seconds: float,
    syslog_pattern: str,
    udid: str,
) -> int:
    payload_url = build_payload_url(route, scheme)
    results_dir.mkdir(parents=True, exist_ok=True)
    json_output = results_dir / f"{sanitize_name(route)}-launch.json"
    syslog_output = results_dir / f"{sanitize_name(route)}-syslog.txt"
    command = build_launch_command(
        device=device,
        bundle_id=bundle_id,
        payload_url=payload_url,
        json_output=json_output,
        activate=activate,
        terminate_existing=terminate_existing,
    )

    print(f"route={route}")
    print(f"payload_url={payload_url}")
    print("command=" + shlex.join(command))

    if dry_run:
        return 0

    syslog_process: subprocess.Popen[str] | None = None
    if capture_syslog:
        syslog_output.parent.mkdir(parents=True, exist_ok=True)
        syslog_command = [
            "zsh",
            "-lc",
            (
                f"source {shlex.quote(str(ROOT / '.venv-mobile' / 'bin' / 'activate'))} && "
                f"timeout {syslog_seconds}s "
                f"pymobiledevice3 syslog live --udid {shlex.quote(udid)} 2>/dev/null | "
                f"rg -n {shlex.quote(syslog_pattern)} > {shlex.quote(str(syslog_output))}"
            ),
        ]
        syslog_process = subprocess.Popen(syslog_command)
        time.sleep(3)

    completed = subprocess.run(command, check=False)
    print(f"exit_code={completed.returncode}")
    if syslog_process is not None:
        try:
            syslog_process.wait(timeout=syslog_seconds + 5)
        except subprocess.TimeoutExpired:
            syslog_process.terminate()
            syslog_process.wait(timeout=5)
        print(f"syslog_output={syslog_output}")
    if json_output.exists():
        try:
            data = json.loads(json_output.read_text())
        except json.JSONDecodeError:
            print(f"json_output={json_output}")
        else:
            outcome = data.get("info", {}).get("outcome", "unknown")
            print(f"outcome={outcome}")
    else:
        print(f"json_output_missing={json_output}")

    return completed.returncode


def iterate_routes(args: argparse.Namespace, routes: Iterable[str]) -> int:
    exit_code = 0
    for index, route in enumerate(routes):
        rc = run_route(
            route=route,
            device=args.device,
            bundle_id=args.bundle_id,
            scheme=args.scheme,
            results_dir=args.results_dir,
            activate=args.activate,
            terminate_existing=args.terminate_existing,
            dry_run=args.dry_run,
            capture_syslog=args.capture_syslog,
            syslog_seconds=args.syslog_seconds,
            syslog_pattern=args.syslog_pattern,
            udid=args.udid or args.device,
        )
        exit_code = exit_code or rc
        if args.delay > 0 and index != len(routes) - 1:
            time.sleep(args.delay)
    return exit_code


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Launch known Divoom iPhone app actions via devicectl. "
            "The target app is the official Divoom iPhone app controlling the "
            "Ditoo Pro 16x16 RGB display."
        )
    )
    parser.add_argument(
        "routes",
        nargs="*",
        help="Specific route names to launch, for example TimeChannelIntent.",
    )
    parser.add_argument(
        "--app-query",
        type=pathlib.Path,
        default=APP_QUERY_PATH,
        help="Path to the captured app metadata JSON.",
    )
    parser.add_argument(
        "--list",
        action="store_true",
        help="List the known NSUserActivityTypes shipped by the iPhone app.",
    )
    parser.add_argument(
        "--all",
        action="store_true",
        help="Launch every known route from NSUserActivityTypes.",
    )
    parser.add_argument(
        "--device",
        default=DEFAULT_DEVICE_IDENTIFIER,
        help="devicectl device identifier or UDID.",
    )
    parser.add_argument(
        "--udid",
        default="00008150-000828191141401C",
        help="USB UDID used for pymobiledevice3 syslog capture.",
    )
    parser.add_argument(
        "--bundle-id",
        default=DEFAULT_BUNDLE_ID,
        help="Target bundle identifier.",
    )
    parser.add_argument(
        "--scheme",
        default=DEFAULT_SCHEME,
        help="Custom URL scheme prefix, default: divoomapp://",
    )
    parser.add_argument(
        "--results-dir",
        type=pathlib.Path,
        default=DEFAULT_RESULTS_DIR,
        help="Directory for devicectl JSON launch results.",
    )
    parser.add_argument(
        "--delay",
        type=float,
        default=1.5,
        help="Seconds to wait between route launches during --all sweeps.",
    )
    parser.add_argument(
        "--activate",
        action=argparse.BooleanOptionalAction,
        default=True,
        help="Whether devicectl should foreground the app.",
    )
    parser.add_argument(
        "--terminate-existing",
        action=argparse.BooleanOptionalAction,
        default=True,
        help="Whether to terminate the existing app instance before launch.",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Print commands without launching anything.",
    )
    parser.add_argument(
        "--capture-syslog",
        action="store_true",
        help="Capture filtered iPhone syslog around each launch.",
    )
    parser.add_argument(
        "--syslog-seconds",
        type=float,
        default=12.0,
        help="Duration for each syslog capture window.",
    )
    parser.add_argument(
        "--syslog-pattern",
        default=DEFAULT_SYSLOG_PATTERN,
        help="rg pattern used to filter live syslog when --capture-syslog is enabled.",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    routes = load_activity_types(args.app_query)

    if args.list:
        for route in routes:
            print(route)
        return 0

    if args.all:
        if args.routes:
            print("error: --all cannot be combined with explicit route names", file=sys.stderr)
            return 2
        return iterate_routes(args, routes)

    if not args.routes:
        print("error: specify one or more route names, or use --list/--all", file=sys.stderr)
        return 2

    return iterate_routes(args, args.routes)


if __name__ == "__main__":
    raise SystemExit(main())
