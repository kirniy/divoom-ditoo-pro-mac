#!/bin/zsh
set -euo pipefail

log_file="$HOME/Library/Logs/divoom-hooks.log"
disable_file="${DIVOOM_AUDIO_DISABLE_FILE:-/tmp/divoom-audio-hooks.disabled}"
mkdir -p "$(dirname "$log_file")"

cat >/dev/null || true
if [[ -e "$disable_file" ]]; then
  printf '%s claude-hook attention skipped-audio-disabled\n' "$(date '+%Y-%m-%d %H:%M:%S')" >>"$log_file"
  exit 0
fi

printf '%s claude-hook attention\n' "$(date '+%Y-%m-%d %H:%M:%S')" >>"$log_file"
/Users/kirniy/dev/divoom/bin/divoom-display play-sound --profile attention >/dev/null 2>&1 || true
