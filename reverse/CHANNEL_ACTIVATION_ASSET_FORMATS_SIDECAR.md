# Channel Activation And Asset Formats Sidecar

Scope:
- Android evidence only from `reverse/android/apktool-out`
- iOS evidence only from `reverse/ios_ipa/REVERSE.md`
- No speculative claims

## 1. Cloud channel activation/playback after selection

### `Channel/SetClockSelectId` is the exact selection POST

- Request class:
  - `reverse/android/apktool-out/smali/com/divoom/Divoom/http/request/channel/wifi/WifiChannelSetClockSelectIdRequest.smali:1-49`
  - Explicit JSON field on the subclass: `ClockId`
- Inherited base-channel fields:
  - `reverse/android/apktool-out/smali/com/divoom/Divoom/http/request/channel/wifi/BaseChannelRequest.smali:6-47`
  - Constructor defaults:
    - `LcdIndependence` from `WifiChannelLcdModel.n()`: `:60-77`
    - `LcdIndex` from `WifiChannelLcdModel.o()`: `:80-97`
    - `Language` from locale helper: `:100-116`
    - `ParentItemId = ""`: `:120-124`
- Main post path:
  - `reverse/android/apktool-out/smali/com/divoom/Divoom/view/fragment/channelWifi/model/WifiChannelModel.smali:4390-4434`
  - `WifiChannelModel.b0(I)`:
    - updates local LCD model clock id via `WifiChannelLcdModel.u(I)`: `:4394-4402`
    - builds `WifiChannelSetClockSelectIdRequest`: `:4407-4411`
    - sets command `Channel/SetClockSelectId`: `:4416-4420`
    - sets `ClockId`: `:4425`
    - posts request: `:4434`
- Second exact caller:
  - `reverse/android/apktool-out/smali/com/divoom/Divoom/view/fragment/channelWifi/model/WifiChannelLcdModel.smali:2120-2170`
  - `WifiChannelLcdModel.z(...)`:
    - builds same request: `:2124-2128`
    - forces server post: `:2133-2136`
    - uses current LCD model clock id: `:2141-2157`
    - posts `Channel/SetClockSelectId`: `:2162-2170`

### Exact selection call sites

- `JumpControl.g(...)` directly triggers selection:
  - `reverse/android/apktool-out/smali/com/divoom/Divoom/view/fragment/control/JumpControl.smali:1515-1535`
  - Reads `JumpClockInfo.item.clockId` and calls `WifiChannelModel.b0(clockId)`
- `WifiChannelMainFragment` direct selection path:
  - `reverse/android/apktool-out/smali/com/divoom/Divoom/view/fragment/channelWifi/WifiChannelMainFragment.smali:893-913`
  - If `p3` is true, it calls `WifiChannelModel.b0(clockId)`

### Store-item handoff into the activation flow

- Store item click gate:
  - `reverse/android/apktool-out/smali_classes2/com/divoom/Divoom/view/fragment/myClock/adapter/MyClockStoreGroupAdapter.smali:199-281`
  - If `ClockListItem.getAddFlag() == 1`:
    - wraps the clicked item in `JumpClockInfo`: `:252-257`
    - calls `JumpControl.g(...)`: `:240-281`
- Non-activated branch:
  - `reverse/android/apktool-out/smali_classes2/com/divoom/Divoom/view/fragment/myClock/adapter/MyClockStoreGroupAdapter.smali:289-320`
  - Opens `MyClockAddFragment` instead of calling `SetClockSelectId`
- Store list request itself:
  - `reverse/android/apktool-out/smali_classes2/com/divoom/Divoom/view/fragment/myClock/adapter/MyClockStoreGroupAdapter.smali:374-445`
  - Posts `Channel/StoreClockGetList`: `:378-386`
  - Passes raw adapter `Flag`: `:436-440`
  - Passes clicked `ClassifyId`: `:445`
