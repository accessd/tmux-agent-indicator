#!/usr/bin/env bash
# Knight Rider animation loop for the running state.
# Launched as a background process by agent-state.sh.
# Bounces a frame index 0->6->0 and writes it to a tmux env var,
# then forces a status bar refresh each tick.

set -euo pipefail

cleanup() {
    tmux set-environment -gu TMUX_AGENT_ANIMATION_FRAME 2>/dev/null || true
    tmux set-environment -gu TMUX_AGENT_ANIMATION_PID 2>/dev/null || true
}
trap cleanup EXIT

# Bail out if tmux server is gone.
if ! command -v tmux >/dev/null 2>&1; then
    exit 0
fi
if ! tmux list-sessions >/dev/null 2>&1; then
    exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/state-lib.sh
source "$SCRIPT_DIR/state-lib.sh"

# Convert a millisecond count to a sleep(1) argument (1500 -> 1.500).
# Anything but a positive integer falls back to the 300ms default.
ms_to_sleep_arg() {
    local ms="$1"
    if ! [[ "$ms" =~ ^[0-9]+$ ]] || [ "$((10#$ms))" -le 0 ]; then
        ms=300
    fi
    ms=$((10#$ms))
    printf '%d.%03d\n' "$((ms / 1000))" "$((ms % 1000))"
}

# Store our PID so agent-state.sh can kill us.
tmux set-environment -g TMUX_AGENT_ANIMATION_PID "$$"

sleep_arg=$(ms_to_sleep_arg "$(tmux_get_option_or_default "@agent-indicator-animation-speed" "300")")

# Bounce sequence: 0 1 2 3 4 5 6 5 4 3 2 1 (12 frames total)
frames=(0 1 2 3 4 5 6 5 4 3 2 1)
frame_count=${#frames[@]}
idx=0

# Self-terminate once no live pane is running (also when the server is gone:
# the scan then finds nothing). Panes closed while running are pruned so their
# stale state cannot keep the loop alive.
while any_live_pane_running; do
    frame="${frames[$idx]}"
    tmux set-environment -g TMUX_AGENT_ANIMATION_FRAME "$frame" 2>/dev/null || break
    tmux refresh-client -S 2>/dev/null || true

    idx=$(( (idx + 1) % frame_count ))
    sleep "$sleep_arg" 2>/dev/null || sleep 1
done

prune_dead_panes
