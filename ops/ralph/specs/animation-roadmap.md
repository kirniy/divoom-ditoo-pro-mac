# Native Animation Roadmap

The device is a Divoom Ditoo Pro with a `16x16` RGB pixel display.

## Proven baseline

- Native macOS BLE writes already work through:
  - service `49535343-FE7D-4AE5-8FA9-9FAFD205E455`
  - write characteristic `49535343-8841-43F4-A8D4-ECBE34729BB3`
  - notify/read characteristic `49535343-1E4D-4BD9-BA61-23C647249616`
- Solid color scenes work.
- Exact-pixel static `16x16` image sends work.

## Unfinished problem

Static frame delivery is solved, but multi-frame animation is not yet solved honestly.

Do not reuse old dead paths:
- macOS RFCOMM / audio fallback
- iPhone Shortcuts as product UI
- guessed packet families that are not grounded in the IPA RE notes

## Required reverse-engineering lane

Use the IPA evidence already documented in `reverse/ios_ipa/REVERSE.md`, especially:

- `uploadGalleryFor16`
- `messageWithGIFImageData`
- `praseGIFDataToImageArray`
- `praseGIFDelay`
- `praseGIFDelayTime`

The goal is to map:
1. how GIF frames are decoded
2. how frame delays are normalized
3. how per-frame payloads are packaged
4. which command sequence commits or starts playback on the device

## Acceptance bar

Animation work is only done when:

- a native macOS command can send a real multi-frame animation to the Ditoo Pro `16x16` display
- the implementation is described in `README.md`
- at least one repeatable smoke-test path exists in Python or CLI form