- Fixed example store request:
  - `reverse/android/apktool-out/smali_classes2/com/divoom/Divoom/view/fragment/photoWifi/model/PhotoWifiSendModel.smali:3202-3249`
  - `Flag = 0`: `:3211-3215`
  - `ClassifyId = 0x64`: `:3219-3223`
  - `StartNum = 1`: `:3228-3231`
  - `EndNum = 0x1e`: `:3236-3240`
  - command `Channel/StoreClockGetList`: `:3245-3249`

### `Channel/GetClockConfig` is the exact post-selection config fetch

- Request class:
  - `reverse/android/apktool-out/smali/com/divoom/Divoom/http/request/channel/wifi/WifiChannelGetClockConfigRequest.smali:1-77`
  - Explicit subclass fields: `ClockId`, `Language`
- Main channel-settings fetch:
  - `reverse/android/apktool-out/smali/com/divoom/Divoom/view/fragment/channelWifi/model/WifiChannelModel.smali:7989-8075`
  - `WifiChannelModel.v(IWifiChannelSettingView, JumpClockInfo)`:
    - sets `ClockId` from `JumpClockInfo.item`: `:8002-8018`
    - sets `ParentClockId`: `:8023-8027`
    - sets `ParentItemId`: `:8032-8036`
    - sets `Language`: `:8041-8057`
    - posts `Channel/GetClockConfig`: `:8062-8075`
- Response model:
  - `reverse/android/apktool-out/smali/com/divoom/Divoom/http/response/channel/wifi/WifiChannelGetClockConfigResponse.smali:6-63`
  - Exact fields:
    - `AlbumShapePicId`
    - `ClockExPlain`
    - `ClockExPlainPicId`
    - `IsMyLike`
    - `ItemList`
    - `ItemList2`
    - `LikeCnt`

### Exact `GetClockConfig` consumers

- Channel settings fragment:
  - `reverse/android/apktool-out/smali/com/divoom/Divoom/view/fragment/channelWifi/WifiChannelClockSettingFragment.smali:7082-7367`
  - Consumes:
    - `AlbumShapePicId`: `:7086-7094`
    - `ClockExPlain`: `:7110-7118`, `:7152-7248`
    - `ClockExPlainPicId`: `:7135-7143`
    - `ItemList`: `:7254-7282`
    - `IsMyLike`: `:7301-7320`
    - `LikeCnt`: `:7324-7367`
- Store/add fragment also fetches config through the same `WifiChannelModel.v(...)` path:
  - `reverse/android/apktool-out/smali_classes2/com/divoom/Divoom/view/fragment/myClock/MyClockAddFragment.smali:4998-5019`
  - Builds `JumpClockInfo` from the current `ClockListItem` and calls `WifiChannelModel.v(...)`
- Store/add fragment response consumption:
  - `reverse/android/apktool-out/smali_classes2/com/divoom/Divoom/view/fragment/myClock/MyClockAddFragment.smali:3882-4145`
  - Consumes:
    - `ClockExPlain`: `:3909-4061`
    - `ClockExPlainPicId`: `:3951-3959`
    - `ItemList`: `:4067-4087`
    - `IsMyLike`: `:4095-4114`
    - `LikeCnt`: `:4118-4145`

### `Channel/SetClockConfig` is the exact config-save POST

- Request class:
  - `reverse/android/apktool-out/smali/com/divoom/Divoom/http/request/channel/wifi/WifiChannelSetClockConfigRequest.smali:1-153`
  - Exact fields: `ClockId`, `ItemList`, `ItemList2`
- Save path:
  - `reverse/android/apktool-out/smali/com/divoom/Divoom/view/fragment/channelWifi/model/WifiChannelModel.smali:4036-4324`
  - `WifiChannelModel.a0(...)`:
    - sets `ClockId`: `:4199-4215`
    - sets `ParentItemId`: `:4220-4224`
    - sets `ParentClockId`: `:4229-4233`
    - writes `ItemList`: `:4238-4262`
    - writes `ItemList2`: `:4266-4305`
    - posts `Channel/SetClockConfig`: `:4311-4324`

### iOS side evidence relevant to activation/send behavior

