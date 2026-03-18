#!/bin/zsh
set -euo pipefail

log_file="$HOME/Library/Logs/divoom-hooks.log"
disable_file="${DIVOOM_AUDIO_DISABLE_FILE:-/tmp/divoom-audio-hooks.disabled}"
mkdir -p "$(dirname "$log_file")"

payload="${1:-}"
if [[ -z "$payload" ]]; then
  payload="$(cat 2>/dev/null || true)"
fi

type=""
if [[ -n "$payload" ]]; then
  type="$(printf '%s' "$payload" | /opt/homebrew/bin/jq -r '.type // empty' 2>/dev/null || true)"
fi

if [[ -e "$disable_file" ]]; then
  printf '%s codex-notify %s skipped-audio-disabled\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${type:-unknown}" >>"$log_file"
  exit 0
fi

printf '%s codex-notify %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${type:-unknown}" >>"$log_file"

case "$type" in
  agent-turn-complete)
    /Users/kirniy/dev/divoom/bin/divoom-display play-sound --profile complete >/dev/null 2>&1 || true
    ;;
  *)
    if [[ "$type" == *approval* || "$type" == *request* || "$type" == *elicitation* ]]; then
      /Users/kirniy/dev/divoom/bin/divoom-display play-sound --profile attention >/dev/null 2>&1 || true
    fi
    ;;
esac
