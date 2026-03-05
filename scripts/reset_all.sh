#!/usr/bin/env bash
# Reset all tmux panes, borders, and window title styles to defaults.
# Cleans up every TMUX_AGENT_* env var and stops animation.

set -euo pipefail

if ! command -v tmux >/dev/null 2>&1; then
    exit 0
fi
if ! tmux display-message -p '#{session_name}' >/dev/null 2>&1; then
    exit 0
fi

tmux_get_env() {
    local key="$1"
    tmux show-environment -g "$key" 2>/dev/null | sed 's/^[^=]*=//' || true
}

tmux_unset_env() {
    tmux set-environment -gu "$1" 2>/dev/null || true
}

reset_window_option() {
    local window_id="$1"
    local option="$2"
    local env_key="$3"
    local marker="__UNSET__"
    local saved

    saved=$(tmux_get_env "$env_key")
    if [ -n "$saved" ] && [ "$saved" != "$marker" ]; then
        # Restore the original value that was saved before the plugin modified it.
        tmux set-window-option -qt "$window_id" "$option" "$saved" || true
    else
        # No saved original (or it was unset before). Unset the window-level
        # override so it falls back to the global/inherited default.
        tmux set-window-option -qt "$window_id" -u "$option" 2>/dev/null || true
    fi
    tmux_unset_env "$env_key"
}

# Stop animation
anim_pid=$(tmux_get_env "TMUX_AGENT_ANIMATION_PID")
if [ -n "$anim_pid" ] && kill -0 "$anim_pid" 2>/dev/null; then
    kill "$anim_pid" 2>/dev/null || true
fi
tmux_unset_env "TMUX_AGENT_ANIMATION_PID"
tmux_unset_env "TMUX_AGENT_ANIMATION_FRAME"

# Reset all pane backgrounds
active_pane=$(tmux display-message -p '#{pane_id}')
while IFS= read -r pane_id; do
    [ -z "$pane_id" ] && continue
    tmux select-pane -t "$pane_id" -P "bg=default" 2>/dev/null || true
done < <(tmux list-panes -a -F '#{pane_id}')
tmux select-pane -t "$active_pane" 2>/dev/null || true

# Restore saved window options and reset borders
while IFS= read -r window_id; do
    [ -z "$window_id" ] && continue
    reset_window_option "$window_id" "window-status-style" "TMUX_AGENT_WINDOW_${window_id}_ORIG_STATUS_STYLE"
    reset_window_option "$window_id" "window-status-current-style" "TMUX_AGENT_WINDOW_${window_id}_ORIG_STATUS_CURRENT_STYLE"
    reset_window_option "$window_id" "pane-active-border-style" "TMUX_AGENT_WINDOW_${window_id}_ORIG_ACTIVE_BORDER_STYLE"
    tmux_unset_env "TMUX_AGENT_WINDOW_${window_id}_DONE"
done < <(tmux list-windows -a -F '#{window_id}')

# Remove all TMUX_AGENT_* env vars
while IFS= read -r line; do
    [ -z "$line" ] && continue
    var_name="${line%%=*}"
    tmux_unset_env "$var_name"
done < <(tmux show-environment -g 2>/dev/null | grep '^TMUX_AGENT_' || true)

tmux refresh-client -S >/dev/null 2>&1 || true