- Playlist push candidate:
  - `reverse/ios_ipa/REVERSE.md:768-774`
  - Exact proof there is `PlayId -> Playlist/SendDevice`
- Auto-send state carriers:
  - `reverse/ios_ipa/REVERSE.md:1125-1141`
  - `DeviceFunction.isCloseAutoSendDevice`
  - `DivoomGalleryInfo.lcdSendDeviceFlag`
- Timing/activation setters:
  - `reverse/ios_ipa/REVERSE.md:1161-1187`
  - `Channel/SetSubscribeTime`
  - `Channel/SetAlbumTime`
  - `Playlist/SendDevice` remains the strongest pinned cloud-side push endpoint in the iOS note, but the note also states the downstream BLE activation chain is not yet fully proven

## 2. Newer vendor asset formats

### Top-level decoder dispatch

- Decoder class:
  - `reverse/android/apktool-out/smali/f3/b.smali`
- Opcode table includes the newer headers:
  - `reverse/android/apktool-out/smali/f3/b.smali:655-675`
  - includes `0x1a`, `0x23`, `0x29`, `0x2a`
- Exact dispatch:
  - `reverse/android/apktool-out/smali/f3/b.smali:4028-4145`
  - `0x1a -> h([B, String)`
  - `0x23 -> m([B, String)`
  - `0x29 -> k([B, String)`
  - `0x2a -> y([B, String)`

### Shared metadata helpers

- Column extractor:
  - `reverse/android/apktool-out/smali/f3/d.smali:7-119`
  - Treats `0x1a` and `0x23` as the same header-layout family for this field
- Speed extractor:
  - `reverse/android/apktool-out/smali/f3/d.smali:151-336`
  - Treats `0x1a`, `0x23`, `0x25`, `0x1f` similarly for the 2-byte speed field
- UI uses those helpers directly:
  - `reverse/android/apktool-out/smali/com/divoom/Divoom/view/custom/Pixel/StrokeImageView.smali:501-535`

### `0x1a` family

- Encoder writes header `0x1a` and 6-byte header layout:
  - `reverse/android/apktool-out/smali/f3/c.smali:6196-6299`
  - byte `0`: `0x1a`: `:6203-6207`
  - byte `1`: valid frame count: `:6211-6217`
  - bytes `2-3`: speed: `:6221-6263`
  - byte `4`: row count: `:6267-6281`
  - byte `5`: column count: `:6285-6299`
- Decoder cache keys:
  - `reverse/android/apktool-out/smali/f3/b.smali:5103-5158`
  - derives `RawDataKeyV2` and `textKey`
- Uncached decode path:
  - `reverse/android/apktool-out/smali/f3/b.smali:5178-5411`
  - logs `DivoomImage 没缓存`: `:5182-5190`
  - starts frame data at offset `6`: `:5245-5254`
  - each loop reads a 4-byte chunk length via `LW2/L.l([BI)`: `:5262-5267`
  - copies chunk bytes: `:5278-5281`
  - decodes through native pixel decoders:
    - `PixelDecode128`: `:5299-5325`
    - `PixelDecode64New`: `:5340-5356`
- Async decode path:
  - `reverse/android/apktool-out/smali/f3/g.smali:4636-4798`
  - same `DivoomImage 没缓存` log: `:4636-4644`
  - same native decoders:
    - `PixelDecode128`: `:4737-4754`
    - `PixelDecode64New`: `:4769-4786`

Evidence-backed interpretation:
- `0x1a` is the `DivoomImage` family.
- In the local `0x1a` decode path above, frames are chunked by 4-byte length and passed to native pixel decoders.
- I did not find a local symbol or branch naming an `encrypt_type` field for this family.

### `0x23` family

- Decoder entry:
  - `reverse/android/apktool-out/smali/f3/b.smali:7982-8050`
- Cache keys:
  - `reverse/android/apktool-out/smali/f3/b.smali:8094-8153`
  - derives `RawDataKeyV2` and `textKey`
