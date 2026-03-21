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
python3 tools/divoom_cloud_sync.py --auto-store-sync --max-per-category 40
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
- the macOS app now runs the sync tool with `--include-store-classify --include-my-list --auto-store-sync`

Outputs:

- downloaded GIFs: `assets/16x16/divoom-cloud/`
- manifest: `.cache/divoom-cloud/manifest.json`

## Current Scope

This sync path currently covers:

- Divoom account login
- required JSON `Command` injection on cloud/store requests
- blue-device registration via `APP/GetServerUTC` plus `BlueDevice/NewDevice`
- direct gallery info fetch by gallery id
- Divoom cloud categories
- Divoom cloud albums via `Discover/GetAlbumListV3` and `Discover/GetAlbumImageListV3`
- Divoom cloud search via `Channel/ItemSearch`
- Divoom gallery like / unlike via `GalleryLikeV2`
- store/channel like / unlike via `Channel/LikeClock`
- playlist metadata via `Playlist/GetMyList` and `Playlist/GetSomeOneList`
- store classification metadata via `Channel/StoreClockGetClassify`
- live store feed sync plumbing for `Channel/StoreClockGetList`, `Channel/StoreTop20`, and `Channel/StoreNew20`
- store banner sync plumbing for `Channel/StoreGetBanner`
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
  - visible `Connect Cloud…` / `Cloud Settings…` entry points in the native library and settings windows
  - `Save + Verify` and `Import + Verify` credential flows
  - source / feed / category / collection filters for the cloud-backed library
  - cloud like / unlike from the native inspector for synced cloud items
  - cloud-aware sorting and source browsing in the native library

The vendored `apixoo` implementation surface is now covered end to end:

- `UserLogin`
- `APP/GetServerUTC`
- `BlueDevice/NewDevice`
- `Cloud/GalleryInfo`
- `GetCategoryFileListV2`
- `Discover/GetAlbumListV3`
- `Discover/GetAlbumImageListV3`
- `Channel/ItemSearch`
- `GalleryLikeV2`
- `Channel/LikeClock`
- `Playlist/GetMyList`
- `Playlist/GetSomeOneList`
- `Channel/StoreClockGetClassify`
- `Channel/StoreClockGetList`
- `Channel/StoreTop20`
- `Channel/StoreNew20`
- `Channel/StoreGetBanner`
- `Channel/GetRGBInfo`
- `Channel/SetRGBInfo`
- PixelBean download and GIF decode

## Current truth

Working now:

- cloud auth verified against the live backend via `UserLogin`
- login via the sync tool environment variables
- app-local Keychain credential save path with live verification
- one-time synced Passwords import path with live verification
- the wrapper now injects the required JSON `Command` field for cloud/store requests
- blue-device registration is live via `APP/GetServerUTC` + `BlueDevice/NewDevice` with `Type=26` and `SubType=1`
- `Sync Cloud` in the macOS app now uses `--auto-store-sync`
- `Channel/StoreClockGetClassify`, `Channel/StoreClockGetList`, `Channel/StoreTop20`, `Channel/StoreNew20`, `Channel/StoreGetBanner`, and `Channel/LikeClock` are live-verified
- the synced manifest now records `storeBanners` once that same blue-device context is present
- sync, search, and gallery like / unlike plumbing
- local manifest generation and native library ingestion

Still rough:

- cloud auth UX inside the macOS app still needs more product polish
- the native library is still cache-first and does not yet expose a full live store browser
- store flag mapping beyond the current default auto-sync lane is still incomplete
- newer `0x1a` cloud payloads with inner `encrypt_type 21` are still unsupported
- the raw FiveLCD RGB channel endpoints are wired in the backend and CLI now, but the March 20, 2026 live `Channel/GetRGBInfo` probe still returned `ReturnCode 1 / Failed`
- exact parity with the iOS store/channel browser and post-upload playback activation

Still pending for full Divoom iOS parity:

- exact iOS store routing:
  - header tab `0 -> Channel/StoreTop20`
  - header tab `1 -> Channel/StoreNew20`
  - category rows -> `Channel/StoreClockGetList` with raw `Flag` plus `ClassifyId`
- exact iOS store payloads now pinned:
  - `Channel/StoreClockGetClassify` sends only `CountryISOCode` and `Language`
  - `Channel/StoreTop20` and `Channel/StoreNew20` send only `CountryISOCode`, `Language`, and raw `Flag`
  - `Channel/StoreClockGetList` sends `CountryISOCode`, `Language`, `Flag`, `ClassifyId`, `StartNum`, and `EndNum`
- preserving raw store/channel fields such as `AddFlag`, `LikeCnt`, `IsMyLike`, `ClockType`, `ImagePixelId`, `ParentClockId`, and `ParentItemId`
- the remaining unsupported `0x1a` branch with inner `encrypt_type 21`
- wider `Flag` mapping beyond the default live auto-sync lane
- generic `Channel/ItemSearch` `ItemFlag` values beyond the verified `SearchUser`
- device-side custom channels and autonomous gallery playback
- the split custom-channel activation flow:
  - `Channel/SetCustom` binds the custom asset
  - `Channel/GetCustomGalleryTime` and `Channel/SetCustomGalleryTime` control `SingleGalleyTime`, `GalleryShowTimeFlag`, and `SoundOnOff`
  - BLE upload / scene activation still happens separately on the device side

## Verified parity notes

- `Channel/StoreClockGetClassify` is not keyed by `Flag`; Android posts it with a plain `BaseLoadMoreRequest` and the response is `ClassifyList` items with `ClassifyId` and `ClassifyName`.
- The current `apixoo` fork and `tools/divoom_cloud_sync.py` now serialize the IPA-confirmed Top20/New20 request family instead of the older guessed `PageIndex` / `ClockId` branch.
- The live backend required the JSON `Command` field. The wrapper now injects it centrally instead of relying on the path alone.
- Store/channel requests also needed live blue-device context. The current working registration path is `APP/GetServerUTC` + `BlueDevice/NewDevice` with `Type=26` and `SubType=1`.
- The current macOS app uses `--auto-store-sync`, which registers that blue-device context and syncs Top20, New20, and live classify buckets with default `Flag=0`.
- `Channel/StoreClockGetClassify`, `Channel/StoreClockGetList`, `Channel/StoreTop20`, `Channel/StoreNew20`, and `Channel/LikeClock` are now live-verified through the current wrapper.
- The current sync docs previously described store/channel likes as `GalleryLikeV2`. That is incorrect for the iOS store/channel surface. The IPA and Android cross-check both use `Channel/LikeClock`.
- `Channel/StoreGetBanner` is live once the same blue-device context used by store list requests is present, and the current sync manifest now preserves that banner payload.
- `0x23` and `0x2a` vendor payloads now decode in the vendored `apixoo` fork against real cloud files.
- the remaining unsupported store assets in the current sync lane are the `0x1a` payloads that carry inner `encrypt_type 21`.
- `AddFlag` is not the same thing as like state. On store/channel items it is the separate added/collected state, while like state lives in `LikeCnt` / `IsMyLike`.
- Custom timing parity is not a single save step. Android applies `Channel/SetCustomGalleryTime` immediately on every timing/toggle change, and iOS `needUploadCustomTimeData:` is only a UI label-update helper, not the transport write.

The native library is intentionally focused on read, sort, browse, and like flows. Write-back flows such as upload and comments remain out of scope here.

For user-facing install and recovery steps, see [`INSTALL.md`](./INSTALL.md) and [`TROUBLESHOOTING.md`](./TROUBLESHOOTING.md).
