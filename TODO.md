# TODO

## Next Protocol Parity

- Reverse-engineer the iOS gallery/channel stack fully from the IPA and replace any remaining host-side approximations for playlist behavior.
- Recover the exact activation flow around `sendAllFrameToDevice:galleryModel:`, `sendAnimateSpeed`, `setCustomGalleryTimeConfig`, and `sppSetSceneGIF:` so uploaded channels can play autonomously on-device.
- Implement custom animation channels/playlists in the macOS app with per-item timing, repeat rules, and persistent device-side playback where supported.
- Recover the text/drawing pipeline behind the `0x87` path and add native text/frame tools in the menu bar app.
- Continue mapping additional useful control surfaces from the iOS app: device settings, advanced scene families, clock/gallery controls, and any stable interactive modes.

## Product / UI

- Keep tightening the menu bar information architecture so only working actions are visible in the primary menu.
- Expand the native animation library with better favorites management, playlists, scheduling, and channel editing.
- Add a proper Divoom cloud source browser with source-aware filters, popularity sorting, album collections, and native sync controls.
- Add retention controls and richer source browsing for Divoom cloud so the library can keep downloading fresh material without bloating forever.
- Continue polishing the quick-tile surface, the solid/color motion studio, and the library inspector interactions.
- Add more high-quality built-in animation sets and curate stronger defaults for menu actions and live feeds.
- Improve install/distribution polish further with a package path and release assets that mirror the smoothness of CodexBar.
- Add a richer native settings surface for onboarding, Bluetooth, credits, logs, releases, updates, and install-state diagnostics.
- Improve the summary card with genuinely useful live state, motion, and source telemetry instead of Bluetooth implementation details.

## Verification

- Add stronger end-to-end checks for live feed rendering, animation playback behavior, favorites rotation, and menu action health.
- Keep documenting real reverse-engineering findings in `reverse/ios_ipa/REVERSE.md` before changing protocol behavior.
- Add verification around Divoom cloud sync, manifest freshness, duplicate collapse, and source-aware library indexing.
