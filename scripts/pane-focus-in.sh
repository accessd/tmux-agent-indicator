#!/usr/bin/env bash
# Clear deferred visual state and stale window-title styles on focus changes.

set -euo pipefail

if ! command -v tmux >/dev/null 2>&1; then
    exit 0
fi

tmux_get_env() {
    local key="$1"
    tmux show-environment -g "$key" 2>/dev/null | sed 's/^[^=]*=//' || true
}

tmux_unset_env() {
    tmux set-environment -gu "$1" 2>/dev/null || true
}

restore_window_option() {
    local window_id="$1"
    local option="$2"
    local env_key="$3"
    local marker="__UNSET__"
    local saved

    saved=$(tmux_get_env "$env_key")
    if [ -z "$saved" ]; then
        return
    fi
    if [ "$saved" = "$marker" ]; then
        tmux set-window-option -qt "$window_id" -u "$option" || true
    else
        tmux set-window-option -qt "$window_id" "$option" "$saved"
    fi
    tmux_unset_env "$env_key"
}

restore_window_title_style() {
    local window_id="$1"
    local window_done_key="TMUX_AGENT_WINDOW_${window_id}_DONE"
    local window_status_key="TMUX_AGENT_WINDOW_${window_id}_ORIG_STATUS_STYLE"
    local window_status_current_key="TMUX_AGENT_WINDOW_${window_id}_ORIG_STATUS_CURRENT_STYLE"

    restore_window_option "$window_id" "window-status-style" "$window_status_key"
    restore_window_option "$window_id" "window-status-current-style" "$window_status_current_key"
    tmux_unset_env "$window_done_key"
}

restore_inactive_window_title_styles() {
    local active_window_id="$1"
    local line window_prefix target_window_id

    while IFS= read -r line; do
        [ -z "$line" ] && continue
        window_prefix="${line%%_ORIG_STATUS_STYLE=*}"
        target_window_id="${window_prefix#TMUX_AGENT_WINDOW_}"
        [ -z "$target_window_id" ] && continue
        [ "$target_window_id" = "$active_window_id" ] && continue
        restore_window_title_style "$target_window_id"
    done < <(tmux show-environment -g | rg '^TMUX_AGENT_WINDOW_.*_ORIG_STATUS_STYLE=' || true)
}

pane_id="${1:-}"
window_id="${2:-}"
if [ -z "$pane_id" ]; then
    pane_id=$(tmux display-message -p '#{pane_id}')
fi
if [ -z "$window_id" ]; then
    window_id=$(tmux display-message -p -t "$pane_id" '#{window_id}')
fi

# Ensure title styles do not persist after switching away from a window.
restore_inactive_window_title_styles "$window_id"

state_key="TMUX_AGENT_PANE_${pane_id}_STATE"
agent_key="TMUX_AGENT_PANE_${pane_id}_AGENT"
done_key="TMUX_AGENT_PANE_${pane_id}_DONE"
done_window_key="TMUX_AGENT_PANE_${pane_id}_DONE_WINDOW"
pending_reset_key="TMUX_AGENT_PANE_${pane_id}_PENDING_RESET"

window_done_key="TMUX_AGENT_WINDOW_${window_id}_DONE"
window_border_key="TMUX_AGENT_WINDOW_${window_id}_ORIG_ACTIVE_BORDER_STYLE"

pending_reset=$(tmux_get_env "$pending_reset_key")
if [ "$pending_reset" = "1" ]; then
    tmux select-pane -t "$pane_id" -P "bg=default"
    restore_window_option "$window_id" "pane-active-border-style" "$window_border_key"
    tmux_unset_env "$pending_reset_key"
fi

window_done=$(tmux_get_env "$window_done_key")
state=$(tmux_get_env "$state_key")
done_marker=$(tmux_get_env "$done_key")
done_window=$(tmux_get_env "$done_window_key")
if [ -z "$done_window" ]; then
    done_window="$window_id"
fi
done_window_done_key="TMUX_AGENT_WINDOW_${done_window}_DONE"
done_window_border_key="TMUX_AGENT_WINDOW_${done_window}_ORIG_ACTIVE_BORDER_STYLE"

if [ "$window_done" = "1" ] || [ "$state" = "done" ] || [ "$done_marker" = "1" ]; then
    restore_window_title_style "$done_window"
    restore_window_option "$done_window" "pane-active-border-style" "$done_window_border_key"
    tmux_unset_env "$done_window_done_key"
    tmux_unset_env "$done_key"
    tmux_unset_env "$done_window_key"
    tmux_unset_env "$state_key"
    tmux_unset_env "$agent_key"

    # Clear stale done state markers for any pane in the done window.
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        pane_prefix="${line%%_DONE_WINDOW=*}"
        tmux_unset_env "${pane_prefix}_DONE"
        tmux_unset_env "${pane_prefix}_DONE_WINDOW"
        tmux_unset_env "${pane_prefix}_PENDING_RESET"
        tmux_unset_env "${pane_prefix}_STATE"
        tmux_unset_env "${pane_prefix}_AGENT"
    done < <(tmux show-environment -g | rg "^TMUX_AGENT_PANE_.*_DONE_WINDOW=${done_window}$" || true)
fi

tmux refresh-client -S >/dev/null 2>&1 || true
