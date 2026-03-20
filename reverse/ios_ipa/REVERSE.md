# Divoom iOS IPA Reverse Engineering Notes

Target IPA:
- `/Users/kirniy/dev/divoom/com.divoom.Smart_3.8.02_und3fined.ipa`

Extracted app:
- `/Users/kirniy/dev/divoom/reverse/ios_ipa/Payload/Aurabox.app`

Main binary:
- `/Users/kirniy/dev/divoom/reverse/ios_ipa/Payload/Aurabox.app/Aurabox`

Bundle metadata:
- bundle id: `com.divoom.Smart`
- version: `3.8.02 (3802)`
- URL scheme: `divoomapp://...`

This app controls more than one Divoom product. For the current hardware target, the relevant device is the Divoom Ditoo Pro with a `16x16` RGB pixel display.

## Main Findings

The app's real Bluetooth/display control logic lives in the `Aurabox` app binary, not in an extension or a helper framework.

High-signal Objective-C classes and selectors in the main binary:
- `BLECommLayer`
- `BLEPeripheral`
- `sendSppCmd:data:`
- `sendSppCmd:data:ack:`
- `sppSetSystemBright:`
- `sppSetScene:`
- `sppSetSceneGIF:`
- `ProtocolPackageWithCommand:Data:PacketID:isNewMode:TransmitMode:`
- `SendDataToQueueWithData:PacketID:isNewMode:TransmitMode:Command:isResponse:onePacketSize:`
- `SendDataToDeviceWithCommand:Data:Peripheral:TransmitMode:isResponse:`

Relevant BLE UUID strings in the binary:
- service: `49535343-FE7D-4AE5-8FA9-9FAFD205E455`
- characteristic: `49535343-1E4D-4BD9-BA61-23C647249616`
- characteristic: `49535343-8841-43F4-A8D4-ECBE34729BB3`

`SppManager.configure` hard-wires the Ditoo Pro transparent BLE service as:
- service UUID: `FE7D`
- `txUUID = 1E4D`
- `rxUUID = 8841`

And the subsequent characteristic discovery logic uses those names from the phone/app perspective:
- `1E4D` is matched first, stored via `setRxCharacteristic:`, and subscribed with `setNotifyValue:YES`
- `8841` is matched second and stored via `setTxCharacteristic:`

Practical implication for the macOS port:
- `8841` is the vendor app's write characteristic for Ditoo Pro
- `1E4D` is the notify/read characteristic, not the normal write target

## Proven Packet Builders

The app has two packet families.

### 1. Old-mode packet format

Method:
- `BLECommLayer OldDevicePackage:Command:`
- IMP: `0x100370220`

Raw inner packet before escaping:

```text
len_le16 + cmd_u8 + data + checksum_le16
```

Where:
- `len_le16 = len(data) + 3`
- `checksum_le16 = sum(inner_without_checksum_bytes) & 0xffff`
- checksum is calculated over:
  - `len_le16`
  - `cmd_u8`
  - `data`

The app then escapes the inner bytes:
- `0x01 -> 0x03 0x04`
- `0x02 -> 0x03 0x05`
- `0x03 -> 0x03 0x06`

Final on-wire old-mode packet:

```text
01 + escape(len_le16 + cmd_u8 + data + checksum_le16) + 02
```

This is the classic Divoom frame.

### 2. New-mode packet format

Methods:
- `BLECommLayer ProtocolPackageWithCommand:Data:PacketID:isNewMode:TransmitMode:`
- IMP: `0x100370570`
- `BLECommLayer NewDevicePackage:PacketID:TransmitMode:`
- IMP: `0x100370414`

Important detail:
- `ProtocolPackageWithCommand...` prepends the command byte to the payload data before calling `NewDevicePackage`.
- So new-mode packages `payload = cmd_u8 + data`.

`NewDevicePackage` writes the 4-byte header:

```text
FE EF AA 55
```

