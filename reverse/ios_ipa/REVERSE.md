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

## Open Questions

These pieces still need more work:
- what helper `0x101018b20` exactly represents semantically
- full semantic naming of the `DivoomTimeBoxScene_t` byte offsets used by `sppSetScene:`
- exact write-routing differences between the `1E4D` and `8841` characteristics for this specific hardware
- whether the Ditoo Pro front display on this unit wants:
  - `0x45` scene writes
  - `sppSetSceneGIF:`
  - or a different scene-selection command layered on top

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
