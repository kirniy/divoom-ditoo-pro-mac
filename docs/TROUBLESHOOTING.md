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

Useful recovery commands from a repo checkout:

```bash
./bin/divoom-display native-headless diagnostics
./bin/divoom-display native-headless probe
```

## Cloud login looks present, but cloud actions still fail

This is a current beta pain point.

The best path is:

1. open `Help & Settings -> Cloud`
2. save Divoom credentials into the app Keychain, or keep using the synced `divoom-gz.com` Passwords entry
3. run `Sync Cloud`

Current runtime truth:

- passive UI refresh should not probe Passwords anymore
- explicit cloud actions use the app-local Keychain copy first
- if that local copy is missing, explicit cloud actions can fall back to the synced `divoom-gz.com` Passwords entry for the current session
- importing from Passwords into the app-local Keychain is still available, but it is not the only path

If cloud actions still fail:

- open Settings and confirm the app has locally saved credentials
- if needed, clear saved credentials and save them again
- if the native library header still shows `Connect Cloud…`, the app does not see a local saved copy yet
- if the local copy is awkward, try the synced Passwords route directly from an explicit cloud action
- then run a new sync

## Repeated Keychain or Passwords prompts

The app should no longer probe synced Passwords items during ordinary UI refresh, and silent cloud work should not trigger interactive unlock prompts.

The concrete bug we hit before this fix:

- launch-time UI work was touching cloud credential state too early
- that could stall the menu bar app before it finished launching
- once the shell stalled, the CLI looked broken too, because it talks to the running app over IPC
- the device itself was fine, and the BLE transport was fine once the app launched cleanly

What changed:

- ordinary menu and library refresh no longer need an interactive credential read
- explicit cloud actions are the only place that should try to use secrets
- saving credentials now rewrites the app-local Keychain items cleanly instead of preserving an older broken ACL shape

Current intended flow:

1. open `Help & Settings -> Cloud`
2. either save the Divoom login directly, or click `Import from Passwords` once
3. after that, use the saved local copy for the smoothest path, or let an explicit cloud action unlock the synced Passwords fallback for the current session

If prompts still continue:

1. open `Help & Settings -> Cloud`
2. click `Clear Saved`
3. save the credentials directly into the app Keychain
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