Then appends:

```text
len_le16 + transmit_mode_u8 + [packet_id_le32 if transmit_mode == 1] + payload + checksum_le16
```

Where:
- `payload = cmd_u8 + data`
- if `transmit_mode != 1`:
  - `len_le16 = len(payload) + 3`
  - there is no packet id field
- if `transmit_mode == 1`:
  - `len_le16 = len(payload) + 7`
  - packet id is 4 bytes, little-endian

Checksum rule:
- `checksum_le16 = sum(all bytes after the FE EF AA 55 header, excluding the checksum itself) & 0xffff`

In other words, checksum covers:
- `len_le16`
- `transmit_mode_u8`
- optional `packet_id_le32`
- `payload`

It does not include:
- the leading `FE EF AA 55`
- the checksum field itself

This matches the known sample packet:

```text
fe ef aa 55 0b 00 00 45 01 ff 00 00 64 00 01 b5 01
```

Breakdown:
- header: `fe ef aa 55`
- len: `0b 00`
- transmit mode: `00`
- payload: `45 01 ff 00 00 64 00 01`
- checksum: `b5 01`

Verification:
- `0x000b + 0x00 + 0x45 + 0x01 + 0xff + 0x00 + 0x00 + 0x64 + 0x00 + 0x01 = 0x01b5`
- checksum on wire is little-endian `b5 01`

## Confirmed Command Builders

### Brightness

Method:
- `BLEPeripheral sppSetSystemBright:`
- IMP: `0x10088dce8`

What it does:
- builds a 1-byte `NSData`
- calls `sendSppCmd:data:` with command `0x74`

Wire meaning:

```text
cmd 0x74
data = [brightness_u8]
```

### Scene / front-display state

Method:
- `BLEPeripheral sppSetScene:`
- IMP: `0x10088e198`

What it does:
- builds a variable-length payload on the stack
- wraps it in `NSData`
- sends it with command `0x45`

So:

```text
cmd 0x45
data = scene payload
```

The payload is model-family dependent. The app branches based on the return value of helper `0x101018b20`.

For documentation below:
- Family A = helper returns `2` or `4`
- Family B = helper returns anything else

## `0x45` Scene Payload Map

The first byte is always `scene_mode` from the `DivoomTimeBoxScene_t` struct.

The app then fills the rest of the payload from fixed offsets in the scene struct. The table below records the exact byte sourcing from the disassembly. Semantic names for every field are not all resolved yet, but the byte offsets are real.

### Family A (`helper == 2 || helper == 4`)

`scene_mode = 0`

```text
[00] = scene_mode
[01] = byte @ +0x1a
[02:03] = le16 @ +0x1b
[04] = byte @ +0x20
length = 5
```

`scene_mode = 1`

```text
[00] = scene_mode
[01] = byte @ +0x08
[02:03] = le16 @ +0x1e
[04] = byte @ +0x20
length = 5
```

`scene_mode = 2`

```text
[00] = scene_mode
[01:04] = le32 @ +0x11
[05] = byte @ +0x15
length = 6
```

`scene_mode = 3`

```text
[00] = scene_mode
[01] = byte @ +0x28
length = 2
```

`scene_mode = 4`

```text
[00] = scene_mode
[01] = byte @ +0x18
[02:05] = le32 @ +0x21
[06] = byte @ +0x25
[07] = byte @ +0x26
length = 8
```

### Family B (`helper != 2 && helper != 4`)

`scene_mode = 0`

```text
[00] = scene_mode
[01] = byte @ +0x1a
[02:05] = le32 @ +0x29
[06] = byte @ +0x2d
[07:08] = le16 @ +0x1b
[09] = byte @ +0x1d
length = 10
```

`scene_mode = 1`

```text
[00] = scene_mode
[01:04] = le32 @ +0x11
[05] = byte @ +0x15
[06] = byte @ +0x16
length = 7
```

