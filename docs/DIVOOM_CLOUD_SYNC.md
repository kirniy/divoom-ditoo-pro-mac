# Divoom Cloud Sync

The native library can now ingest a second source root:

- local curated assets: `assets/16x16/curated`
- Divoom cloud assets: `assets/16x16/divoom-cloud`

## Sync Tool

Use:

```bash
export DIVOOM_EMAIL='you@example.com'
export DIVOOM_PASSWORD='your-password'
python3 tools/divoom_cloud_sync.py
```

Or with an md5 password hash:

```bash
export DIVOOM_EMAIL='you@example.com'
export DIVOOM_MD5_PASSWORD='...'
python3 tools/divoom_cloud_sync.py
```

Useful flags:

```bash
python3 tools/divoom_cloud_sync.py --category recommend --category top --skip-albums
python3 tools/divoom_cloud_sync.py --max-per-category 40 --max-albums 4
python3 tools/divoom_cloud_sync.py --redownload
```

Outputs:

- downloaded GIFs: `assets/16x16/divoom-cloud/`
- manifest: `.cache/divoom-cloud/manifest.json`

## Current Scope

This sync path currently covers:

- Divoom cloud categories
- Divoom cloud albums
- 16x16 animation download and GIF export
- native library ingestion from the synced output folder

Still pending for full parity:

- live auto-update scheduling from native settings
- popularity/collection sorting that exactly matches the iOS app
- device-side custom channels and autonomous gallery playback
- deeper IPA parity for channel timing and playback activation
