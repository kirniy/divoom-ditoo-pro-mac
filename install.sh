#!/bin/zsh
set -euo pipefail

REPO_URL="${REPO_URL:-https://github.com/kirniy/divoom-ditoo-pro-mac.git}"
INSTALL_DIR="${INSTALL_DIR:-/Applications}"
LINK_DIR="${LINK_DIR:-/usr/local/bin}"
SUPPORT_ROOT="${SUPPORT_ROOT:-$HOME/Library/Application Support/DivoomDitooProMac}"
REPO_DIR="$SUPPORT_ROOT/repo"

mkdir -p "$SUPPORT_ROOT"
if [[ -d "$REPO_DIR/.git" ]]; then
  git -C "$REPO_DIR" fetch --depth=1 origin main >/dev/null
  git -C "$REPO_DIR" reset --hard FETCH_HEAD >/dev/null
else
  rm -rf "$REPO_DIR"
  git clone --depth=1 "$REPO_URL" "$REPO_DIR" >/dev/null
fi

"$REPO_DIR/bin/build-divoom-menubar-app" >/dev/null

APP_SRC="$REPO_DIR/build/DivoomMenuBar.app"
APP_DEST="$INSTALL_DIR/DivoomMenuBar.app"
CLI_SRC="$REPO_DIR/bin/divoom-display"
CLI_DEST="$LINK_DIR/divoom-display"

if [[ ! -d "$INSTALL_DIR" ]]; then
  sudo mkdir -p "$INSTALL_DIR"
fi

if [[ -e "$APP_DEST" ]]; then
  sudo rm -rf "$APP_DEST"
fi
sudo cp -R "$APP_SRC" "$APP_DEST"

if [[ -d "$LINK_DIR" ]]; then
  sudo mkdir -p "$LINK_DIR"
  sudo ln -sf "$CLI_SRC" "$CLI_DEST"
fi

open -na "$APP_DEST"

printf 'Installed %s\n' "$APP_DEST"
printf 'CLI linked to %s\n' "$CLI_DEST"
printf 'Support repo at %s\n' "$REPO_DIR"
