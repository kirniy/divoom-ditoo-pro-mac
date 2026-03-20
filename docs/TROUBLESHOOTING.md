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
3. Test a simple command:

```bash
./bin/divoom-display native-headless scene-color --color '#247cff'
```

Important: the running app owns Bluetooth. The CLI is only an IPC client.

## Cloud login looks present, but cloud actions still fail

This is a current beta pain point.

The stable intended path is:

1. open `Settings -> Library`
2. save Divoom credentials into the app Keychain
3. use `Sync Cloud`

The synced Passwords entry for `divoom-gz.com` is currently best treated as an import source, not the main long-term runtime credential source.

If cloud actions still fail:

- open Settings and confirm the app has locally saved credentials
- if needed, clear saved credentials and save them again
- then run a new sync

## Repeated Passwords prompts

If macOS keeps prompting for access to a synced Passwords item, the app is likely still falling back to the synced entry rather than using a clean app-local copy.

Best current workaround:

1. use `Use Synced Password` once
2. make sure the import succeeds
3. keep using the app-local saved credential path afterward

If the prompts continue, clear the saved state and re-import once.

## CLI works badly or not at all

The CLI expects the menu bar app to be running.

Start it first:

```bash
./bin/divoom-display native-open-app
```

Then retry the action.

## Release install works, but `divoom-display` is missing

The one-line installer links the CLI into `/usr/local/bin`.

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
- inspect the last lines directly:

```bash
tail -n 100 ~/Library/Logs/DivoomMenuBar.log
```

## Known beta-grade issues

- cloud auth and Passwords import UX still needs tightening
- exact iOS store/channel sorting parity is not finished
- autonomous device-side playlist/channel playback is still under reverse engineering
- some menu and live-feed surfaces are still actively being polished
