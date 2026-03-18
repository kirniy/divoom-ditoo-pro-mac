# OpenClaw Integration

## Local plugin package

Plugin source:

- [package.json](/Users/kirniy/dev/divoom/openclaw-divoom-plugin/package.json)
- [openclaw.plugin.json](/Users/kirniy/dev/divoom/openclaw-divoom-plugin/openclaw.plugin.json)
- [index.ts](/Users/kirniy/dev/divoom/openclaw-divoom-plugin/index.ts)

## Install

```bash
openclaw plugins install /Users/kirniy/dev/divoom/openclaw-divoom-plugin
```

## Exposed tools

- `divoom_status_push`
- `divoom_art_push`
- `divoom_media_push`
- `divoom_text_push`
- `divoom_volume_get`

## Example cron jobs

Codex status every 15 minutes:

```bash
openclaw cron add \
  --name "Divoom Codex Status" \
  --every 15m \
  --system-event "refresh divoom codex status"
```

Direct local execution is currently the cleaner path than asking the model to synthesize pixels every time.

## Recommended use

The stable architecture is:

1. `codexbar` collects live usage.
2. `divoom_mac.py` renders and uploads a 16x16 animation.
3. OpenClaw calls the local tool on demand or on a schedule.
