# Attributions

## Divoom Cloud Client

- Project: `redphx/apixoo`
- Upstream: <https://github.com/redphx/apixoo>
- License: MIT
- Vendored source: [vendor/apixoo](/Users/kirniy/dev/divoom/vendor/apixoo)

This repo vendors `apixoo` for the Divoom cloud sync path:

- Divoom account login
- direct gallery info by id
- Divoom cloud category and album listing
- Divoom cloud search
- Divoom cloud like / unlike
- Divoom cloud playlist metadata
- Divoom store/channel classification metadata
- Divoom PixelBean decoding
- GIF export for the native animation library

The vendored code remains attributed to its upstream author and license.

Current repo truth:

- `vendor/apixoo` is a vendored dependency, not original work from this repo
- this repo carries local compatibility fixes for the current native cloud sync and library-ingestion path
- upstream credit and the MIT license must stay intact when this surface changes

Relevant files:

- upstream license copy: [vendor/apixoo/LICENSE.md](/Users/kirniy/dev/divoom/vendor/apixoo/LICENSE.md)
- vendored source: [vendor/apixoo](/Users/kirniy/dev/divoom/vendor/apixoo)

## Product Sounds

- Source: OpenPeon
- Pack: `cute-minimal`
- Site: <https://openpeon.com/packs/cute-minimal>

This app uses sounds from the OpenPeon `cute-minimal` pack for beam and feedback cues.

## Provider Art

The app bundle also carries provider icon resources for Codex and Claude display surfaces.

- bundled app resources: `macos/DivoomMenuBar/Resources/*.svg`

These should remain attributed to their respective upstream product brands.
