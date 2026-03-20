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
- The same `setCustomGalleryTimeConfig...` request builder now has exact CFString-backed proof for the key names and endpoint:
  - `LcdIndex` CFString `0x10138bb18`
  - `LcdIndependence` CFString `0x10138d5d8`
  - `SingleGalleyTime` CFString `0x1013b9c78`
  - `GalleryShowTimeFlag` CFString `0x1013b9c98`
  - `SoundOnOff` CFString `0x1013b9cf8`
  - `CustomId` CFString `0x1013b9878`
  - `ClockId` CFString `0x101378678`
  - `ParentClockId` CFString `0x101378778`
  - `ParentItemId` CFString `0x101378798`
  - endpoint CFString `0x10139e9b8` -> `Channel/SetCustomGalleryTime`
- `WifiChannelModel` also exposes a broader custom-gallery control surface than the current Python wrapper covers:
  - `getCustomList:CallBack:ClockId:ParentClockId:ParentItemId:` `0x1007eebc0`
  - `getCustomConfig:callback:ClockId:ParentClockId:ParentItemId:` `0x1007f4240`
  - `setCustom:CustomId:FileId:gallery:CallBack:ClockId:ParentClockId:ParentItemId:` `0x1007eef8c`
  - `setCustom:CustomId:FileId:SoundFileId:gallery:CallBack:ClockId:ParentClockId:ParentItemId:` `0x1007eefc4`
  - `deleteOneCustom:CustomId:CallBack:ClockId:ParentClockId:ParentItemId:` `0x1007ef8ac`
  - `deleteAllCustom:CallBack:ClockId:ParentClockId:ParentItemId:` `0x1007efc20`
  - `getCustomAllIndexTime:ClockId:` `0x1007f5c64`
  - `setCustomAllIndexTime:CallBack:ClockId:` `0x1007f5f38`
  - `getSubscribeTime:ClockId:` `0x1007f6650`
  - `setSubscribeTime:CallBack:ClockId:` `0x1007f6344`
  - `getAlbumTime:ClockId:` `0x1007f70f0`
  - `setAlbumTime:CallBack:ClockId:` `0x1007f6e74`
- The exact timing/config channel strings now confirmed in the IPA are:
  - `Channel/GetCustomGalleryTime`
  - `Channel/SetCustomGalleryTime`
  - `Channel/GetSubscribeTime`
  - `Channel/SetSubscribeTime`
  - `Channel/GetAlbumTime`
  - `Channel/SetAlbumTime`
  So the vendor app has distinct read/write paths for custom-gallery timing plus separate subscribe/album timing lanes.
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
  - exact CFString-backed proof from `storeClockHeaderView:didSelectItemAtIndex:`:
    - branch `index == 0` loads `0x10138ac18 -> "Top20"` and `0x10138ac38 -> "Channel/StoreTop20"`
    - branch `index == 1` loads `0x10138ac58 -> "Newest 20"` and `0x10138ac78 -> "Channel/StoreNew20"`
  - iOS `StoreClockVC storeClockTitleView:didSelectItemAtSection:` `0x1001aa81c` uses section `0` as the special header lane and `n >= 1` as `classifyArray[n - 1]`
  - Android `MyClockStoreGroupAdapter` passes raw launch-context `Flag` plus the clicked `ClassifyId` into `StoreClockGetList`; it does not derive top/new/category from `Flag`
- verified item fields relevant to store state:
  - `ClockId`
  - `ClockName`
  - `ClockType`
  - `ImagePixelId`
  - `AddFlag`

