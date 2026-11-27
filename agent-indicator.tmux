#!/usr/bin/env bash
# tmux-agent-indicator bootstrap.

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

do_interpolation() {
    local string="$1"
    # Replacements live in variables: single quotes written inline in a
    # ${var//pat/rep} replacement are stripped by bash, which would unquote
    # the pane id / session name argument.
    local indicator="#($CURRENT_DIR/scripts/indicator.sh '#{pane_id}')"
    local limits="#($CURRENT_DIR/scripts/agent-limits.sh)"
    local session_dots="#($CURRENT_DIR/scripts/session-dots.sh '#S')"
    # bash >= 5.2 treats `&` in a replacement as the matched text.
    shopt -u patsub_replacement 2>/dev/null || true
    string="${string//\#\{agent_indicator\}/$indicator}"
    string="${string//\#\{agent_limits\}/$limits}"
    string="${string//\#\{agent_session_dots\}/$session_dots}"
    echo "$string"
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

# Register a hook command, first removing every earlier entry of this hook
# that runs the same plugin script. Matching uses the path-independent
# `/scripts/<name>` suffix, so a reload also replaces hooks registered from
# an older install directory (e.g. a previous Nix store path).
register_hook_once() {
    local hook_type="$1"
    local command="$2"
    local match="$3"
    local existing_hooks line existing_name
    existing_hooks=$(tmux show-hooks -g "$hook_type" 2>/dev/null || true)

    while IFS= read -r line; do
        [ -z "$line" ] && continue
        existing_name="${line%% *}"
        tmux set-hook -gu "$existing_name" 2>/dev/null || true
    done < <(printf '%s\n' "$existing_hooks" | grep -F -- "$match" || true)

    tmux set-hook -ag "$hook_type" "$command"
}

register_focus_hooks() {
    local match="/scripts/pane-focus-in.sh"
    local hook_command="run-shell \"$CURRENT_DIR$match \\\"#{pane_id}\\\" \\\"#{window_id}\\\"\""
    register_hook_once "pane-focus-in" "$hook_command" "$match"
    register_hook_once "after-select-window" "$hook_command" "$match"
    register_hook_once "after-select-pane" "$hook_command" "$match"
}

# Closed panes (and windows) must not leave state behind: it would keep the
# animation looping and window styling applied.
register_prune_hooks() {
    local match="/scripts/prune-panes.sh"
    local hook_command="run-shell \"$CURRENT_DIR$match\""
    local hook_type
    for hook_type in pane-exited pane-died after-kill-pane window-unlinked; do
        register_hook_once "$hook_type" "$hook_command" "$match"
    done
}

main() {
    tmux set-environment -g TMUX_AGENT_INDICATOR_DIR "$CURRENT_DIR"
    update_tmux_option "status-right"
    update_tmux_option "status-left"
    update_tmux_option "@minimal-tmux-status-right"
    update_tmux_option "@minimal-tmux-status-left"
    update_tmux_option "@minimal-tmux-status-right-extra"
    update_tmux_option "@minimal-tmux-status-left-extra"
    register_focus_hooks
    register_prune_hooks
    local session_match="/scripts/session-changed.sh"
    register_hook_once "client-session-changed" "run-shell \"$CURRENT_DIR$session_match\"" "$session_match"
    # Drop state left behind by panes closed before this (re)load.
    "$CURRENT_DIR/scripts/prune-panes.sh" >/dev/null 2>&1 || true
}

main
