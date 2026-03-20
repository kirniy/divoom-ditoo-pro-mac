# TODO

## Next Protocol Parity

- Reverse-engineer the iOS gallery/channel stack fully from the IPA and replace any remaining host-side approximations for playlist behavior.
- Replace the remaining guessed store/search payloads with IPA-backed ones. Current real-account verification is now explicit:
  - `Channel/StoreClockGetClassify` still returns `ReturnCode 12 / Request data is null` for the current guessed payloads.
  - `Channel/ItemSearch` still returns `ReturnCode 1 / Failed`, and a raw `Application/ItemSearch` probe failed too.
- Recover the exact `StoreClockGetList.Flag` mapping used by the iOS app sections so the Mac app can browse every cloud store lane without raw low-level parameters.
- Implement the IPA-proven store split cleanly in the native library:
  - `Channel/StoreTop20`
  - `Channel/StoreNew20`
  - `Channel/StoreClockGetList` for category lanes
- Recover the live request shape for `Channel/StoreClockGetClassify`, `Channel/StoreTop20`, and `Channel/StoreNew20` on today’s backend so the RE-backed wrappers can be verified against a real account, not just disassembly.
- Recover the exact activation flow around `sendAllFrameToDevice:galleryModel:`, `sendAnimateSpeed`, `setCustomGalleryTimeConfig`, and `sppSetSceneGIF:` so uploaded channels can play autonomously on-device.
- Implement custom animation channels/playlists in the macOS app with per-item timing, repeat rules, and persistent device-side playback where supported.
- Recover the text/drawing pipeline behind the `0x87` path and add native text/frame tools in the menu bar app.
- Continue mapping additional useful control surfaces from the iOS app: device settings, advanced scene families, clock/gallery controls, and any stable interactive modes.
- Recover the exact ambient-light mode table behind `sppSetColorMode`, `sppSetSleepCtrlMode`, and related FiveLCD RGB fields so the Mac app can expose vendor-grade backlight controls instead of raw RGB only.
- Verify whether Ditoo hardware key/button assignment can be surfaced safely on macOS for icon upload, function mapping, or button-event handling.

## Product / UI

- Keep tightening the menu bar information architecture so only working actions are visible in the primary menu.
- Expand the native animation library with better favorites management, playlists, scheduling, and channel editing.
- Add a fully native Divoom cloud store browser with section parity to the iOS app, not just synced files plus metadata.
- Add native sort lanes that mirror the IPA findings: top, newest, category rows, likes, views, and cloud playlist surfaces where the backend supports them.
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