Exact store sort/filter strings in the IPA:
- `Channel/StoreTop20` `17824863`
- `Channel/StoreNew20` `17824892`
- `Channel/StoreClockGetClassify` `17834523`
- `Channel/StoreClockGetList` `17834577`
- `gallery_filter_selected` `17986688`
- `gallery_filter_popular` `17986720`
- `gallery_filter_latest_upload` `17986752`
- `gallery_filter_immersive` `17986784`
- `gallery_filter_default` `17986816`
- `gallery_filter_classical` `17986848`

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
- exact iOS request builder evidence:
  - selector `WifiChannelModel itemSearch:withItenID:withSearchString:start:end:withItemFlag:callback:` `0x1007f3208`
  - endpoint CFString `0x1013b9ad8` -> `Channel/ItemSearch`
  - request-key CFStrings:
    - `Language` `0x10137a518`
    - `ClockId` `0x101378678`
    - `ItemId` `0x101392c18`
    - `Key` `0x1013b9af8` -> cstring `0x1011176ac`
    - `StartNum` `0x10137a4d8`
    - `EndNum` `0x10137a4f8`
    - `ItemFlag` `0x1013b9b18`
  - response-list CFString `0x1013b9b38` -> `SearchList`
  - nil `itemFlag` is normalized to the empty CFString `0x101378238`, so the explicit-flag path is optional rather than mandatory
  - the only verified non-empty flag token still recovered from the IPA is `SearchUser`, via CFString `0x10137a538` and the dedicated controller class `WifiChannelSubsctibeSearchUserVC`
  - there is also a sibling raw IPA string `0x1011177d6` -> `Application/ItemSearch`, but this pass did not pin an iOS request builder that targets it directly

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
- iOS UI code also separates collection/add state from popularity state:
  - `WifiChannelAPPSettingTopCell showAddedClockState` `0x100217a70`
  - `WifiChannelAPPSettingTopCell updateLikeCnt:isMyLike:` `0x1002182b8`
  That is additional evidence that `AddFlag` is not just a synonym for like state.

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

### Playlist / autonomous playback surface

`PlaylistModel` exposes a larger playlist-management surface than the current wrapper:
- `createListWithName:Callback:` `0x1007803f0`
- `playlistWithHide:PlayId:Callback:` `0x100780654`
- `renameWithName:PlayId:Callback:` `0x100780818`
- `setDescribe:PlayId:Callback:` `0x1007809dc`
- `setCover:PlayId:Callback:` `0x100780ba8`
- `DeleteListWithId:Callback:` `0x100780d74`
- `addListWithGalleryId:PlayId:Callback:` `0x100780f18`
- `removeWithGalleryId:PlayId:Callback:` `0x100781130`
- `playlistSendWithPlayId:Callback:` `0x100781348`

Matched playlist endpoint strings in the IPA:
- `Playlist/NewList`
- `Playlist/Hide`
- `Playlist/Rename`
- `Playlist/SetDescribe`
- `Playlist/SetCover`
- `Playlist/DeleteList`
- `Playlist/AddImageToList`
- `Playlist/RemoveImage`
- `Playlist/SendDevice`

Exact `playlistSendWithPlayId:Callback:` proof:
- request key CFString `0x101379078` -> `PlayId`
- endpoint CFString `0x10139e818` -> `Playlist/SendDevice`

This is currently the strongest cloud-side candidate for “send a prepared gallery/playlist to the device” behavior beyond raw BLE frame upload.

Exact playlist timing/control selectors in the IPA:
- `PlaylistModel playFromPlaylist:` `0x1010668a0`
- `PlaylistModel playFromPlaylist:itemIndex:` `0x1010668c0`
- `PlaylistModel preloadNextPlaylistItemAutomatically` `0x101068000`
- `WifiChannelModel setSubscribeTime:CallBack:ClockId:` `0x1007f6344`
- `WifiChannelModel setAlbumTime:CallBack:ClockId:` `0x1007f6e74`
- `WifiChannelModel setCustomAllIndexTime:CallBack:ClockId:` `0x1007f5f38`
- `WifiChannelModel setCustomGalleryTimeConfig:galleryShowTimeFlag:SoundOnOff:customId:callback:ClockId:ParentClockId:ParentItemId:` `0x1007f4ff8`
- `WifiChannelModel setYuntuGalleryTimeConfig:galleryShowTimeFlag:callback:ClockId:ParentClockId:ParentItemId:` `0x1010a1d40`
- `WifiChannelModel setCustom:CustomId:FileId:SoundFileId:gallery:CallBack:ClockId:ParentClockId:ParentItemId:` `0x10107f0c0`
- `WifiChannelModel setCustom:CustomId:FileId:gallery:CallBack:ClockId:ParentClockId:ParentItemId:` `0x10107f180`

