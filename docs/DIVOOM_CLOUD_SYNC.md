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
python3 tools/divoom_cloud_sync.py --sort most-liked --sort new-upload
python3 tools/divoom_cloud_sync.py --gallery-id 83312 --gallery-id 4272387
python3 tools/divoom_cloud_sync.py --search-query nyan --search-query bunny --skip-albums --max-per-category 0
python3 tools/divoom_cloud_sync.py --include-store-classify --include-my-list
python3 tools/divoom_cloud_sync.py --like-gallery-id 83312 --like-classify 4 --like-file-type 1
python3 tools/divoom_cloud_sync.py --like-gallery-id 83312 --like-classify 4 --like-file-type 1 --unlike
python3 tools/divoom_cloud_sync.py --redownload
```

The native app and the sync tool share the same Divoom account model, but they do not ask for credentials in the same way:

- the macOS app stores cloud login in the app Keychain
- the macOS app can import a synced Passwords entry for `divoom-gz.com` once, then reuse the local Keychain copy
- the CLI sync tool still uses `DIVOOM_EMAIL` plus `DIVOOM_PASSWORD` or `DIVOOM_MD5_PASSWORD`

Outputs:

- downloaded GIFs: `assets/16x16/divoom-cloud/`
- manifest: `.cache/divoom-cloud/manifest.json`

## Current Scope

This sync path currently covers:

- Divoom account login
- direct gallery info fetch by gallery id
- Divoom cloud categories
- Divoom cloud albums via `Discover/GetAlbumListV3` and `Discover/GetAlbumImageListV3`
- Divoom cloud search via `Channel/ItemSearch`
- Divoom cloud like / unlike via `GalleryLikeV2`
- playlist metadata via `Playlist/GetMyList` and `Playlist/GetSomeOneList`
- store classification metadata via `Channel/StoreClockGetClassify`
- optional raw store feed sync plumbing for `Channel/StoreClockGetList`, `Channel/StoreTop20`, and `Channel/StoreNew20` when an exact `--store-flag` is provided
- 16x16 animation download and GIF export
- native library ingestion from the synced output folder
- native app settings for:
  - secure email and password entry in the native Settings window
  - local-Keychain-first credentials so the app does not keep reopening Passwords prompts for passive UI state
  - enabling or disabling the cloud source in the library
  - syncing on launch
  - background sync every 6 hours
- native app controls for:
  - Sync Cloud
  - Cloud Search
  - Reveal Divoom Cloud Folder
  - Open Divoom Cloud Guide
  - a visible `Cloud Login` entry point in the native library window
  - source / feed / category / collection filters for the cloud-backed library
  - cloud like / unlike from the native inspector for synced cloud items
  - cloud-aware sorting and source browsing in the native library

The vendored `apixoo` implementation surface is now covered end to end:

- `UserLogin`
- `Cloud/GalleryInfo`
- `GetCategoryFileListV2`
- `Discover/GetAlbumListV3`
- `Discover/GetAlbumImageListV3`
- `Channel/ItemSearch`
- `GalleryLikeV2`
- `Playlist/GetMyList`
- `Playlist/GetSomeOneList`
- `Channel/StoreClockGetClassify`
- `Channel/StoreClockGetList`
- `Channel/StoreTop20`
- `Channel/StoreNew20`
- PixelBean download and GIF decode

Still pending for full Divoom iOS parity:

- exact section-to-`Flag` mapping for the iOS store/channel browser
- popularity/collection sorting that exactly matches the iOS app
- device-side custom channels and autonomous gallery playback
- deeper IPA parity for channel timing and playback activation

The native library is intentionally focused on read, sort, browse, and like flows. Write-back flows such as upload and comments remain out of scope here.
