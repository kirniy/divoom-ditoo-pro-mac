# TODO

## Next Protocol Parity

- Reverse-engineer the iOS gallery/channel stack fully from the IPA and replace any remaining host-side approximations for playlist behavior.
- Keep the verified live store envelope explicit in wrappers and docs:
  - JSON `Command` in the request body is required
  - blue-device registration is live with `Type=26` and `SubType=1`
  - the current app store sync lane runs through `--auto-store-sync`
- Recover the remaining unknowns around the live store surface instead of re-guessing the now-verified endpoints:
  - `Channel/StoreGetBanner`
  - wider non-default `StoreClockGetList.Flag` mapping
  - whether any store routes need additional device context beyond the current verified lane
- Recover additional live `Channel/ItemSearch` requirements and flags:
  - `Channel/ItemSearch` still returns `ReturnCode 1 / Failed` for the broader manual probes
  - a raw `Application/ItemSearch` probe also failed
- Recover the exact live request requirements for the FiveLCD persisted RGB lane:
  - repo wrappers and CLI probes now exist for `Channel/GetRGBInfo` and `Channel/SetRGBInfo`
  - the March 20, 2026 live `Channel/GetRGBInfo` probe returned `ReturnCode 1 / Failed`
  - do not guess extra request keys until they are pinned from the IPA or live traffic
- Recover the exact `StoreClockGetList.Flag` mapping used by the iOS app sections so the Mac app can browse every cloud store lane beyond the current verified default lane without raw low-level parameters.
- Implement the IPA-proven store split cleanly in the native library:
  - `Channel/StoreTop20`
  - `Channel/StoreNew20`
  - `Channel/StoreClockGetList` for category lanes
- Recover `Channel/StoreGetBanner` and any remaining store bootstrap routes on today’s backend so the RE-backed wrappers can cover the full iOS store shell, not just the list/detail feeds.
- Recover the exact activation flow around `sendAllFrameToDevice:galleryModel:`, `sendAnimateSpeed`, `setCustomGalleryTimeConfig`, and `sppSetSceneGIF:` so uploaded channels can play autonomously on-device.
- Implement custom animation channels/playlists in the macOS app with per-item timing, repeat rules, and persistent device-side playback where supported.
- Recover the text/drawing pipeline behind the `0x87` path and add native text/frame tools in the menu bar app.
- Continue mapping additional useful control surfaces from the iOS app: device settings, advanced scene families, clock/gallery controls, and any stable interactive modes.
- Recover the exact ambient-light mode table behind `sppSetColorMode`, `sppSetSleepCtrlMode`, and related FiveLCD RGB fields so the Mac app can expose vendor-grade backlight controls instead of raw RGB only.
- Verify whether Ditoo hardware key/button assignment can be surfaced safely on macOS for icon upload, function mapping, or button-event handling.

## Product / UI

- Keep tightening the menu bar information architecture so only working actions are visible in the primary menu.
- Expand the native animation library with better favorites management, playlists, scheduling, and channel editing.
- Add a fully native Divoom cloud store browser with section parity to the iOS app, not just the current auto-synced cache plus metadata.
- Add native store lanes that mirror the verified IPA/live findings: Top20, New20, category rows, likes, views, and cloud playlist surfaces where the backend supports them.
- Add retention controls and richer source browsing for Divoom cloud so the library can keep downloading fresh material without bloating forever.
- Continue polishing the quick-tile surface, the solid/color motion studio, and the library inspector interactions.
- Add more high-quality built-in animation sets and curate stronger defaults for menu actions and live feeds.
- Tighten install/distribution polish further so source install, `.pkg`, and `.zip` paths communicate CLI availability and support-repo expectations clearly.
- Extend the native settings surface with update flow, deeper transport recovery guidance, and better install-state diagnostics.
- Keep improving the summary card with stronger recovery cues, richer source counts, and better live-feed context.
- Capture current screenshots for the menu shell, library window, settings window, and ambient/device surfaces so the docs match the shipped app.
- Keep tightening cloud account UX so synced Passwords fallback, local save, and manual import are visible and understandable in both Settings and the native library.
- Keep README, install, and troubleshooting docs aligned with real menu labels, current install paths, and app-only release behavior.

## AI Roadmap

- Add a provider abstraction for Gemini 2, Gemini 3.1 Pro, Gemini Flash, and future Gemini variants.
- Route AI tasks by intent instead of one generic model: status-card copy, library tagging, cloud search help, log summarization, release-note drafts, and animation curation.
- Use AI only for optional, grounded status suggestions and library assistance. Do not depend on rotating headline gimmicks or opaque UI copy generation.
- Use AI to classify, tag, sort, and dedupe animation assets and cloud downloads.
- Use AI to summarize logs and failed beams from the native app, with explicit opt-in and local caching.
- Keep the AI layer practical: clear fallbacks, user-controlled model selection, and no hidden prompt magic.
- Track implementation details and provider notes in `docs/AI_ROADMAP.md`.

## Verification

- Add stronger end-to-end checks for live feed rendering, animation playback behavior, favorites rotation, and menu action health.
- Add a transport-health checklist and UI gate so the app only claims readiness when `DitooPro-Light` is actually connected and `8841` is writable.
- Keep the hidden-light-endpoint recovery procedure mirrored in docs, diagnostics output, and in-app empty states so future work does not confuse `DitooPro-Audio` with the real display path.
- Keep documenting real reverse-engineering findings in `reverse/ios_ipa/REVERSE.md` before changing protocol behavior.
- Add verification around Divoom cloud sync, manifest freshness, duplicate collapse, and source-aware library indexing.
