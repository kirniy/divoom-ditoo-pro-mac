# Divoom + macOS + OpenClaw Research

## What I verified locally

- The Ditoo can show up to macOS in two different roles:
  - `DitooPro-Audio` for the speaker/audio side
  - `DitooPro-Light` for the hidden 16x16 display-control side
- The winning display path on this Mac is the hidden BLE path:
  - `CoreBluetooth`
  - service `49535343-FE7D-4AE5-8FA9-9FAFD205E455`
  - notify/read characteristic `49535343-1E4D-4BD9-BA61-23C647249616`
  - write characteristic `49535343-8841-43F4-A8D4-ECBE34729BB3`
- `DitooPro-Light` does not need to appear in Bluetooth Settings to be usable. It is a CoreBluetooth/GATT endpoint, not a normal user-facing macOS Bluetooth device entry.
- `codexbar` is installed and returns real local usage JSON for both Codex and Claude.
- `openclaw` is installed and supports plugins plus cron jobs, which is enough to wire the display into an agent workflow.
- The audio-side RFCOMM path is not the reliable display path on this Mac:
  - `performSDPQuery` can see a serial service on the audio device
  - `openRFCOMMChannelSync` still fails in practice
  - earlier “success” periods still used the BLE light path, not RFCOMM
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

## Actual macOS transport truth

The most important correction in this repo is:

- The real working macOS path is not BlueZ and not the audio-side serial port.
- The real working macOS path is:
  - menu bar app
  - `CoreBluetooth`
  - hidden `DitooPro-Light` peripheral
  - write to `8841`

The earlier serial/RFCOMM exploration was still useful as archaeology, but it is not the transport to trust for the display on this Mac.

## Failure mode we just hit

This broke in a specific, repeatable way:

1. The app kept a cached UUID for a previously working `DitooPro-Light` peripheral.
2. Later, the live light endpoint stopped appearing in fresh BLE scans.
3. The app could still see `DitooPro-Audio`, which made the machine look “sort of connected.”
4. RFCOMM on the audio side was still failing, so display actions had no viable fallback.
5. The UI was overstating readiness because `BLE scan finished` is not the same thing as `BLE light write characteristic ready`.

What proved this:

- Earlier success logs showed:
  - `didDiscover BLE Ditoo name=DitooPro-Light`
  - `didConnect BLE peripheral name=DitooPro-Light`
  - `BLE light write characteristic ready ...8841`
  - successful `runNativeBLESolidColor ... characteristic=...8841`
- Failure logs later showed:
  - only `DitooPro-Audio`
  - `BLE light idle`
  - `LE scan: none`
  - `BLE light transport not ready`

## What recovered it

The recovery sequence that got real beams back was:

1. Reconfirm we were using the current app, not an archival build.
2. Compare the current BLE controller with the last pushed working branch.
3. Remove the new BLE connect watchdog/retry logic that was not part of the proven working path.
4. Relaunch the current menu bar app cleanly.
5. Restart the Ditoo so the hidden light-side BLE endpoint could advertise again.
6. Verify the real path, not a fake proxy:
  - `LE scan` includes `DitooPro-Light`
  - `BLE light connected`
  - `BLE light write characteristic ready ...8841`
  - `scene-color` succeeds
  - `send-gif` succeeds

## How to not lose this again

- Treat `DitooPro-Light` as the source of truth for the screen.
- Do not treat `DitooPro-Audio` as proof that the display path is healthy.
- Do not treat `BLE scan finished` as success. Success is:
  - `BLE light connected`
  - and ideally `BLE light write characteristic ready`
- Keep the UI transport-aware:
  - `Light Ready`
  - `Light Connecting`
  - `Audio Only`
  - `No Light Link`
- Avoid speculative BLE recovery logic in the critical path unless it is verified on-device against the real peripheral.
- When transport breaks, check the log in this exact order:
  1. Is `DitooPro-Light` in `LE scan`?
  2. Did we get `didConnect`?
  3. Did `8841` become ready?
  4. If not, do not assume audio/RFCOMM can save the session.

## Current blocker for full parity

The blocker is no longer “how to talk to the screen at all.” That part is proven.

The real blocker is full iOS parity on top of the working BLE light transport:

- cloud store browsing and sorting parity
- likes/unlikes and collections
- custom channel / playlist timing
- autonomous on-device gallery/channel playback
- text/drawing and additional scene families

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

### 1. Keep BLE light transport isolated from higher-level features

Do not let UI work, cloud sync, or automation-like behavior obscure the fact that all screen features depend on a healthy `DitooPro-Light -> 8841` path.

This needs explicit diagnostics and explicit UI state, not optimistic summaries.

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

- Audio-side RFCOMM probing can enumerate services but still fail channel open.
- The display-control BLE path is the one that actually matters.
- The iOS IPA and local logs agree on the hidden BLE transport:
  - service `FE7D`
  - notify `1E4D`
  - write `8841`
