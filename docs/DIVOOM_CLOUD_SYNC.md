# Divoom Cloud Sync

The native animation library can ingest a second source root:

- local curated assets: `assets/16x16/curated`
- Divoom cloud assets: `assets/16x16/divoom-cloud`

This is a real working surface, but it is still early beta from a product and parity standpoint.

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
python3 tools/divoom_cloud_sync.py --print-rgb-info
python3 tools/divoom_cloud_sync.py --set-rgb-info --rgb-on-off 1 --rgb-brightness 80 --rgb-select-light-index 0 --rgb-color '#FFFFFF'
python3 tools/divoom_cloud_sync.py --redownload
```

The native app and the sync tool share the same Divoom account model, but they do not ask for credentials in the same way:

- the macOS app stores cloud login in the app Keychain
- the macOS app can import a synced Passwords entry for `divoom-gz.com` once
- the CLI sync tool still uses `DIVOOM_EMAIL` plus `DIVOOM_PASSWORD` or `DIVOOM_MD5_PASSWORD`

Recommended product path:

- keep passive UI reads silent
- save a local app Keychain copy if you want the smoothest in-app path
- `Save + Verify` and `Import + Verify` now sign into Divoom first and only then persist the local Keychain copy
- use import only when you actually want to refresh the local copy from synced Passwords

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
- Divoom gallery like / unlike via `GalleryLikeV2`
- playlist metadata via `Playlist/GetMyList` and `Playlist/GetSomeOneList`
- store classification metadata via `Channel/StoreClockGetClassify`
- optional raw store feed sync plumbing for `Channel/StoreClockGetList`, `Channel/StoreTop20`, and `Channel/StoreNew20`
- raw FiveLCD RGB probe plumbing for `Channel/GetRGBInfo` and `Channel/SetRGBInfo`
- 16x16 animation download and GIF export
- native library ingestion from the synced output folder
- native app settings for:
  - secure email and password entry in the native Settings window
  - app-local Keychain storage for stable runtime auth
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
- `Channel/GetRGBInfo`
- `Channel/SetRGBInfo`
- PixelBean download and GIF decode

## Current truth

Working now:

- login via the sync tool environment variables
- app-local Keychain credential save path with live verification
- one-time synced Passwords import path with live verification
- sync, search, and gallery like / unlike plumbing
- local manifest generation and native library ingestion

Still rough:

- cloud auth UX inside the macOS app still needs more product polish
- store/search payload parity is still incomplete even though login itself is verified
- the raw FiveLCD RGB channel endpoints are wired in the backend and CLI now, but the March 20, 2026 live `Channel/GetRGBInfo` probe still returned `ReturnCode 1 / Failed`
- exact parity with the iOS store/channel browser

Still pending for full Divoom iOS parity:

- store/channel likes via `Channel/LikeClock` with `ClockId` and `LikeFlag`
- exact iOS store routing:
  - header tab `0 -> Channel/StoreTop20`
  - header tab `1 -> Channel/StoreNew20`
  - category rows -> `Channel/StoreClockGetList` with raw `Flag` plus `ClassifyId`
- preserving raw store/channel fields such as `AddFlag`, `LikeCnt`, `IsMyLike`, `ClockType`, `ImagePixelId`, `ParentClockId`, and `ParentItemId`
- generic `Channel/ItemSearch` `ItemFlag` values beyond the verified `SearchUser`
- device-side custom channels and autonomous gallery playback
- the split custom-channel activation flow:
  - `Channel/SetCustom` binds the custom asset
  - `Channel/GetCustomGalleryTime` and `Channel/SetCustomGalleryTime` control `SingleGalleyTime`, `GalleryShowTimeFlag`, and `SoundOnOff`
  - BLE upload / scene activation still happens separately on the device side

## Verified parity notes

- `Channel/StoreClockGetClassify` is not keyed by `Flag`; Android posts it with a plain `BaseLoadMoreRequest` and the response is `ClassifyList` items with `ClassifyId` and `ClassifyName`.
- The current sync docs previously described store/channel likes as `GalleryLikeV2`. That is incorrect for the iOS store/channel surface. The IPA and Android cross-check both use `Channel/LikeClock`.
- `AddFlag` is not the same thing as like state. On store/channel items it is the separate added/collected state, while like state lives in `LikeCnt` / `IsMyLike`.
- Custom timing parity is not a single save step. Android applies `Channel/SetCustomGalleryTime` immediately on every timing/toggle change, and iOS `needUploadCustomTimeData:` is only a UI label-update helper, not the transport write.

The native library is intentionally focused on read, sort, browse, and like flows. Write-back flows such as upload and comments remain out of scope here.

For user-facing install and recovery steps, see [`INSTALL.md`](./INSTALL.md) and [`TROUBLESHOOTING.md`](./TROUBLESHOOTING.md).
