#!/bin/zsh
set -euo pipefail

provider="${1:-codex}"
exec /Users/kirniy/dev/divoom/bin/divoom-display send-status --provider "$provider"
