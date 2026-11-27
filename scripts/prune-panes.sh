#!/usr/bin/env bash
# Drop agent state of closed panes and restore the styling of their windows.
# Registered on pane-exited, pane-died, after-kill-pane and window-unlinked.

set -euo pipefail

if ! command -v tmux >/dev/null 2>&1; then
    exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/state-lib.sh
source "$SCRIPT_DIR/state-lib.sh"

prune_dead_panes
stop_animation_if_idle
tmux refresh-client -S >/dev/null 2>&1 || true
