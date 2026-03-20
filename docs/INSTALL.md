# Install and Release

## Current install paths

There are two real install paths today.

Quick rule:

- source install = app + CLI + support repo checkout
- `.pkg` / `.zip` = app only

### 1. One-line source install

```bash
curl -fsSL https://raw.githubusercontent.com/kirniy/divoom-ditoo-pro-mac/main/install.sh | bash
```

This is a source build installer. It does not download a prebuilt binary.

What it does:

- clones or refreshes the repo in `~/Library/Application Support/DivoomDitooProMac/repo`
- runs `bin/build-divoom-menubar-app`
- installs `DivoomMenuBar.app` into `/Applications`
- source-install path for `divoom-display` in `/usr/local/bin/divoom-display`
- launches the installed app

Requirements:

- macOS
- `git`
- `python3`
- Xcode Command Line Tools with `swiftc`

Installed locations:

- app: `/Applications/DivoomMenuBar.app`
- support repo: `~/Library/Application Support/DivoomDitooProMac/repo`
- expected CLI link after source install: `/usr/local/bin/divoom-display`

Use this path if you want menu bar control plus local automation and CLI access.

### 2. Release artifacts

Generate them locally:

```bash
./bin/package-release-artifacts
```

Outputs:

- `build/release/DivoomDitooProMac-<version>.zip`
- `build/release/DivoomDitooProMac-<version>.pkg`

Use the `.pkg` if you want a straightforward installer artifact.

Use the `.zip` if you want the app bundle directly.

Current release truth: both artifacts install the app only. They do not set up `divoom-display` and they do not create the support repo checkout used by the source installer.

Use this path if you only want the app bundle and do not need the CLI.

## Current release truth

- current version source of truth: `VERSION`
- current version: `0.3.0-beta.3`
- release stage: early beta

There is no Homebrew formula in this repo yet.

## Build and package commands

Build the app:

```bash
./bin/build-divoom-menubar-app
```

Open the built app:

```bash
open ./build/DivoomMenuBar.app
```

Package release artifacts:

```bash
./bin/package-release-artifacts
```

## First launch checklist

1. Launch the app.
2. Allow Bluetooth access when macOS asks.
3. Wait for the Ditoo Pro to be discovered.
4. If the speaker side appears but beams still fail, use `Device -> Connection -> Reconnect Light Link`, then `Run Bluetooth Diagnostics`.
5. If you used the source installer or a local repo checkout, test with:

```bash
./bin/divoom-display native-headless scene-color --color '#19c37d'
```

## What install does not solve for you

- macOS Bluetooth privacy prompts still need user approval
- cloud login still needs app-local credentials or a one-time Passwords import into the app Keychain
- device pairing / radio environment issues still need troubleshooting on the host Mac
- `.pkg` / `.zip` releases do not install the CLI for you

## Related docs

- troubleshooting: [`TROUBLESHOOTING.md`](./TROUBLESHOOTING.md)
- cloud login and sync: [`DIVOOM_CLOUD_SYNC.md`](./DIVOOM_CLOUD_SYNC.md)
