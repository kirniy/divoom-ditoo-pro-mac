# Install and Release

## Current install paths

There are two real install paths today.

### 1. One-line source install

```bash
curl -fsSL https://raw.githubusercontent.com/kirniy/divoom-ditoo-pro-mac/main/install.sh | bash
```

This is a source build installer. It does not download a prebuilt binary.

What it does:

- clones or refreshes the repo in `~/Library/Application Support/DivoomDitooProMac/repo`
- runs `bin/build-divoom-menubar-app`
- installs `DivoomMenuBar.app` into `/Applications`
- links `divoom-display` into `/usr/local/bin/divoom-display`
- launches the installed app

Requirements:

- macOS
- `git`
- `python3`
- Xcode Command Line Tools with `swiftc`

Installed locations:

- app: `/Applications/DivoomMenuBar.app`
- support repo: `~/Library/Application Support/DivoomDitooProMac/repo`
- CLI link: `/usr/local/bin/divoom-display`

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

## Current release truth

- current version source of truth: `VERSION`
- current version: `0.2.0-beta.1`
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
4. Test with:

```bash
./bin/divoom-display native-headless scene-color --color '#19c37d'
```

## What install does not solve for you

- macOS Bluetooth privacy prompts still need user approval
- cloud login still needs credentials or a one-time Passwords import
- device pairing / radio environment issues still need troubleshooting on the host Mac

## Related docs

- troubleshooting: [`TROUBLESHOOTING.md`](./TROUBLESHOOTING.md)
- cloud login and sync: [`DIVOOM_CLOUD_SYNC.md`](./DIVOOM_CLOUD_SYNC.md)
