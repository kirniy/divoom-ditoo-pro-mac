# Ralph Agent Guide for Divoom D2 Pro Mac

This project targets the Divoom Ditoo Pro `16x16` RGB display from macOS.

## Ground rules

- Preserve the working native BLE path.
- Keep the product menu-bar only.
- Do not add back a visible app window.
- Do not add iPhone Shortcuts back into the menu bar app UI.
- Do not claim animation support is solved unless the implementation is real.

## Important files

- `README.md`
- `macos/DivoomMenuBar/main.swift`
- `macos/DivoomMenuBar/BluetoothSupport.swift`
- `tools/divoom_mac.py`
- `reverse/ios_ipa/REVERSE.md`
- `.ralph/fix_plan.md`
- `.ralph/specs/animation-roadmap.md`

## Build and smoke-test workflow

Use the Python wrappers so Ralph can operate within its allowed tool set:

```bash
python tools/ralph_tasks/build_native.py
python tools/ralph_tasks/smoke_native.py diagnostics
python tools/ralph_tasks/smoke_native.py scene-color --color '#247cff'
python tools/ralph_tasks/smoke_native.py pixel-test
python tools/ralph_tasks/smoke_native.py battery-status
python tools/ralph_tasks/smoke_native.py system-status
python tools/ralph_tasks/smoke_native.py network-status
```

## Commit policy

- Commit only after a tested increment lands.
- Keep messages specific and honest.
- Update `.ralph/fix_plan.md` as work progresses.