Exact timing-related CFString payload keys already pinned in the binary:
- `LcdIndex`
- `LcdIndependence`
- `SingleGalleyTime`
- `GalleryShowTimeFlag`
- `StartUpClockId`
- `SoundOnOff`
- `ClockId`
- `ParentClockId`
- `ParentItemId`

Additional per-screen timing state carriers now pinned from Objective-C metadata:
- `LcdIndependenceList` property token `0x1011909de`
- `LcdIndependenceList` getter/method token `0x10119f9d0`
- `setLcdIndependenceIndex:` `0x101254ff0`
- `setLcdIndependenceList:` `0x101255009`
- `getFiveLcdIndependenceTime:` `0x101216498`
- `setFiveLcdIndependenceTime:CallBack:` `0x10124f173`
- `add5LcdIndependenceListHistory:callback:` `0x1011f6c1f`
- `drawSendByLcdIndex:` `0x10120f9f8`

This is stronger evidence that the vendor app tracks not just one global gallery duration, but a per-LCD / per-slot timing state surface layered on top of the shared channel timing endpoints.

### Store / channel parity corrections

- `Flag` is not the store section selector. The top/new split is endpoint-based, not `Flag`-based.
- `Channel/StoreClockGetClassify` is the shared category metadata feed and does not need `Flag`.
- The exact store matrix is now:
  - header tab `0` -> `Channel/StoreTop20`
  - header tab `1` -> `Channel/StoreNew20`
  - category rows -> `Channel/StoreClockGetList` with raw `Flag` plus clicked `ClassifyId`
- `ClassifyId == 100` is still special-cased in Android UI code, but its server meaning is not yet proven.
- `AddFlag` is separate from like state. Android store cards use `AddFlag == 1` to change the add/collection icon, while `LikeCnt` and `IsMyLike` live on the detail/config side.

## Optional Device Keys / Buttons Parity

This surface is also BLE/SPP-native. The IPA and Android app both expose a dedicated optional-device
key configuration lane for hardware buttons.

### iOS classes and selectors

Confirmed Objective-C classes:
- `PartKeySettingVC`
- `PartKeyFuncPickerVC`
- `PartKeyModel`
- `KeyFuncCellModel`

Confirmed `PartKeySettingVC` selectors:
- `viewWillAppear:`: `0x1004a3004`
- `keyFuncDidTouchForKeyIdx:`: `0x1004a3720`
- `resetAction`: `0x1004a3854`
- `sppCmdNote:`: `0x1004a3990`

Confirmed `PartKeyModel` selectors:
- `handlerPartKeyInfoCMD:`: `0x10033866c`
- `funcArrWithKeyIdx:funcIdx:isON:`: `0x1003386dc`
- `localKeyByIdx:`: `0x1003388a0`
- `getPartKeyDefImgByKeyIdx:`: `0x100338960`
- `resetPartInfo`: `0x100338a24`

Confirmed `BLEPeripheral` selectors:
- `sppPartSetKeyPic:btnIdx:`: `0x1008946cc`
- `sppPartSetKeyFuncByMode:partInfo:`: `0x100894930`
- `sppPartGetKeyFuncInfo`: `0x100894a18`
- `sppPartSetKeyFuncInfoByPartInfo:`: `0x100894a88`
- `sppPartResetkeyFuncInfo`: `0x100894b0c`

Matched iOS UI strings for this surface:
- `Single click`
- `Long click`
- `Left button`
- `Right button`
- `Power button`
- `CH button`
- `sound_control_tips_title`
- `sound_control_tips_k_button`

