#!/usr/bin/env bash
# tmux-agent-indicator bootstrap.

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

agent_indicator_interpolation=(
    "\#{agent_indicator}"
    "#($CURRENT_DIR/scripts/indicator.sh)"
)

do_interpolation() {
    local string="$1"
    local search="${agent_indicator_interpolation[0]}"
    local replace="${agent_indicator_interpolation[1]}"
    echo "${string//$search/$replace}"
}

update_tmux_option() {
    local option="$1"
    local option_value
    option_value=$(tmux show-option -gqv "$option")
    if [ -z "$option_value" ]; then
        return
    fi
    tmux set-option -gq "$option" "$(do_interpolation "$option_value")"
}

register_hook_once() {
    local hook_type="$1"
    local command="$2"
    local hook_script="$CURRENT_DIR/scripts/pane-focus-in.sh"
    local existing_hooks
    existing_hooks=$(tmux show-hooks -g "$hook_type" 2>/dev/null || true)

    # Remove previously registered plugin hooks to avoid duplicates.
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        local existing_name
        existing_name="${line%% *}"
        tmux set-hook -gu "$existing_name" 2>/dev/null || true
    done < <(printf '%s\n' "$existing_hooks" | grep -F "$hook_script" || true)

    tmux set-hook -ag "$hook_type" "$command"
}

register_focus_hooks() {
    local hook_script="$CURRENT_DIR/scripts/pane-focus-in.sh"
    local hook_command="run-shell \"$hook_script \\\"#{pane_id}\\\" \\\"#{window_id}\\\"\""
    register_hook_once "pane-focus-in" "$hook_command"
    register_hook_once "after-select-window" "$hook_command"
    register_hook_once "after-select-pane" "$hook_command"
}

main() {
    tmux set-environment -g TMUX_AGENT_INDICATOR_DIR "$CURRENT_DIR"
    update_tmux_option "status-right"
    update_tmux_option "status-left"
    update_tmux_option "@minimal-tmux-status-right"
    register_focus_hooks
}

main
