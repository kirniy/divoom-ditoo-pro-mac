# Divoom D2 Pro Mac

<p align="center">
  <img src="docs/assets/app-icon.png" alt="Divoom D2 Pro Mac app icon" width="160" height="160">
</p>

<p align="center">
  <img alt="macOS" src="https://img.shields.io/badge/macOS-native%20menu%20bar-111827?logo=apple&logoColor=white">
  <img alt="Display" src="https://img.shields.io/badge/display-16x16%20RGB-0f766e">
  <img alt="Transport" src="https://img.shields.io/badge/transport-native%20BLE-1d4ed8">
  <img alt="CLI" src="https://img.shields.io/badge/CLI-available-7c3aed">
</p>

Native macOS control for the Divoom Ditoo Pro desk display.

This project gives the Ditoo Pro `16x16` RGB pixel screen a real Mac-native control stack:
- a menu bar app
- a CLI
- exact-pixel static image rendering
- native BLE animation upload
- local status and automation surfaces

No phone bridge is required for the core display path.

## Preview

<p align="center">
  <img src="docs/assets/codex-status.gif" alt="Codex status preview" width="160" height="160">
  <img src="docs/assets/claude-status.gif" alt="Claude status preview" width="160" height="160">
</p>

## What Works

- Native macOS menu bar app for the Ditoo Pro `16x16` RGB display
- Native CLI that talks to the already-running menu bar app over IPC
- Direct BLE scene-color control
- Direct exact-pixel `16x16` static image rendering
- Native `.divoom16` animation upload over BLE
- Local asset pipeline for turning images or GIFs into `.divoom16`
- Static and animated analog clock faces (with sweeping second hand)
- Animated system monitor with CPU, memory, battery scan-line sweep
- Pomodoro timer with countdown ring and digit display
- Native battery, system snapshot, and network throughput telemetry screens
- A reverse-engineered transport path grounded in the iOS app plus live device verification

## Quick Start

Build the menu bar app:

```bash
./bin/build-divoom-menubar-app
```

Launch it:

```bash
open ./build/DivoomMenuBar.app
```

On first launch, allow Bluetooth access when macOS asks. The app is built specifically to discover and control the Ditoo Pro `16x16` RGB display over the native BLE path.

## Verified Commands

Open the menu bar app if it is not already running:

```bash
./bin/divoom-display native-open-app
```

Send a native solid color:

```bash
./bin/divoom-display native-headless scene-color --color '#247cff'
```

Render an exact-pixel test frame:

```bash
./bin/divoom-display native-headless pixel-test
```

Upload a native BLE animation file:

```bash
./bin/divoom-display native-headless animation-upload --path path/to/file.divoom16
```

Convert and upload a GIF in one step:

```bash
./bin/divoom-display native-headless send-gif --path input.gif
```

Push the native telemetry screens:

```bash
./bin/divoom-display native-headless battery-status
./bin/divoom-display native-headless system-status
./bin/divoom-display native-headless network-status
```

Show the static analog clock face:

```bash
./bin/divoom-display native-headless clock-face
```

Show the animated clock with a sweeping second hand:

```bash
./bin/divoom-display native-headless animated-clock
```

Show the animated system monitor (CPU, memory, battery with scan-line sweep):

```bash
./bin/divoom-display native-headless animated-monitor
```

Start a Pomodoro timer (default 25 minutes, countdown ring with digit display):

```bash
./bin/divoom-display native-headless pomodoro-timer
./bin/divoom-display native-headless pomodoro-timer --minutes 15
```

## Asset Pipeline

Convert an image or GIF into the Divoom `16x16` animation format:

```bash
python tools/convert_to_divoom16.py input.gif -o output.divoom16
python tools/convert_to_divoom16.py input.png -o output.divoom16
```

Inspect frame details of an image or GIF:

```bash
python tools/convert_to_divoom16.py input.gif --info
```

Inspect an existing `.divoom16` binary:

```bash
python tools/convert_to_divoom16.py --info existing.divoom16
```

Override frame duration:

```bash
python tools/convert_to_divoom16.py input.gif -o fast.divoom16 --duration 50
```

Batch convert multiple files or a directory:

```bash
python tools/convert_to_divoom16.py *.gif
python tools/convert_to_divoom16.py images/
```

Then upload the result directly from the Mac:

```bash
./bin/divoom-display native-headless animation-upload --path output.divoom16
```

## Native BLE Path

For this Ditoo Pro, the working native control path is:

```text
Mac menu bar app -> CoreBluetooth -> DitooPro-Light
```

BLE details:
- service: `49535343-FE7D-4AE5-8FA9-9FAFD205E455`
- write characteristic: `49535343-8841-43F4-A8D4-ECBE34729BB3`
- notify/read characteristic: `49535343-1E4D-4BD9-BA61-23C647249616`

The menu bar app owns Bluetooth. The CLI does not spin up a second controller; it forwards commands into the running app through IPC so macOS permission and pairing stay stable.

## Project Layout

- `macos/DivoomMenuBar`: native macOS app in Swift
- `tools/divoom_mac.py`: CLI entrypoint
- `tools/convert_to_divoom16.py`: image and GIF conversion tool for the `16x16` display
- `docs/assets`: product visuals used by this README
- `openclaw-divoom-plugin`: OpenClaw integration surface
- `hooks`: local Codex / Claude notification hooks
- `reverse/ios_ipa/REVERSE.md`: reverse-engineering notes for the official iPhone app

## Automation

A launchd watchdog keeps the overnight Ralph worker alive across reboots:

```bash
bin/install-overnight-ralph-watchdog   # install the launchd plist
bin/overnight-ralph-status             # check session health
```

The watchdog runs every five minutes. It detects stale sessions (no `status.json` update for 30 minutes) and restarts them, rotates its own logs, and uses a file lock to prevent overlapping runs.

## Status

The Mac controls the Ditoo Pro `16x16` RGB display directly over native BLE. Static images, telemetry screens, the analog clock, the animated system monitor, and the pomodoro timer all work through the proven `8841` write characteristic.

The `0x8B` animation upload now sends the `0xBD [0x31]` new-animation-mode preamble (matching the vendor Android app's `NewAniSendMode2020` family) and uses the negotiated BLE MTU instead of hard-coded 20-byte ATT chunks. Frame-by-frame streaming via `0x44` is confirmed working for software-driven animation from the Mac.
