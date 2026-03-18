# Divoom D2 Pro Mac

Direct macOS control stack for the Divoom Ditoo Pro with a `16x16` RGB pixel display.

## What Works

- Native macOS menu bar app for the Ditoo Pro BLE path
- Native CLI that sends commands into the running menu bar app over IPC
- Direct solid-color scene control from the Mac
- Direct exact-pixel `16x16` static image sends from the Mac
- Native telemetry screens from the Mac:
  - AC power / battery
  - system snapshot
  - network throughput
- Reverse-engineering notes for the official iPhone app transport and GIF/gallery path
- OpenClaw integration hooks and local automation helpers

## Key Finding

For the Ditoo Pro BLE service:

- service: `49535343-FE7D-4AE5-8FA9-9FAFD205E455`
- write characteristic: `49535343-8841-43F4-A8D4-ECBE34729BB3`
- notify/read characteristic: `49535343-1E4D-4BD9-BA61-23C647249616`

The working direct path on this Mac is:

```text
Mac menu bar app -> CoreBluetooth -> DitooPro-Light -> 8841 write characteristic
```

The CLI no longer launches a fresh Bluetooth controller for each command. It opens the menu bar app if needed, then sends the action through a small IPC queue so the already-authorized app owns Bluetooth.

## Native Menu Bar App

Launch the app:

```bash
open ./build/DivoomMenuBar.app
```

What the app exposes today:

- Bluetooth diagnostics
- direct scene tests
- direct pixel test
- battery / AC status
- system status
- network status
- Codex / Claude / art sample actions

## Native CLI

Open the native app:

```bash
./bin/divoom-display native-open-app
```

Run diagnostics:

```bash
./bin/divoom-display native-headless diagnostics
```

Send the vendor-backed `0x45` scene red test:

```bash
./bin/divoom-display native-headless scene-red
```

Send the vendor-backed `0x6f` purity RGB red test:

```bash
./bin/divoom-display native-headless purity-red
```

Send a direct pixel badge test:

```bash
./bin/divoom-display native-headless pixel-test
```

Send the native telemetry screens:

```bash
./bin/divoom-display native-headless battery-status
./bin/divoom-display native-headless system-status
./bin/divoom-display native-headless network-status
```

## Overnight Worker

This repo now includes a repo-local Ralph launcher for unattended progress outside the chat loop.

Start the detached tmux session:

```bash
./bin/start-overnight-ralph
```

Check the worker:

```bash
./bin/overnight-ralph-status
```

Notes:

- It caches the latest upstream Ralph for Claude Code in `.cache/ralph-claude-code`
- It stages repo-specific templates into `.ralph/` and `.ralphrc`
- It uses Python build and smoke wrappers so Ralph can operate on the native Swift app without broad shell permissions
- It runs in stable non-live mode by default on this Mac because Ralph live streaming currently trips a Homebrew `stdbuf` dylib issue here

## Project Layout

- `macos/DivoomMenuBar`: native macOS app
- `tools/divoom_mac.py`: CLI entrypoint
- `openclaw-divoom-plugin`: OpenClaw plugin
- `hooks/`: Codex / Claude local hooks
- `reverse/ios_ipa/REVERSE.md`: iPhone app reverse-engineering notes
