# Divoom Mac

Direct macOS control stack for the Divoom Ditoo Pro with a `16x16` RGB pixel display.

## What Works

- Native macOS menu bar app for Bluetooth diagnostics and direct BLE sends
- Native CLI wrapper for the menu bar app
- Reverse-engineering notes for the official iPhone app transport
- OpenClaw integration hooks and local automation helpers

## Key Finding

For the Ditoo Pro BLE service:

- service: `49535343-FE7D-4AE5-8FA9-9FAFD205E455`
- write characteristic: `49535343-8841-43F4-A8D4-ECBE34729BB3`
- notify/read characteristic: `49535343-1E4D-4BD9-BA61-23C647249616`

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

## Project Layout

- `macos/DivoomMenuBar`: native macOS app
- `tools/divoom_mac.py`: CLI entrypoint
- `openclaw-divoom-plugin`: OpenClaw plugin
- `hooks/`: Codex / Claude local hooks
- `reverse/ios_ipa/REVERSE.md`: iPhone app reverse-engineering notes
