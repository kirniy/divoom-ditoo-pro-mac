# Divoom Ditoo Pro Mac: Product + Parity Plan

## Current verified state

### Native macOS transport

- Direct BLE control from the running menu bar app works.
- Verified working surfaces:
  - solid color scenes
  - purity RGB color
  - exact-pixel image push
  - persistent frame-streamed `.divoom16` animations
  - battery/system/network panels
  - animated monitor
  - analog/animated clock
  - pomodoro timer

### Native macOS product surfaces

- Menu-bar-only app shell
- grouped menu hierarchy
- color studio with:
  - swatches
  - hex input
  - color wheel
  - screen sampler
- native animation library window with:
  - search
  - category filtering
  - grid/list modes
  - favorites
  - recent picks
  - crisp pixel previews
  - hover beam affordances

### Integrations already present

- CodexBar usage rendering
- Claude usage rendering
- OpenClaw plugin scaffold
- local CLI + menu bar IPC bridge

## Main product gaps

### 1. Animation library UX

- stronger category navigation than a popup alone
- playlist/channel creation
- scheduling surfaces
- favorites management beyond a single toggle
- richer recents/history
- import pipeline for custom GIF/video/image assets
- drag and drop
- stronger preview inspector with timing / loop / source metadata

### 2. Menu bar UX

- richer recents/favorites submenus
- faster one-click “send last / favorite / current feed” flows
- more agent surfaces:
  - CodexBar split status
  - OpenClaw themed presets
  - current IP animated flag
- stronger top summary surface with useful rotating product-state copy instead of transport/debug text

### 3. Integration UX

- CodexBar/OpenClaw/Claude Code surfaces should feel native, not bolted on
- agent-oriented presets need their own visual identities
- OpenClaw workflows should expose:
  - on-demand push
  - scheduled push
  - crab/OpenClaw themed presets

## Main parity gaps vs iOS / vendor behavior

### 1. Gallery upload + playback activation

The hardest remaining parity gap is not raw upload. It is the vendor gallery/channel/timing activation layer after upload.

Reversed anchors already identified:

- `sendAllFrameToDevice:galleryModel:`
- `sendAnimateSpeed`
- `setCustomGalleryTimeConfig:galleryShowTimeFlag:SoundOnOff:customId:callback:ClockId:ParentClockId:ParentItemId:`
- `sppSetSceneGIF:` with command `0xB1`

What remains to recover:

- exact gallery message construction after frame upload
- how timing / loop / dwell are activated
- how channel-like playback selections are committed

### 2. Custom channels / playlists

Needed product behavior:

- group animations into a channel
- set per-item dwell / ordering / repeat behavior
- trigger from the menu bar app
- persist locally

Needed reverse-engineering behavior:

- understand vendor “gallery” / “channel” object model
- recover timing flags and related config semantics

### 3. Text / drawing / richer board control

Known anchor:

- `0x87` text/drawing path via `DrawingBoard.sendDeviceText` / `sendDeviceTextFrame`

Needed work:

- build native Mac editor/sender for vendor text frames
- map text + drawing controls into a useful macOS UI

### 4. Device button / game input / notifications

Potentially high-value parity items:

- hardware button input
- score mode / game key input
- unsolicited device state packets
- notification / alert surfaces

These need deeper packet observation and reverse engineering.

### 5. JSON / advanced vendor commands

Still open:

- `SPP_JSON`
- advanced watch-face / score / drawing-pad related branches

## Product execution order

### Phase 1: Finish the visible native experience

- strengthen animation library hierarchy
- add playlists/channels/favorites management
- tighten menu recents/favorites/integrations
- finish branded agent surfaces
- make imports/custom media first-class

### Phase 2: Finish truthful integration surfaces

- CodexBar split status
- OpenClaw presets and dashboard entry points
- current-IP animated country flag
- better live-feed and source-state surfaces without exposing legacy automation terminology

### Phase 3: Finish gallery/channel parity

- complete reverse engineering of gallery activation
- implement timing / loop / playback config on Mac
- expose custom channels/playlists in native UI

### Phase 4: Finish advanced protocol parity

- text and drawing path
- button / game input
- vendor JSON branches
- additional clock / watch-face / board features

## Definition of done

The Mac app should be considered “parity-grade” only when all of the following are true:

- native BLE path is the default for all primary display actions
- animation uploads can be activated with vendor-style timing / looping behavior
- channels/playlists exist and are editable from the Mac UI
- CodexBar / Claude / OpenClaw integrations feel first-class
- the menu bar app remains clean, fast, and menu-bar-centric
- every exposed feature is verified against either the live device or reversed vendor behavior, not guessed
