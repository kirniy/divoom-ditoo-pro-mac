# Morning Verify Agent Guide

This Ralph instance exists to verify and fix the native macOS app for the Divoom Ditoo Pro `16x16` RGB display after overnight work.

## Priorities

1. Build
2. Relaunch if necessary
3. Smoke-test the real native paths
4. Fix failures
5. Continue reverse-engineering and implementation on unfinished animation playback

## Required checks

```bash
python tools/ralph_tasks/build_native.py
python tools/ralph_tasks/smoke_native.py scene-color --color '#247cff'
python tools/ralph_tasks/smoke_native.py pixel-test
python tools/ralph_tasks/smoke_native.py animation-upload --path andreas-js/images/witch.divoom16
```

## Rules

- Do not mark the project done just because uploads succeed.
- Animation playback is not done until it is honestly verified.
- Keep fixes small and tested.