Exact key/UI strings and object names in the IPA:
- `keyFuncDidTouchForKeyIdx:` `19032759`
- `keyOnOffSwitch` `19032805`
- `keyOnOffSwitchClick:` `19032820`
- `kNotiPartKeyInfoReceive` `0x10110465b`
- `keyWindow` `19033104`
- `lcj_power_button` `19037967`
- `lcj_power_button_methoe` `19037984`
- `power_button` `19091814`
- `power_button_bottom` `19091827`
- `power_button_method` `19091847`
- `FiveLCDControll_Visualizer` `17993344`
- `FiveLCDControll_Custom` `17993376`
- `FiveLCDControll_CloudChannel` `17993408`
- `sound_control_tips_long_press`
- `sound_control_tips_volume`
- `sound_control_tips_tf`
- `sound_control_tips_record`
- `sound_control_tips_record_tf`

### Wire protocol

The optional-button lane rides the extended SPP command family under top-level command `0xbd`.

Verified command bytes:
- `0x11` = `SPP_SECOND_SET_KEY_PIC`
- `0x12` = `SPP_SECOND_SET_KEY_FUNC`

Verified `0x12` submode mapping:
- submode `0` = get current key config
- submode `1` = set current key config
- submode `2` = reset current key config

Grounded packet shapes:
- `sppPartGetKeyFuncInfo` sends `[0x12, 0x00]`
- `sppPartSetKeyFuncInfoByPartInfo:` sends `[0x12, 0x01, <12-byte key_func blob>]`
- `sppPartResetkeyFuncInfo` sends `[0x12, 0x02]`
- `sppPartSetKeyPic:btnIdx:` sends `[0x11, <btnIdx>, <pixel payload...>]`

The exact subcommand names are corroborated by Android:
- `SppProc$EXT_CMD_TYPE SPP_SECOND_SET_KEY_PIC = 0x11`
- `SppProc$EXT_CMD_TYPE SPP_SECOND_SET_KEY_FUNC = 0x12`

### Key config struct

Exact iOS ivar metadata on `PartKeyModel`:
- `partInfo : {SppPartsInfo_t=[12C]}`

The internal struct name is explicit in the metadata:
- `SppPartsInfo_t="key_func"[12C]`

`handlerPartKeyInfoCMD:` explicitly checks the first incoming byte for `0x12` before consuming the
12-byte config payload.

Verified 12-byte layout from Android `PartsModel.l([B, List)`:
- bytes `0..3` = slot 0: `singleIndex`, `singleSwitch`, `longIndex`, `longSwitch`
- bytes `4..7` = slot 1: `singleIndex`, `singleSwitch`, `longIndex`, `longSwitch`
- bytes `8..9` = slot 2: `singleIndex`, `singleSwitch`
- bytes `10..11` = slot 3: `singleIndex`, `singleSwitch`

So the first two hardware-button slots support single-click plus long-click config, while the last
two slots only carry single-click config in the proven model.

### Android cross-checks

Verified Android send helpers:
- `CmdManager.J()` builds `[0x12, 0x00]`
- `CmdManager.p2([B)` logs `setKeyConfig` and builds `[0x12, 0x01, <12-byte blob>]`
- `CmdManager.j1()` builds `[0x12, 0x02]`

Verified Android receive helper:
- `bluetooth/s.smali` branches on `SPP_SECOND_SET_KEY_FUNC`, copies `12` bytes, and forwards them
  into `PartsModel.h([B)`

Verified Android local model fields on `PartsSettingsBean`:
- `singleIndex`
- `singlePicData`
- `singleSwitch`
- `longIndex`
- `longPicData`
- `longSwitch`

Verified local Android icon storage:
- `reverse/android/apktool-out/assets/key_config_pic.db`
- current rows include `left`, `right`, and `777777`

### Current parity conclusion

Verified:
- macOS-native control can read the current optional-button config over BLE/SPP
- macOS-native control can write the 12-byte key config blob over BLE/SPP
- macOS-native control can reset the key config over BLE/SPP
- macOS-native control can upload per-button icon pixel data over BLE/SPP