Confirmed writer:
- `MiniLightBoxVC colorSliderAction:` (`0x10060be08`)

What that UI path does before calling `blePeripheral.sppSetScene:`:

```text
scene[+0x11] = red
scene[+0x12] = green
scene[+0x13] = blue
scene[+0x14] = brightness
scene[+0x15] = 0x00
scene[+0x16] = preserved
```

So the live app's RGB slider path is not a separate "full color" command here; it mutates the
`scene_mode = 1` scene payload bytes and sends them through `sppSetScene:`.

`scene_mode = 2`

```text
[00] = scene_mode
length = 1
```

`scene_mode = 3`

```text
[00] = scene_mode
[01] = byte @ +0x28
length = 2
```

`scene_mode = 4`

```text
[00] = scene_mode
[01] = byte @ +0x18
length = 2
```

## Send Pipeline

High-level call chain:

```text
BLEPeripheral.sendSppCmd:data:
  -> BLEPeripheral.addOperationSendSQueue:data:
  -> BLECommLayer.SendDataToDeviceWithCommand:Data:Peripheral:TransmitMode:isResponse:
  -> BLECommLayer.ProtocolPackageWithCommand:Data:PacketID:isNewMode:TransmitMode:
  -> BLECommLayer.SendDataToQueueWithData:PacketID:isNewMode:TransmitMode:Command:isResponse:onePacketSize:
```

### `sendSppCmd:data:`

Method:
- IMP: `0x10088c568`

This is the normal send path that queues a command/data pair.

### `sendSppCmd:data:ack:`

Method:
- IMP: `0x10088c708`

This is the path that routes through the ack-aware queue/send logic.

### `SendDataToDeviceWithCommand...`

Method:
- `BLECommLayer SendDataToDeviceWithCommand:Data:Peripheral:TransmitMode:isResponse:`
- IMP: `0x1003708a0`

What it clearly does:
- verifies the peripheral is usable
- fetches device/state flags from a singleton
- chooses whether to use old or new mode
- allocates a packet id only when:
  - `transmit_mode == 1`
  - `isNewMode == 1`
- chooses a `onePacketSize` value:
  - fallback `0x70`
  - alternate values `0x8a` or `0xb9` for another device/state branch
- builds packaged bytes via `ProtocolPackageWithCommand...`
- queues them via `SendDataToQueueWithData...`

Resolved helper selectors from the trampoline calls:
- `0x10102c360 -> blueEnum`
- `0x1010b4540 -> wifiBlueArch`
- `0x10101bc80 -> PacketID`
- `0x1010542a0 -> isConnected`
- `0x10101c800 -> ProtocolPackageWithCommand:Data:PacketID:isNewMode:TransmitMode:`

So the old-vs-new choice is gated by a device capability property called `blueEnum`, and the packet-size variant is gated by `wifiBlueArch`.

### `SendDataToQueueWithData...`

Method:
- `BLECommLayer SendDataToQueueWithData:PacketID:isNewMode:TransmitMode:Command:isResponse:onePacketSize:`
- IMP: `0x1003706b0`

Observed queue item facts:
- allocates a `0x40` byte queue node
- stores:
  - command
  - transmit mode
  - flags
  - packet id when applicable
  - copied packet bytes
  - packet length
  - one-packet size
  - computed packet count
- enqueues onto one of the internal send queues

## Practical Implications

The earlier macOS attempts were wrong in at least one critical way:
- the iOS app's new-mode frame is not just `header + command + data + checksum`
- it is:

```text
FE EF AA 55 + len + transmit_mode + optional_packet_id + (cmd + data) + checksum
```

And the checksum is not vague or guessed. It is a straight 16-bit little-endian sum over everything after the header and before the checksum.

For classic old-mode packets, the framing is also now fully defined:

```text
01 + escape(len + cmd + data + checksum) + 02
```

