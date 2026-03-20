# Divoom Ditoo Pro Mac

<p align="center">
  <img src="docs/assets/app-icon.png" alt="Divoom Ditoo Pro Mac app icon" width="160" height="160">
</p>

<p align="center">
  <img alt="macOS" src="https://img.shields.io/badge/macOS-native%20menu%20bar-111827?logo=apple&logoColor=white">
  <img alt="Display" src="https://img.shields.io/badge/display-16x16%20RGB-0f766e">
  <img alt="Transport" src="https://img.shields.io/badge/transport-hidden%20inside%20app-1d4ed8">
  <img alt="CLI" src="https://img.shields.io/badge/CLI-IPC%20bridge-7c3aed">
  <img alt="Version" src="https://img.shields.io/badge/version-0.2.0--beta.1-f97316">
</p>

Native macOS menu bar control for the Divoom Ditoo Pro `16x16` RGB display.

This repo is building a real Mac-native stack around the Ditoo Pro:

- a menu bar app that owns Bluetooth
- a CLI that forwards into the running app over IPC
- a native animation library window
- a native cloud-backed Divoom source
- direct pixel rendering, clocks, telemetry, timers, and live feed surfaces

No iPhone bridge is required for the core Mac control path.

## Visuals

<p align="center">
  <img src="docs/assets/codex-status.gif" alt="Codex status preview" width="160" height="160">
  <img src="docs/assets/claude-status.gif" alt="Claude status preview" width="160" height="160">
</p>

## Current Product Truth

### Verified working now

- direct native BLE control from macOS
- solid color scenes
- exact `16x16` static image rendering
- software-driven frame-streamed animations from the Mac
- battery, system, and network telemetry panels
- analog clock, animated clock, animated monitor, and Pomodoro timer
- native animation library with favorites, recents, filters, and beam actions
- release packaging into `.zip` and `.pkg`
- one-line source installer

### Working, but still beta-grade

- native Divoom cloud browsing, sync, search, and like / unlike
- cloud login via app Keychain plus one-time Passwords import
- favorites rotation and live feed surfaces
- branded Codex / Claude / split feed rendering

### Not claimed as finished yet

- full iOS-equivalent Divoom store/channel browsing parity
- exact vendor custom channel / gallery playback activation after upload
- fully recovered device-side autonomous playlist behavior
- exact iOS store flag mapping for every cloud lane

If a feature is in the app but still depends on reverse-engineering work, it should be treated as beta, not vendor-parity complete.

## How It Works

The BLE light transport is intentionally hidden behind the running menu bar app.

User-facing model:

- launch the app once
- grant Bluetooth once
- drive the Ditoo from the menu bar UI or from `divoom-display`

Actual control path:

```text
CLI -> local IPC -> running DivoomMenuBar.app -> CoreBluetooth -> DitooPro-Light
```

BLE details currently verified on this device:

- service: `49535343-FE7D-4AE5-8FA9-9FAFD205E455`
- write characteristic: `49535343-8841-43F4-A8D4-ECBE34729BB3`
- notify/read characteristic: `49535343-1E4D-4BD9-BA61-23C647249616`

This matters because the CLI does not spin up a second BLE controller. The app owns the Bluetooth session and keeps macOS permissions, pairing state, and transport behavior stable.

## Install

### One-line source install

```bash
curl -fsSL https://raw.githubusercontent.com/kirniy/divoom-ditoo-pro-mac/main/install.sh | bash
```

What that does:

- clones the repo into `~/Library/Application Support/DivoomDitooProMac/repo`
- builds the app locally
- installs `DivoomMenuBar.app` into `/Applications`
- links `divoom-display` into `/usr/local/bin`
- launches the app

Requirements for the one-line installer:

- macOS
- `git`
- `python3`
- Xcode Command Line Tools / `swiftc`

### Local build

```bash
./bin/build-divoom-menubar-app
open ./build/DivoomMenuBar.app
```

### Release artifacts

Build release artifacts locally:

```bash
./bin/package-release-artifacts
```

This emits:

- `build/release/DivoomDitooProMac-<version>.zip`
- `build/release/DivoomDitooProMac-<version>.pkg`

Current release train:

- semantic versioning
- current version: `0.2.0-beta.1`
- release channel: early beta

More detail: [`docs/INSTALL.md`](docs/INSTALL.md)

## Quick Start

Open the app if it is not already running:

