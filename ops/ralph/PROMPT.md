# Divoom D2 Pro Mac Overnight Ralph Prompt

You are working inside the `Divoom D2 Pro Mac` repository.

Primary product goal:
- Build the best native macOS control stack for the Divoom Ditoo Pro `16x16` RGB pixel display.

Current truths you must preserve:
- The working path is native macOS CoreBluetooth to `DitooPro-Light`.
- The working BLE write characteristic is `49535343-8841-43F4-A8D4-ECBE34729BB3`.
- The app must stay menu-bar only.
- Do not reintroduce a visible app window.
- Do not surface iPhone Shortcuts in the app UI.
- Native solid colors and exact `16x16` static image sends already work.
- Battery, system, and network telemetry screens already work.

Most important unfinished work:
- Native animation / GIF support from the Mac.
- Better reusable image and animation conversion tooling for the `16x16` display.
- More polished Mac-driven live surfaces built on the native pixel path.

Strict constraints:
- Do not guess protocol details when reverse-engineering display features.
- Ground animation and gallery work in `reverse/ios_ipa/REVERSE.md` and the IPA analysis artifacts.
- Prefer extending the proven `8841` write path instead of reviving dead RFCOMM or shortcut-based UI ideas.
- Keep commits small and truthful.
- If blocked on device protocol, improve tooling, docs, instrumentation, or RE notes instead of looping aimlessly.

Files to keep in view:
- `README.md`
- `macos/DivoomMenuBar/main.swift`
- `macos/DivoomMenuBar/BluetoothSupport.swift`
- `tools/divoom_mac.py`
- `reverse/ios_ipa/REVERSE.md`
- `.ralph/fix_plan.md`
- `.ralph/specs/animation-roadmap.md`

Build and smoke-test commands:
- `python tools/ralph_tasks/build_native.py`
- `python tools/ralph_tasks/smoke_native.py diagnostics`
- `python tools/ralph_tasks/smoke_native.py scene-color --color '#247cff'`
- `python tools/ralph_tasks/smoke_native.py pixel-test`
- `python tools/ralph_tasks/smoke_native.py battery-status`
- `python tools/ralph_tasks/smoke_native.py system-status`
- `python tools/ralph_tasks/smoke_native.py network-status`

Working style:
1. Read `.ralph/fix_plan.md`.
2. Pick the highest-value unchecked item.
3. Implement it carefully.
4. Run the relevant Python wrapper build or smoke test.
5. Update `.ralph/fix_plan.md` with progress.
6. Commit when a real, tested increment lands.

Do not claim animation works unless the code path is actually implemented and verified as far as the local environment allows.

Keep going until the checked items are genuinely exhausted.