The Android device tables in `reverse/android/apktool-out` also put `DitooPro` in the vendor's `NewAniSendMode2020` family. That does not prove every command for every transport path, but it is strong evidence that Ditoo Pro should not be treated as an old-mode-only device.

## Alternate Solid-Color Path

There is also a grounded direct RGB command in the IPA:

- `BLEPeripheral sppFillPurityColor:g:b:` sends command `0x6f` with a 3-byte RGB payload
- the named wrapper `sppSetFullColorR:G:B:` also emits `0x6f`, but static analysis has not found a normal caller for that selector yet
- concrete traced call chain:
  - `fillColor:g:b:` at `0x1001de5cc`
  - callsite `0x1001de650`
  - `BLEPeripheral sppFillPurityColor:g:b:` at `0x100890fc8`
  - `sendSppCmd:data:` with command byte `0x6f`

So there are two real solid-color candidates from the vendor app:
- `0x45` scene-mode payloads via `sppSetScene:`
- `0x6f` pure RGB payloads via `sppFillPurityColor:g:b:`

## GIF / Gallery Pipeline Targets

The next animation/content path should target the app's GIF/gallery stack, not broad packet guessing.

Confirmed Objective-C stubs:
- `_uploadGalleryFor16:MusicData:ReviewFlag:CompletionHandler:`: `0x101023ba0`
- `messageWithGIFImageData:width:height:`: `0x10105de60`
- `praseGIFDataToImageArray:`: `0x101067a40`
- `praseGIFDelay:`: `0x101067a60`
- `praseGIFDelayTime:`: `0x101067a80`
- `saveOrUploadGalleryFor16`: `0x1010711c0`
- `uploadGalleryFor16:MusicData:CompletionHandler:`: `0x1010b1bc0`

Important correction:
- The `messageWithGIFImageData:width:height:` / `praseGIF*` addresses above resolve to Objective-C selector stubs in `__objc_stubs`, not to the final implementation bodies. They are still useful anchors for caller tracing, but not the place to recover real parsing logic directly.

Confirmed direct callers:
- `0x1000974a4 -> saveOrUploadGalleryFor16`
- `0x1001a5c40 -> praseGIFDataToImageArray:`
- `0x1001a5c5c -> praseGIFDelay:`
- `0x100252a94 -> uploadGalleryFor16:MusicData:CompletionHandler:`
- `0x10041b788 -> _uploadGalleryFor16:MusicData:ReviewFlag:CompletionHandler:`
- `0x10041b980 -> _uploadGalleryFor16:MusicData:ReviewFlag:CompletionHandler:`
- `0x100491790 -> praseGIFDataToImageArray:`
- `0x1004917a8 -> praseGIFDelayTime:`
- `0x10054ffb8 -> uploadGalleryFor16:MusicData:CompletionHandler:`
- `0x1005ab248 -> praseGIFDataToImageArray:`
- `0x1005aba00 -> praseGIFDataToImageArray:`
- `0x1005aba18 -> praseGIFDelayTime:`
- `0x10066ef4c -> messageWithGIFImageData:width:height:`

Additional instruction-level findings from the `Aurabox` binary:
- `sppSetSceneGIF:` IMP `0x10088dfac` zeroes a fixed `185`-byte buffer, copies a `DivoomTimeboxSceneGIf_t={CCC[182C]}` struct into it, wraps it as `NSData`, and sends it with command `0xB1`.
- `DrawingBoard` owns:
  - `sendAllFrameToDevice:galleryModel:` IMP `0x1007818bc`
  - `sendAnimateSpeed` IMP `0x1007819b4`