```bash
./bin/divoom-display native-open-app
```

Allow Bluetooth access when macOS asks.

Then try a few real commands:

```bash
./bin/divoom-display native-headless scene-color --color '#247cff'
./bin/divoom-display native-headless pixel-test
./bin/divoom-display native-headless send-gif --path input.gif
./bin/divoom-display native-headless battery-status
./bin/divoom-display native-headless animated-clock
./bin/divoom-display native-headless animated-monitor
./bin/divoom-display native-headless pomodoro-timer --minutes 15
```

## Working Surfaces

### Native app

- menu bar shell for the Ditoo Pro
- top summary surface for device and beam state
- quick tiles for live feeds, library, color picking, and favorites
- color motion studio
- animation library window with previews, favorites, recents, filters, and inspector actions
- settings window for install state, cloud login, logs, and release links

### Native cloud library

- source root: `assets/16x16/divoom-cloud`
- manifest: `.cache/divoom-cloud/manifest.json`
- native controls:
  - `Settings -> Library`
  - `Animation Library -> Cloud Login`
  - `Animation Library -> Sync Cloud`
  - `Animation Library -> Cloud Search`

Important: cloud auth is still a beta surface. The intended stable path is to save credentials into the app Keychain. Synced Passwords import exists as a helper, not as the long-term product endpoint.

Guide: [`docs/DIVOOM_CLOUD_SYNC.md`](docs/DIVOOM_CLOUD_SYNC.md)

### Asset pipeline

Convert images or GIFs into Divoom `16x16` animation format:

```bash
python tools/convert_to_divoom16.py input.gif -o output.divoom16
python tools/convert_to_divoom16.py input.png -o output.divoom16
python tools/convert_to_divoom16.py input.gif --info
python tools/convert_to_divoom16.py --info existing.divoom16
```

Then send the result from the Mac:

```bash
./bin/divoom-display native-headless animation-upload --path output.divoom16
```

## Troubleshooting

Common issues:

- app opens but no menu bar icon appears
- Bluetooth permission is denied or never granted
- cloud login looks present but sync/search still fails
- repeated Passwords prompts from synced credentials
- release install succeeds but CLI is missing from `PATH`

Start here: [`docs/TROUBLESHOOTING.md`](docs/TROUBLESHOOTING.md)

Logs live at:

```text
~/Library/Logs/DivoomMenuBar.log
```

The app also has native log entry points in Settings.

## Project Layout

- `macos/DivoomMenuBar`: native macOS app in Swift
- `tools/divoom_mac.py`: CLI entrypoint
- `tools/convert_to_divoom16.py`: image and GIF conversion tool
- `vendor/apixoo`: vendored Divoom cloud client
- `reverse/ios_ipa/REVERSE.md`: reverse-engineering notes for the iPhone app
- `docs/AI_ROADMAP.md`: AI feature backlog
- `docs/PRODUCT_PARITY_PLAN.md`: product and protocol parity plan

## Docs

- install and release path: [`docs/INSTALL.md`](docs/INSTALL.md)
- troubleshooting: [`docs/TROUBLESHOOTING.md`](docs/TROUBLESHOOTING.md)
- cloud sync: [`docs/DIVOOM_CLOUD_SYNC.md`](docs/DIVOOM_CLOUD_SYNC.md)
- product and parity plan: [`docs/PRODUCT_PARITY_PLAN.md`](docs/PRODUCT_PARITY_PLAN.md)
- AI roadmap: [`docs/AI_ROADMAP.md`](docs/AI_ROADMAP.md)
- attributions: [`docs/ATTRIBUTIONS.md`](docs/ATTRIBUTIONS.md)

## Attribution

This repo vendors and builds on upstream work. See [`docs/ATTRIBUTIONS.md`](docs/ATTRIBUTIONS.md).

Current notable upstream attribution:

- `redphx/apixoo` for the Divoom cloud client base

## Status

The Mac-native transport is real and verified. The UI/product layer is moving fast. The remaining hard work is on exact iOS parity for cloud sorting, channel browsing, and vendor-style autonomous playback behavior after upload.

Releases:

- GitHub Releases: <https://github.com/kirniy/divoom-ditoo-pro-mac/releases>
- installer script: [`install.sh`](install.sh)
- release packaging: [`bin/package-release-artifacts`](bin/package-release-artifacts)
- version source of truth: [`VERSION`](VERSION)