Not yet verified:
- a separate live device-to-app hardware button press event stream for this same `PartKey` lane

In the artifacts checked so far, the only proven receive path for this feature is the config-readback
packet on `SPP_SECOND_SET_KEY_FUNC` / `0x12`, not a runtime key-press event callback.

## FiveLCD RGB / Backlight Parity

This surface is not Wi-Fi-only. The iOS IPA contains both:
- a `Channel/GetRGBInfo` / `Channel/SetRGBInfo` model path
- direct BLE/SPP setters on `BLEPeripheral`

### Wi-Fi / channel model

Confirmed selectors on `WifiChannelModel`:
- `getFiveLCDRGBInfo:`: `0x1007f7c60`
- `setFiveLCDRGBInfo:callBack:`: `0x1007f7dac`

Confirmed channel strings in the IPA:
- `Channel/GetRGBInfo`
- `Channel/SetRGBInfo`
- `WifiChanneGetRGBInfoNotification`

Additional ambient / screen-state channel strings now pinned in the IPA:
- `Channel/SetBrightness` `0x101107bbb`
- `Channel/GetOnOffScreen` `0x101107cf6`
- `Channel/GetAmbientLight` `0x101107d6c`
- `Channel/SetAmbientLight` `0x101107d84`
- `Channel/OnOffScreen` `0x101107e8c`
- `Channel/SetOnOff` `0x101107eb5`
- `Channel/GetOnOff` `0x1011187a9`
- `WifiChannelGetAmbientLightNotification` `0x10110f6f3`

Confirmed Objective-C model classes:
- `WifiChannelFiveLCDRGBModel`
- `WifiChannelFiveLCDRGBColorModel`

Exact `WifiChannelFiveLCDRGBModel` properties from Objective-C metadata:
- `OnOff: NSNumber`
- `Brightness: NSNumber`
- `SelectLightIndex: NSNumber`
- `Color: NSString`
- `ColorCycle: NSNumber`
- `KeyOnOff: NSNumber`
- `LightList: NSArray`

Exact `WifiChannelFiveLCDRGBModel` ivar offsets:
- `_OnOff` -> `0x08`
- `_Brightness` -> `0x10`
- `_SelectLightIndex` -> `0x18`
- `_Color` -> `0x20`
- `_ColorCycle` -> `0x28`
- `_KeyOnOff` -> `0x30`
- `_LightList` -> `0x38`

Exact `WifiChannelFiveLCDRGBColorModel` property from Objective-C metadata:
- `SelectEffect: NSNumber`

### iOS controller / view surface

Confirmed controller class:
- `FiveLCDControllRGBVC`

Confirmed `FiveLCDControllRGBVC` selectors:
- `getData`: `0x1008a41ec`
- `setUIValue:`: `0x1008a47d8`
- `updateScreenLight:`: `0x1008a4a58`
- `colorCycle:color:`: `0x1008a8508`
- `setData`: `0x1008a8934`
- `WifiLightSettingTttleMoreTextCell_cilckChooseSwitch:withWhich:`: `0x1008a89a0`
- `FiveLCDControllRGBLightView_valueChange:`: `0x1008a8a10`
- `lightInfo`: `0x1008a8ac8`
- `keyOnOffSwitchClick:`: `0x1008a8b18`

Confirmed `FiveLCDControllRGBVC` ivars:
- `_screenSlider` at offset `0x18`
- `_lightSlider` at offset `0x20`
- `_lightView` at offset `0x28`
- `_rgbModel` at offset `0x30`
- `_lightInfo` at offset `0x38`
- `_keyOnOffSwitch` at offset `0x60`

Confirmed view class:
- `FiveLCDControllRGBLightView`

Confirmed `FiveLCDControllRGBLightView` selectors:
- `setRgbModel:`
- `controllAll`: `0x100179394`
- `controllSide`: `0x10017955c`
- `controllBack`: `0x100179724`

Exact `SelectLightIndex` mapping from the view disassembly:
- `0` = all light
- `1` = side light
- `2` = back light