- The adjacent `DrawingBoard.sendDeviceText` helper at `0x100781ac0` takes the output of `getTextModel:` -> `setRow` -> `encodeText:width:` -> `packetBlueData:`, enumerates the resulting packet array, and calls `sendSppCmd:data:` with command byte `0x87` for each packet (`mov w2, #0x87` at `0x100781c98`, branch to `sendSppCmd:data:` at `0x101075560`).
- `DrawingBoard.sendDeviceTextFrame` is the neighboring method at `0x100781d30`, and it uses `set32TextFrame:startY:frameWidth:frameHeight:`. So the discovered `0x87` branch is now clearly part of the text/drawing pipeline, not the gallery upload pipeline.
- `sendAllFrameToDevice:galleryModel:` does not directly inline obvious frame bytes in its first block; it branches through helper send routines after checking device mode and gallery state, which is consistent with a higher-level playback activation path rather than a raw uploader only.
- `setCustomGalleryTimeConfig:galleryShowTimeFlag:SoundOnOff:customId:callback:ClockId:ParentClockId:ParentItemId:` IMP `0x1007f4ff8` builds a keyed config object containing at least:
  - `LcdIndex`
  - `LcdIndependence`
  - `SingleGalleyTime`
  - `GalleryShowTimeFlag`
  - `SoundOnOff`
  - `CustomId`
  - `ClockId`
  - `ParentClockId`
  - `ParentItemId`
  This strongly suggests gallery playback duration/loop behavior is controlled separately from raw GIF parsing/upload.
- Android cross-check now confirms the timing write path exactly: `WifiChannelCustomFragment` calls `WifiChannelModel.h0(...)` immediately on single-time changes, gallery-show toggles, and sound toggles, and `h0(...)` posts `Channel/SetCustomGalleryTime` with `SingleGalleyTime`, `GalleryShowTimeFlag`, `SoundOnOff`, `CustomId`, `ClockId`, `ParentClockId`, and `ParentItemId`.
- iOS correction: `WifiChannelCustomVC needUploadCustomTimeData:` at `0x1003293ec` and `BlueCustomVC needUploadCustomTimeData:` at `0x10038ceac` are controller/UI helpers, not the timing-write or BLE activation seam. The callback block at `0x10032947c` formats the selected value as `"%d s"` or `"%d min"` and updates the visible label. Future RE should not treat this selector as the upload/apply boundary.
- The iOS reusable-view delegates remain the correct UI seam:
  - `WifiChannelCustomVC WifiChannelReusableViewSetSingleGalleyTime:` `0x10032e9f4`
  - `WifiChannelCustomVC WifiChannelReusableViewSoundOnOff:` `0x10032eba8`
  - `WifiChannelCustomVC WifiChannelReusableViewSetGalleryShowTimeFlag:` `0x10032ed5c`
  - `BlueCustomVC WifiChannelReusableViewSetSingleGalleyTime:` `0x1003903d4`
  - `BlueCustomVC WifiChannelReusableViewSetGalleryShowTimeFlag:` `0x10039058c`
  These methods route through a shared Objective-C stubbed helper path, so they are still the right caller anchors for picker/toggle tracing, but not yet proof of the final transport write.

Practical implication:
- The vendor app clearly has a first-class `16x16` upload/gallery path.
- The best next reverse-engineering move is to inspect the callers above and recover:
  - how GIF frames are decoded and timed
  - what intermediate image/message object `messageWithGIFImageData:width:height:` builds
  - where that object transitions into BLE/SPP commands for the Ditoo Pro
  - how gallery playback timing is activated after upload (`sendAllFrameToDevice`, `sendAnimateSpeed`, `setCustomGalleryTimeConfig`, `sppSetSceneGIF:`)

## Animation Upload Protocol (0x8B)

### Packet sequence

The Ditoo Pro `16x16` animation upload uses the `0x8B` command family with a `0xBD [0x31]` preamble. The full sequence is:

1. `0xBD [0x31]` - marks the device as `NewAniSendMode2020` (required preamble)
2. `0x8B [0x00, total_size_le32]` - start upload, declares total animation byte count
3. `0x8B [0x01, total_size_le32, chunk_offset_le16, chunk_data...]` - data chunks (up to 256 bytes each)
4. `0x8B [0x02]` - end upload marker
5. `0x45 [0x05]` - switch to user-animation view
6. `0xBD [0x17, 0x00]` - select animation slot 0