- Uncached decode path:
  - `reverse/android/apktool-out/smali/f3/b.smali:8168-8435`
  - logs `lzo jpeg 没缓存`: `:8168-8176`
  - per-frame layout:
    - one selector byte at current offset: `:8207-8212`
    - 4-byte payload length immediately after it: `:8215-8220`
    - payload copy after the 5-byte prefix: `:8223-8238`
  - selector branches:
    - `0` -> `Li3/a.a([B,[B)`: `:8252-8273`
    - `1` -> `BitmapFactory.decodeByteArray(...)`: `:8304-8332`
    - `2` -> `LW2/h.m([B)[B`: `:8340-8363`
    - `3` -> `LW2/h.j([B,I)[B`: `:8371-8394`
- Async decode path:
  - `reverse/android/apktool-out/smali/f3/g.smali:743-966`
  - same selector byte and same four branches:
    - `0`: `:825-845`
    - `1`: `:859-889`
    - `2`: `:897-927`
    - `3`: `:933-963`
- Encoder evidence:
  - `reverse/android/apktool-out/smali/f3/c.smali:9783-9819`
  - logs either `用Jpeg编码` or `用MiniLzo编码`
  - writes header `0x23` plus frame count/speed/row/column at:
    - `reverse/android/apktool-out/smali/f3/c.smali:9885-9993`

Evidence-backed interpretation:
- `0x23` is the mixed MiniLZO/JPEG/other-compressed-frame family.
- The selector byte is real and local evidence proves at least values `0`, `1`, `2`, and `3`.

### `0x2a` family

- Encoder writes header `0x2a` with the same 6-byte header layout:
  - `reverse/android/apktool-out/smali/f3/c.smali:3142-3255`
- Sync decoder entry:
  - `reverse/android/apktool-out/smali/f3/b.smali:12142-12263`
  - logs `handleZSTD256`: `:12154-12162`
- Cache keys:
  - `reverse/android/apktool-out/smali/f3/b.smali:12267-12326`
  - derives `RawDataKeyV2` and `textKey`
- Uncached sync path:
  - `reverse/android/apktool-out/smali/f3/b.smali:12356-12427`
  - logs `zstd256 没缓存`: `:12356-12364`
  - text-length read at offset `6`: `:12369-12385`
  - text bytes copied from offset `0x0a`: `:12381-12397`
- Async path:
  - `reverse/android/apktool-out/smali/f3/g.smali:2570-2738`
  - logs `handleZSTD256`: `:2574-2582`
  - logs `zstd256 没缓存`: `:2661-2669`
  - computes compressed payload offset from `0x0a + textLen`: `:2674-2718`
  - decompresses with `LW2/h.j([B,I)[B`: `:2733`

Evidence-backed interpretation:
- `0x2a` is the `ZSTD256` family.
- The local path shows one compressed payload block after the text segment, not the `0x23` per-frame selector table.

### `0x29` is a separate family, not `0x23`

- Sync:
  - `reverse/android/apktool-out/smali/f3/b.smali:7172-7180`
  - logs `handleJpegZstd256`
- Async:
  - `reverse/android/apktool-out/smali/f3/g.smali:96-104`
  - logs `handleJpegZstd256`

This is the exact local reason not to merge `0x23` and `0x29`.

## 3. What I did not find locally for `0x15`

- Search across `reverse/android/apktool-out/smali/f3`, nearby static-array classes, and `reverse/ios_ipa/REVERSE.md` did not recover:
  - an `encrypt_type` symbol
  - an `EncryptType` field
  - a decoder branch tying `0x15` to the `0x1a` family
- The only `0x15` hits in `reverse/ios_ipa/REVERSE.md` are unrelated scene-structure offsets:
  - `reverse/ios_ipa/REVERSE.md:229`
  - `reverse/ios_ipa/REVERSE.md:271`
  - `reverse/ios_ipa/REVERSE.md:286`

Evidence-backed boundary:
- From the currently inspected Android/iOS reverse artifacts, I cannot make a verified claim that `encrypt_type = 0x15` belongs to the `0x1a` decoder family.