The mapping above is grounded by the per-button methods:
- `controllAll` writes literal `0`
- `controllSide` writes literal `1`
- `controllBack` writes literal `2`

Matched UI strings:
- `FiveLCDControllRGBLightView_deviceAllLight`
- `FiveLCDControllRGBLightView_deviceSideLight`
- `FiveLCDControllRGBLightView_deviceBackLight`

Verified ambient/backlight mode labels in the binary:
- `FiveLCDControll_Visualizer` `17993344`
- `FiveLCDControll_Custom` `17993376`
- `FiveLCDControll_CloudChannel` `17993408`

### BLE / SPP control

Confirmed `BLEPeripheral` selectors for the same hardware surface:
- `sppSetLampValue:`: `0x10088cdc0`
- `sppSetColorMode:`: `0x10088cdcc`
- `sppSetSystemBright:`: `0x10088dce8`
- `sppSetSleepAlarmRed:green:Blue:`: `0x10088da38`
- `sppSetSleepAlarmLight:`: `0x10088da9c`
- `sppGetSleepCtrlMode`: `0x1008902d4`
- `sppSetSleepCtrlMode:`: `0x100890334`
- `sppSetFullColorR:G:B:`: `0x10088d5e0`

Additional ambient-light selectors pinned in the IPA:
- `getAmbientLight:` `0x1010442e0`
- `setAmbientLightWithModel:Callback:` `0x1010775e0`
- `getOnOffScreen` `0x101217ed1`
- `handleOnOffScreenWithJson:` `0x10121ab13`
- `setOnOffScreen:CallBack:` `0x101259c16`

Confirmed SPP command bytes:
- `sppSetLampValue:` -> command `0x32`
- `sppSetColorMode:` -> command `0x38` with a 1-byte payload
- `sppSetSystemBright:` -> command `0x74` with a 1-byte payload
- `sppSetSleepAlarmLight:` -> command `0xae` with a 1-byte payload
- `sppGetSleepCtrlMode` -> command `0x79` with payload `ff`
- `sppSetSleepCtrlMode:` -> command `0x79` with a 1-byte payload
- `sppSetFullColorR:G:B:` -> command `0x6f` with a 3-byte RGB payload

The IPA therefore exposes two parity lanes for ambient / backlight / RGB behavior:
- persisted state via `Channel/GetRGBInfo` and `Channel/SetRGBInfo`
- immediate device-side control via SPP commands

## Focused Follow-up: Timing / Auto-Send / Ambient

### Autonomous playback state carriers

Exact Objective-C metadata now ties the 5-LCD auto-send state to two different owners:

- `DeviceFunction`
  - `isCloseAutoSendDevice`: `0x10077c620`
  - `setCloseAutoSendDevice:`: `0x10077c690`
  - `get5LcdScreenArray`: `0x10077c6d8`
  - `get5LcdScreenSendArray`: `0x10077c918`
  - `get5LcdControlMode`: `0x10077c9e4`
- `DivoomGalleryInfo`
  - `lcdSendDeviceFlag`: `0x1005516bc`
  - `setLcdSendDeviceFlag:`: `0x1005516c8`

Practical implication:
- the app appears to track one device-level 5-LCD auto-send gate in `DeviceFunction`
- and a separate per-gallery/per-item send flag in `DivoomGalleryInfo`

That is stronger evidence than the earlier raw strings `KeyCloseAutoSendDevice` / `lcdSendDeviceFlag` alone.

### Playlist / album / subscribe timing activation

`WifiChannelSubscribeModel` is now pinned as the shared selection model for the channel timing surface:
- class `WifiChannelSubscribeModel`
- `SubscribeType`: `0x1007ebfc0`
- `AuthorType`: `0x1007ebfd0`
- `AlbumName`: `0x1007ebfe0`
- `AlbumId`: `0x1007ebff0`
- `UserList`: `0x1007ec000`
- `PlayId`: `0x1007ec010`
- `PlayName`: `0x1007ec020`

