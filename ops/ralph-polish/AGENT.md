# Post-Verify Polish Agent Guide

This Ralph instance is for product polish after the functional lanes.

## Priorities

1. Verify build + core control still work
2. Improve menu bar UX
3. Improve iconography and information architecture
4. Improve README visuals and product communication
5. Commit and push polished, truthful improvements

## Required baseline checks

```bash
python tools/ralph_tasks/build_native.py
python tools/ralph_tasks/smoke_native.py scene-color --color '#247cff'
python tools/ralph_tasks/smoke_native.py pixel-test
```

## Rules

- Menu-bar only
- No fake feature claims
- No visible app window
- Use Swift safety discipline
- Use taste-skill and ui-ux-pro-max sensibilities for every UI change
