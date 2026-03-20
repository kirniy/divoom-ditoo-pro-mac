# Divoom Ditoo Pro Mac

<p align="center">
  <img src="docs/assets/app-icon.png" alt="Divoom Ditoo Pro Mac app icon" width="160" height="160">
</p>

<p align="center">
  <img alt="macOS" src="https://img.shields.io/badge/macOS-native%20menu%20bar-111827?logo=apple&logoColor=white">
  <img alt="Display" src="https://img.shields.io/badge/display-16x16%20RGB-0f766e">
  <img alt="Transport" src="https://img.shields.io/badge/transport-hidden%20inside%20app-1d4ed8">
  <img alt="CLI" src="https://img.shields.io/badge/CLI-IPC%20bridge-7c3aed">
  <img alt="Version" src="https://img.shields.io/badge/version-0.3.0--beta.2-f97316">
</p>

Native macOS menu bar control for the Divoom Ditoo Pro `16x16` RGB display.

This repo is building a real Mac-native stack around the Ditoo Pro:

- a menu bar app that owns Bluetooth
- a CLI that forwards into the running app over IPC
- a native animation library window
- a native cloud-backed Divoom source
- a compact status shell with a native live-mode control deck
- direct pixel rendering, clocks, telemetry, timers, and live feed surfaces

No iPhone bridge is required for the core Mac control path.

Install truth in one sentence:

- use the one-line source installer if you want the app plus the `divoom-display` CLI
- use the `.zip` or `.pkg` release artifact if you only want the app bundle

## Visuals

<p align="center">
  <img src="docs/assets/codex-status.gif" alt="Codex status preview" width="160" height="160">
  <img src="docs/assets/claude-status.gif" alt="Claude status preview" width="160" height="160">
</p>

The repo currently includes only animated feed previews here. Full screenshots of the menu shell, library window, and settings window still need to be added.

## Current Product Truth

### Verified working now

- direct native BLE control from macOS
- solid color scenes
- ambient RGB / backlight color via the IPA-confirmed `0x6f` path
- exact `16x16` static image rendering
- software-driven frame-streamed animations from the Mac
- battery, system, and network telemetry panels
- analog clock, animated clock, animated monitor, and Pomodoro timer
- native animation library with favorites, recents, filters, and beam actions
- release packaging into `.zip` and `.pkg`
- one-line source installer

### Working, but still beta-grade

- native Divoom cloud login, sync, and like / unlike
- one-time import from synced Passwords into the app Keychain
- favorites rotation and live feed surfaces
- branded Codex / Claude / split feed rendering
- the new native menu shell and library chrome are still being iterated aggressively

### Not claimed as finished yet

- full iOS-equivalent Divoom store/channel browsing parity
- exact payload parity for `Channel/StoreClockGetClassify`
- exact payload parity for `Channel/ItemSearch`
- exact vendor custom channel / gallery playback activation after upload
- fully recovered device-side autonomous playlist behavior
- exact iOS store flag mapping for every cloud lane

If a feature is in the app but still depends on reverse-engineering work, it should be treated as beta, not vendor-parity complete.

For the current parity roadmap, see [`docs/PRODUCT_PARITY_PLAN.md`](docs/PRODUCT_PARITY_PLAN.md).

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

If the speaker side is visible but beams still fail, the recovery truth is the same as the app UI: the display path is `DitooPro-Light`, not `DitooPro-Audio`. Use `Device -> Connection -> Reconnect Light Link` and `Run Bluetooth Diagnostics`.

## Install

### One-line source install

```bash
curl -fsSL https://raw.githubusercontent.com/kirniy/divoom-ditoo-pro-mac/main/install.sh | bash
```

What that does:

- clones the repo into `~/Library/Application Support/DivoomDitooProMac/repo`
- builds the app locally
- installs `DivoomMenuBar.app` into `/Applications`
- source-install path for `divoom-display` in `/usr/local/bin`
- launches the app

Choose this path if you want:

- the app bundle in `/Applications`
- a local support-repo checkout
- the `divoom-display` CLI on your `PATH`

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

Important: release artifacts install the app bundle only. They do not create a `divoom-display` symlink and they do not clone the support repo.

Choose this path if you want:

- a straightforward app install
- no local source checkout
- no CLI setup

Current release train:

- semantic versioning
- current version: `0.3.0-beta.2`
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
./bin/divoom-display native-headless purity-color --color '#19c37d'
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
- compact status strip for link, live-mode, and beam state
- native live-mode deck for Codex, Claude, split, IP flag, favorites, library, and color pick
- color motion studio with separate ambient-light beam control
- Device menu with Battery Dashboard, System Dashboard, Network Dashboard, Animated Monitor, Analog Clock, Animated Clock, and Pomodoro Timer
- animation library window with previews, favorites, recents, filters, and inspector actions
- settings window for launch at login, live feed behavior, cloud login and sync, logs, and release/about links

### Native cloud library

- source root: `assets/16x16/divoom-cloud`
- manifest: `.cache/divoom-cloud/manifest.json`
- native controls:
- `Settings -> Cloud`
- cloud account button in the native library header
- `Sync Cloud`
- `Cloud Search`

Important: cloud auth is still a beta surface. The intended stable path is to save credentials into the app Keychain. Passwords import is a one-time helper action that copies the synced `divoom-gz.com` entry into the app-local Keychain.

Current runtime truth:

- passive UI refresh does not probe Passwords or trigger cloud auth prompts
- explicit cloud actions use the app-local credential path
- direct cloud sync is working with valid credentials and produces a real native manifest
- store classify and cloud search still need more IPA parity work before they can be called finished
- importing into the app-local Keychain is the supported way to reuse the synced `divoom-gz.com` Passwords entry

If you want the smoothest path today, save a local app Keychain copy in `Settings -> Cloud` and use Passwords import only as a one-time copy helper.

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
- repeated Keychain or Passwords prompts
- release install is app-only, so the CLI is missing from `PATH`

Important recovery truth from the latest bug:

- if the menu bar app stalls during launch, the CLI will look broken too, because the CLI only talks to the running app
- the recent startup regression was caused by launch-time cloud credential access, not by the Ditoo itself
- current builds avoid that launch-time credential path, so the menu bar app reaches `ready` again before any beam request

Start here: [`docs/TROUBLESHOOTING.md`](docs/TROUBLESHOOTING.md)

Logs live at:

```text
~/Library/Logs/DivoomMenuBar.log
```

The app also has native log entry points in Settings. You can open, reveal, or export the current log from the app.

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