`WifiChannelSubsctibeTopView` is the strongest UI entry-point currently pinned for selecting those modes:
- `setTimeEntrance`: `0x1009139c4`
- `albumClick`: `0x100913ec4`
- `playlistClick`: `0x100914184`
- `resetSubscribeType:`: `0x10091446c`

Exact timing setter details from disassembly:
- `WifiChannelModel setSubscribeTime:CallBack:ClockId:` `0x1007f6344`
  - writes `LcdIndex` via CFString `0x10138bb18`
  - writes `LcdIndependence` via CFString `0x10138d5d8`
  - conditionally writes `ClockId` via CFString `0x101378678`
  - exact endpoint cstring `0x101107f78` -> `Channel/SetSubscribeTime`
  - dispatches through endpoint pointer `0x10139e9d8`
- `WifiChannelModel setAlbumTime:CallBack:ClockId:` `0x1007f6e74`
  - conditionally writes `ClockId` via CFString `0x101378678`
  - exact endpoint cstring `0x101108055` -> `Channel/SetAlbumTime`
  - dispatches through endpoint pointer `0x10139eb78`
- `WifiChannelModel setCustomAllIndexTime:CallBack:ClockId:` `0x1007f5f38`
  - writes `LcdIndex` via CFString `0x10138bb18`
  - writes `LcdIndependence` via CFString `0x10138d5d8`
  - conditionally writes `ClockId` via CFString `0x101378678`
  - dispatches through endpoint pointer `0x10139ea18`

Boundary of certainty:
- the exact cstrings are now pinned for:
  - `Channel/SetSubscribeTime` `0x101107f78`
  - `Channel/GetSubscribeTime` `0x101117836`
  - `Channel/SetAlbumTime` `0x101108055`
  - `Channel/GetAlbumTime` `0x101117861`
- `setSubscribeTime` / `setAlbumTime` are exact by both string and dispatch evidence
- `setCustomAllIndexTime` still lacks a directly printed endpoint literal in this pass, but its payload shape remains exact by key-plus-dispatch evidence

`Playlist/SendDevice` remains the strongest exact playlist push endpoint, but this pass still did not recover a fully proven downstream BLE activation chain from that cloud call alone.

### Ambient / backlight follow-up

Additional exact string evidence exists for mode-family labels beyond the currently proven `0x6f` full-color path:
- `FiveLCDControll_Visualizer`
- `FiveLCDControll_Custom`
- `FiveLCDControll_CloudChannel`

This pass did not recover a stronger selector -> SPP command mapping for those mode families, so the only exact immediate device-side backlight commands remain:
- `0x32` via `sppSetLampValue:`
- `0x38` via `sppSetColorMode:`
- `0x74` via `sppSetSystemBright:`
- `0xae` via `sppSetSleepAlarmLight:`
- `0x79` via `sppGetSleepCtrlMode` / `sppSetSleepCtrlMode:`
- `0x6f` via `sppSetFullColorR:G:B:`

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
- exact semantic meaning of `OnOff` versus `KeyOnOff` from the `FiveLCD` RGB controller path
- exact value tables behind `sppSetColorMode:` and `sppSetSleepCtrlMode:` from iOS alone
- whether any screen-following / visualizer-style backlight mode exists beyond raw string evidence such as `FiveLCDControll_Visualizer`
- whether the device exposes a separate live key/button event notification path beyond the verified
  `0x12` config-readback packet

## Useful Addresses

