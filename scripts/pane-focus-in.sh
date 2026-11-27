#!/usr/bin/env bash
# Clear deferred visual state and stale window-title styles on focus changes.

set -euo pipefail

if ! command -v tmux >/dev/null 2>&1; then
    exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/state-lib.sh
source "$SCRIPT_DIR/state-lib.sh"

target_is_focused() {
    local pane_id="$1"
    local window_id="$2"
    local pane_active window_active

    pane_active=$(tmux display-message -p -t "$pane_id" '#{pane_active}' 2>/dev/null || true)
    window_active=$(tmux display-message -p -t "$window_id" '#{window_active}' 2>/dev/null || true)
    [ "$pane_active" = "1" ] && [ "$window_active" = "1" ]
}

# Forget that a pane finished: its state, agent and window contributions go,
# but a deferred background reset stays until the pane itself is focused.
clear_done_state() {
    clear_pane_keys "$1" STATE AGENT WINDOW DONE DONE_WINDOW TITLE BORDER
}

pane_id="${1:-}"
window_id="${2:-}"
if [ -z "$pane_id" ]; then
    pane_id=$(tmux display-message -p '#{pane_id}')
fi
if [ -z "$window_id" ]; then
    window_id=$(tmux display-message -p -t "$pane_id" '#{window_id}')
fi

# Ignore stale hook invocations that do not match the currently focused pane/window.
if ! target_is_focused "$pane_id" "$window_id"; then
    exit 0
fi

agent_env_load

pane_prefix="TMUX_AGENT_PANE_${pane_id}"
state="${AGENT_ENV[${pane_prefix}_STATE]:-}"
done_marker="${AGENT_ENV[${pane_prefix}_DONE]:-}"
done_window="${AGENT_ENV[${pane_prefix}_DONE_WINDOW]:-$window_id}"
changed=""

if [ "${AGENT_ENV[${pane_prefix}_PENDING_RESET]:-}" = "1" ]; then
    reset_pane_style "$pane_id"
    clear_pane_keys "$pane_id" BORDER PENDING_RESET
    changed=1
fi

# Needs-input visuals are cleared when focus returns to the source pane; the
# state itself stays until the agent reports again.
if [ "$state" = "needs-input" ]; then
    reset_pane_style "$pane_id"
    clear_pane_keys "$pane_id" TITLE BORDER
    changed=1
fi

# Done panes are acknowledged when focused, and every done pane of a window is
# acknowledged once the user looks at a window whose title shows done.
# Running and needs-input panes are never touched here.
window_shows_done=""
declare -A done_panes=()
for key in "${!AGENT_ENV[@]}"; do
    case "$key" in
        TMUX_AGENT_PANE_*_DONE_WINDOW) ;;
        *) continue ;;
    esac
    [ "${AGENT_ENV[$key]}" = "$window_id" ] || continue
    other=$(pane_from_key "$key")
    [ -n "$other" ] || continue
    case "${AGENT_ENV[TMUX_AGENT_PANE_${other}_STATE]:-}" in
        done|"") ;;
        *) continue ;;
    esac
    done_panes["$other"]=1
    if [ "${AGENT_ENV[TMUX_AGENT_PANE_${other}_TITLE]:-}" = "done" ]; then
        window_shows_done=1
    fi
done

if [ "$state" = "done" ] || [ "$done_marker" = "1" ] || [ -n "$window_shows_done" ]; then
    if [ "$state" = "done" ] || [ "$done_marker" = "1" ]; then
        clear_done_state "$pane_id"
    fi
    if [ -n "$window_shows_done" ]; then
        live_panes_load
        for other in "${!done_panes[@]}"; do
            if pane_is_live "$other"; then
                clear_done_state "$other"
            else
                clear_pane_keys "$other"
            fi
        done
    fi
    stop_animation_if_idle
    changed=1
fi

if [ -n "$changed" ]; then
    window_refresh_styles "$window_id"
    if [ "$done_window" != "$window_id" ]; then
        window_refresh_styles "$done_window"
    fi
fi

tmux refresh-client -S >/dev/null 2>&1 || true