### Device acknowledgment

On 2026-03-19, real device testing confirmed the Ditoo Pro responds to the `0x8B` upload with an old-mode ACK packet:

```text
01 07 00 04 8b 55 00 01 ec 00 02
```

Decoded:
- `01` / `02` = old-mode frame delimiters
- `07 00` = length (little-endian)
- `04` = command 0x04 = ACK response
- `8b` = ACKed command: 0x8B (animation upload)
- `55` = 0x55 = vendor "OK" marker
- `00 01` = status bytes (upload accepted)
- `ec 00` = checksum (verified correct)

This confirms the device accepts and acknowledges the `0x8B` upload traffic. Whether it then plays the animation autonomously depends on the `.divoom16` payload format matching what the firmware expects.

### .divoom16 frame format

Each frame in the upload blob starts with:

```text
0xAA  frame_length_le16  duration_ms_le16  reuse_palette_flag  palette_count  [palette_rgb...]  [packed_pixel_indices...]
```

Where:
- `frame_length` = total bytes from `0xAA` to end of pixel data (inclusive)
- `duration_ms` = display time per frame in milliseconds
- `reuse_palette_flag` = 0 for local palette, 1 to reuse the previous frame's palette
- `palette_count` = number of RGB entries (0 = 256), only present when `reuse_palette_flag == 0`
- `palette_rgb` = 3 bytes per color (R, G, B)
- pixel indices are bit-packed at `ceil(log2(max(2, palette_count)))` bits per pixel, LSB-first

### Animation playback status

- **0x44 frame streaming (proven)**: Mac sends each frame individually with timing controlled by `DispatchQueue`. Visually confirmed on the device display.
- **0x8B bulk upload (ACKed but unverified playback)**: Device acknowledges the upload with cmd 0x04 ACK. On-device autonomous playback has not been visually confirmed yet. The display may require an additional scene-switch or playback command not yet identified.

## Cloud / Store Endpoints Confirmed From IPA

The iOS app exposes these cloud and channel/store paths directly:

- `Channel/StoreClockGetClassify`
- `Channel/StoreClockGetList`
- `Channel/StoreTop20`
- `Channel/StoreNew20`
- `Channel/ItemSearch`
- `Channel/LikeClock`
- `Playlist/GetMyList`
- `Playlist/GetSomeOneList`
- `Discover/GetAlbumListV3`
- `Discover/GetAlbumImageListV3`

### Confirmed request / response keys

`Channel/StoreClockGetClassify`
- request shape: no store-specific selector fields are present in the Android cross-check; `MyClockModel` posts it with plain `BaseLoadMoreRequest`
- response list: `ClassifyList`
- per-item key: `ClassifyId`
- per-item key: `ClassifyName`

`Channel/StoreClockGetList`
- request keys confirmed in disassembly:
  - `CountryISOCode`
  - `Language`
  - `Flag`
  - `ClassifyId`
  - `StartNum`
  - `EndNum`
- response list: `ClockList`
- verified routing:
  - iOS `StoreClockVC storeClockHeaderView:didSelectItemAtIndex:` `0x1001aa508` maps header index `0 -> Channel/StoreTop20 / "Top20"` and `1 -> Channel/StoreNew20 / "Newest 20"`
  - iOS `StoreClockVC storeClockTitleView:didSelectItemAtSection:` `0x1001aa81c` uses section `0` as the special header lane and `n >= 1` as `classifyArray[n - 1]`
  - Android `MyClockStoreGroupAdapter` passes raw launch-context `Flag` plus the clicked `ClassifyId` into `StoreClockGetList`; it does not derive top/new/category from `Flag`
- verified item fields relevant to store state:
  - `ClockId`
  - `ClockName`
  - `ClockType`
  - `ImagePixelId`
  - `AddFlag`