- `BLECommLayer OldDevicePackage:Command:`: `0x100370220`
- `BLECommLayer NewDevicePackage:PacketID:TransmitMode:`: `0x100370414`
- `BLECommLayer ProtocolPackageWithCommand:Data:PacketID:isNewMode:TransmitMode:`: `0x100370570`
- `BLECommLayer SendDataToQueueWithData:PacketID:isNewMode:TransmitMode:Command:isResponse:onePacketSize:`: `0x1003706b0`
- `BLECommLayer SendDataToDeviceWithCommand:Data:Peripheral:TransmitMode:isResponse:`: `0x1003708a0`
- `BLEPeripheral sendSppCmd:data:`: `0x10088c568`
- `BLEPeripheral sendSppCmd:data:ack:`: `0x10088c708`
- `PartKeyModel handlerPartKeyInfoCMD:`: `0x10033866c`
- `PartKeyModel localKeyByIdx:`: `0x1003388a0`
- `PartKeyModel getPartKeyDefImgByKeyIdx:`: `0x100338960`
- `PartKeySettingVC viewWillAppear:`: `0x1004a3004`
- `PartKeySettingVC keyFuncDidTouchForKeyIdx:`: `0x1004a3720`
- `PartKeySettingVC resetAction`: `0x1004a3854`
- `PartKeySettingVC sppCmdNote:`: `0x1004a3990`
- `BLEPeripheral sppPartSetKeyPic:btnIdx:`: `0x1008946cc`
- `BLEPeripheral sppPartSetKeyFuncByMode:partInfo:`: `0x100894930`
- `BLEPeripheral sppPartGetKeyFuncInfo`: `0x100894a18`
- `BLEPeripheral sppPartSetKeyFuncInfoByPartInfo:`: `0x100894a88`
- `BLEPeripheral sppPartResetkeyFuncInfo`: `0x100894b0c`
- `WifiChannelModel getFiveLCDRGBInfo:`: `0x1007f7c60`
- `WifiChannelModel setFiveLCDRGBInfo:callBack:`: `0x1007f7dac`
- `BLEPeripheral sppSetLampValue:`: `0x10088cdc0`
- `BLEPeripheral sppSetColorMode:`: `0x10088cdcc`
- `BLEPeripheral sppSetSystemBright:`: `0x10088dce8`
- `BLEPeripheral sppSetSleepAlarmLight:`: `0x10088da9c`
- `BLEPeripheral sppGetSleepCtrlMode`: `0x1008902d4`
- `BLEPeripheral sppSetSleepCtrlMode:`: `0x100890334`
- `BLEPeripheral sppSetScene:`: `0x10088e198`
- `FiveLCDControllRGBVC getData`: `0x1008a41ec`
- `FiveLCDControllRGBVC setData`: `0x1008a8934`
- `FiveLCDControllRGBVC keyOnOffSwitchClick:`: `0x1008a8b18`
- `FiveLCDControllRGBLightView controllAll`: `0x100179394`
- `FiveLCDControllRGBLightView controllSide`: `0x10017955c`
- `FiveLCDControllRGBLightView controllBack`: `0x100179724`

## Reproduction Commands

Examples used during this reverse pass:

```bash
r2 -q -e scr.color=0 -e bin.relocs.apply=true \
  -c 's 0x100370220;pd 120;s 0x100370414;pd 120;s 0x100370570;pd 120;s 0x10088e198;pd 220;q' \
  reverse/ios_ipa/Payload/Aurabox.app/Aurabox

r2 -q -e scr.color=0 -e bin.relocs.apply=true \
  -c 's 0x1003708a0;pd 220;q' \
  reverse/ios_ipa/Payload/Aurabox.app/Aurabox

r2 -q -e scr.color=0 -e bin.relocs.apply=true \
  -c 's 0x10033866c;pd 60;s 0x1008946cc;pd 90;s 0x100894930;pd 70;s 0x100894a18;pd 40;s 0x100894a88;pd 50;s 0x100894b0c;pd 40;q' \
  reverse/ios_ipa/Payload/Aurabox.app/Aurabox

r2 -q -e scr.color=0 -e bin.relocs.apply=true \
  -c 's 0x100179394;pd 40;s 0x10017955c;pd 40;s 0x100179724;pd 40;s 0x10088cdc0;pd 80;s 0x10088cdcc;pd 80;s 0x1008902d4;pd 80;s 0x100890334;pd 80;q' \
  reverse/ios_ipa/Payload/Aurabox.app/Aurabox
```
