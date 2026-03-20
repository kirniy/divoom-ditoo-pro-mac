# Troubleshooting

## App does not show up in the menu bar

Launch the app bundle, not the raw executable:

```bash
open -na /Applications/DivoomMenuBar.app
```

If you built locally instead of installing:

```bash
open -na /Users/kirniy/dev/divoom/build/DivoomMenuBar.app
```

## Bluetooth permission is missing or broken

Symptoms:

- the Ditoo never appears
- commands fail immediately
- the app says permission is needed

Actions:

1. Relaunch the app bundle.
2. Re-grant Bluetooth when macOS asks.
3. If the speaker side shows up but beams still fail, run `Device -> Connection -> Reconnect Light Link`.
4. Run `Device -> Connection -> Run Bluetooth Diagnostics`.
5. Test a simple command:

```bash
./bin/divoom-display native-headless scene-color --color '#247cff'
```

Important: the running app owns Bluetooth. The CLI is only an IPC client.

Transport truth: the display path is the hidden `DitooPro-Light` endpoint. `DitooPro-Audio` is not enough for colors, animations, or other beam surfaces.

What actually broke earlier:

- the app still saw the speaker-side profile, but the real display transport was missing or stale
- once that happens, colors and animations stop even though the device looks "connected"
- the fix is not generic Bluetooth pairing voodoo; it is recovering `DitooPro-Light` and its writable `8841` characteristic again

How the app now recovers:

- it caches the last working hidden-light peripheral UUID
- `Reconnect Light Link` clears stale light-link state and triggers a fresh BLE scan
- readiness is only real when `DitooPro-Light` is back and the writable light characteristic is ready

The macOS-specific failure mode that bit us:

- ad-hoc rebuilt app bundles can fall back to `Bluetooth auth=denied` or `Bluetooth auth=notDetermined`
- when that happens, the app can still look alive, but every beam path fails before transport discovery
- this is a permissions/TCC problem first, not a Divoom packet problem

Fast recovery:

```bash
tccutil reset BluetoothAlways dev.kirniy.divoom.menubar
open -na /Users/kirniy/dev/divoom/build/DivoomMenuBar.app
```

Then:

1. accept the Bluetooth prompt from the relaunched bundle
2. if the prompt does not appear, use `Device -> Connection -> Request Bluetooth Access`
3. once permission is back, use `Reconnect Light Link` only if the app still sees `DitooPro-Audio` but not `DitooPro-Light`

Useful recovery commands from a repo checkout:

```bash
./bin/divoom-display native-headless diagnostics
./bin/divoom-display native-headless probe
```

## Cloud login looks present, but cloud actions still fail

This is a current beta pain point.

The best path is:

1. open `Settings -> Cloud`
2. save Divoom credentials into the app Keychain, or import the synced `divoom-gz.com` Passwords entry once
3. run `Sync Cloud`

Current runtime truth:

- passive UI refresh should not probe Passwords anymore
- explicit cloud actions use the app-local Keychain copy
- direct cloud sync is working with valid credentials
- `Channel/StoreClockGetClassify` and `Channel/ItemSearch` are still blocked by payload-parity work
- importing from Passwords into the app-local Keychain is still available, but it is now an explicit copy step rather than a passive fallback

If cloud actions still fail:

- open Settings and confirm the app has locally saved credentials
- if needed, clear saved credentials and save them again
- if the native library header still shows `Connect Cloud…`, the app does not see a local saved copy yet
- if the local copy was originally created outside the app, re-save it from the app to rewrite the Keychain item cleanly
- then run a new sync

## Repeated Keychain or Passwords prompts

The app should no longer probe synced Passwords items during ordinary UI refresh, and silent cloud work should not trigger interactive unlock prompts.

The concrete bug we hit before this fix:

- launch-time UI work was touching cloud credential state too early
- that could stall the menu bar app before it finished launching
- once the shell stalled, the CLI looked broken too, because it talks to the running app over IPC
- the device itself was fine, and the BLE transport was fine once the app launched cleanly

## BLE light path disappears after rebuild or relaunch

The important distinction is:

- `DitooPro-Audio` is not the 16x16 display transport
- the real display path is the hidden `DitooPro-Light` BLE peripheral

The app now persists the last known `DitooPro-Light` peripheral UUID and, if that defaults key is missing, tries to recover it from the app log before scanning again. That keeps the known-good `retrievePeripherals(withIdentifiers:)` path alive across rebuilds and crashes.

If the app still comes up as `BLE light idle` or `BLE light connecting` for too long:

1. make sure the Ditoo is awake
2. open `Ambient & Device -> Reconnect Light Link`
3. if needed, restart the Ditoo once so `DitooPro-Light` starts advertising again
4. re-open the app and watch `~/Library/Logs/DivoomMenuBar.log`

Expected healthy log lines:

- `retrievePeripherals cached id=... name=DitooPro-Light`
- `didConnect BLE peripheral name=DitooPro-Light`
- `BLE light write characteristic ready`

If you only see `DitooPro-Audio`, the speaker is visible but the display endpoint is not.

What changed:

- ordinary menu and library refresh no longer need an interactive credential read
- explicit cloud actions are the only place that should try to use secrets
- saving credentials now verifies the Divoom account first and then rewrites the app-local Keychain items in a stable shape that survives local rebuilds better

Current intended flow:

1. open `Settings -> Cloud`
2. either click `Save + Verify` with the Divoom login directly, or click `Import + Verify` once
3. after that, use the saved local copy for the smoothest path

If prompts still continue:

1. open `Settings -> Cloud`
2. click `Clear Saved`
3. save the credentials directly into the app Keychain again with `Save + Verify`
4. turn off `Sync Divoom Cloud on app launch` and `Auto-sync Divoom Cloud every 6 hours` until the next manual cloud action succeeds cleanly
5. avoid repeated re-import attempts unless you actually need to refresh the local copy

## CLI works badly or not at all

The CLI expects the menu bar app to be running.

Start it first:

```bash
./bin/divoom-display native-open-app
```

Then retry the action.

## Release install works, but `divoom-display` is missing

This is expected if you installed from the `.pkg` or `.zip` release artifact. Those paths install the app only.

The one-line source installer is the path that is meant to wire the CLI into `/usr/local/bin` and create the support repo checkout under `~/Library/Application Support/DivoomDitooProMac/repo`.

Check:

```bash
which divoom-display
ls -l /usr/local/bin/divoom-display
```

If needed, reinstall with the source installer or run from the repo copy directly:

```bash
/Users/kirniy/Library/Application\ Support/DivoomDitooProMac/repo/bin/divoom-display native-open-app
```

## Logs

Primary app log:

```text
~/Library/Logs/DivoomMenuBar.log
```

Useful actions:

- open the log from the app Settings surface
- reveal the log in Finder from the app Settings surface
- export a copy of the log from the app Settings surface
- inspect the last lines directly:

```bash
tail -n 100 ~/Library/Logs/DivoomMenuBar.log
```

## Known beta-grade issues

- cloud auth and Passwords import UX still needs tightening
- exact iOS store/channel sorting parity is not finished
- autonomous device-side playlist/channel playback is still under reverse engineering
- some menu and live-feed surfaces are still actively being polished