`Channel/ItemSearch`
- request keys confirmed in disassembly / strings:
  - `Language`
  - `ClockId`
  - `ItemId`
  - `Key`
  - `StartNum`
  - `EndNum`
  - `ItemFlag`
- response list: `SearchList`

`Channel/LikeClock`
- request keys:
  - `ClockId`
  - `LikeFlag`
- verified caller behavior:
  - Android `MyClockAddFragment` flips its local liked boolean and passes that boolean directly into `MyClockModel.n(clockId, likeFlag)`, so this surface uses `1 = like`, `0 = unlike`
- relevant item/config fields on the channel/store surface:
  - `LikeCnt`
  - `IsMyLike`
  - `AddFlag`

`Playlist/GetMyList`
- request keys:
  - `StartNum`
  - `EndNum`
  - optional `GalleryId`
- response list: `PlayList`

`Playlist/GetSomeOneList`
- request keys:
  - `StartNum`
  - `EndNum`
  - `TargetUserId`
- response list: `PlayList`

### Store / channel parity corrections

- `Flag` is not the store section selector. The top/new split is endpoint-based, not `Flag`-based.
- `Channel/StoreClockGetClassify` is the shared category metadata feed and does not need `Flag`.
- The exact store matrix is now:
  - header tab `0` -> `Channel/StoreTop20`
  - header tab `1` -> `Channel/StoreNew20`
  - category rows -> `Channel/StoreClockGetList` with raw `Flag` plus clicked `ClassifyId`
- `ClassifyId == 100` is still special-cased in Android UI code, but its server meaning is not yet proven.
- `AddFlag` is separate from like state. Android store cards use `AddFlag == 1` to change the add/collection icon, while `LikeCnt` and `IsMyLike` live on the detail/config side.

## Open Questions

These pieces still need more work:
- what helper `0x101018b20` exactly represents semantically
- full semantic naming of the `DivoomTimeBoxScene_t` byte offsets used by `sppSetScene:`
- exact write-routing differences between the `1E4D` and `8841` characteristics for this specific hardware
- whether the Ditoo Pro front display on this unit wants:
  - `0x45` scene writes
  - `sppSetSceneGIF:`
  - or a different scene-selection command layered on top
- the full generic `ItemFlag` table for `Channel/ItemSearch` beyond the verified author-search token `SearchUser`

## Useful Addresses

- `BLECommLayer OldDevicePackage:Command:`: `0x100370220`
- `BLECommLayer NewDevicePackage:PacketID:TransmitMode:`: `0x100370414`
- `BLECommLayer ProtocolPackageWithCommand:Data:PacketID:isNewMode:TransmitMode:`: `0x100370570`
- `BLECommLayer SendDataToQueueWithData:PacketID:isNewMode:TransmitMode:Command:isResponse:onePacketSize:`: `0x1003706b0`
- `BLECommLayer SendDataToDeviceWithCommand:Data:Peripheral:TransmitMode:isResponse:`: `0x1003708a0`
- `BLEPeripheral sendSppCmd:data:`: `0x10088c568`
- `BLEPeripheral sendSppCmd:data:ack:`: `0x10088c708`
- `BLEPeripheral sppSetSystemBright:`: `0x10088dce8`
- `BLEPeripheral sppSetScene:`: `0x10088e198`

## Reproduction Commands

Examples used during this reverse pass:

```bash
r2 -q -e scr.color=0 -e bin.relocs.apply=true \
  -c 's 0x100370220;pd 120;s 0x100370414;pd 120;s 0x100370570;pd 120;s 0x10088e198;pd 220;q' \
  reverse/ios_ipa/Payload/Aurabox.app/Aurabox

r2 -q -e scr.color=0 -e bin.relocs.apply=true \
  -c 's 0x1003708a0;pd 220;q' \
  reverse/ios_ipa/Payload/Aurabox.app/Aurabox
```
