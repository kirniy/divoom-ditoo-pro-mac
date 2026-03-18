# Divoom + macOS + OpenClaw Research

## What I verified locally

- The Ditoo is already paired to this Mac as `DitooPro-Audio`.
- macOS exposes a serial endpoint at `/dev/cu.DitooPro-Audio`.
- `codexbar` is installed and returns real local usage JSON for both Codex and Claude.
- `openclaw` is installed and supports plugins plus cron jobs, which is enough to wire the display into an agent workflow.

## What the `futpib/divoom-ditoo-pro-controller` fork already does

- Static image upload
- Divoom animation upload
- Static text
- Scrolling text
- Video playback via frame streaming
- Brightness
- Volume get/set
- Play/pause
- Clock face get/set
- Language
- Keyboard backlight
- Alarm
- Box/display modes
- Basic response parsing with ACK/NAK handling

## Current blocker for macOS

The Rust repo is still built around Linux Bluetooth assumptions. The current transport is tied to RFCOMM/BlueZ-style connection management, and `Development.md` explicitly notes Linux-only transport history.

On this Mac, the right direction is not BlueZ. It is a macOS transport backend that can use the already exposed serial device (`/dev/cu.DitooPro-Audio`) or an IOBluetooth-based RFCOMM client.

## OpenClaw integration path

The clean architecture is:

1. `codexbar` provides usage JSON.
2. A local Divoom controller renders status into a 16x16 animation or text scene.
3. OpenClaw triggers it through:
   - a plugin tool for on-demand updates
   - or a cron job for periodic refresh

Suggested plugin tools:

- `divoom_status_render`
- `divoom_status_push`
- `divoom_mode_set`
- `divoom_text_show`
- `divoom_animation_play`

## Best upstream contribution priorities

### 1. Abstract transport from protocol

Create a transport trait/interface so packet encoding/decoding is independent from Bluetooth stack details.

Backends:

- Linux RFCOMM via current path
- macOS serial transport via `/dev/cu.*`
- future native macOS RFCOMM transport if needed

This is the highest-value change because it unlocks everything else on macOS.

### 2. Make setters optionally ACK-aware

The repo already parses replies, but many setters still use fire-and-forget. Add a mode that waits for ACK/NAK so failures are observable.

### 3. Add a protocol exploration/sniff mode

A raw log mode that records unsolicited packets and unknown response payloads would help reverse engineer:

- game key input
- notifications
- extra device state
- JSON-based commands

### 4. Finish small high-value TODOs first

These look tractable and useful:

- GIF speed control
- screen direction configuration
- set box color / sleep color
- configurable adapter or transport selection

### 5. Tackle bigger unlocks next

- JSON-based command protocol (`SPP_JSON`)
- drawing pad control
- watch face mode
- score mode
- game key input

## Recommended order for actual work

1. Land macOS transport support.
2. Add a raw packet debug mode.
3. Finish GIF speed control.
4. Reverse engineer `SPP_JSON` and game/button input.
5. Build an OpenClaw plugin around the controller once transport is stable.

## Notes from local probing

- Writes to `/dev/cu.DitooPro-Audio` succeed.
- Readback is not stable yet; I saw no response data and then a macOS serial read error (`Device not configured`).
- That means the port is real, but transport handling needs proper mac-specific work before I would trust round-trip behavior.
