#!/usr/bin/env bash
# Sessions whose agents need attention.
#
# A session needs attention while one of its panes is in an
# @agent-indicator-session-dots-attention-states state (default
# `needs-input,done`) and it has not been marked seen by switching away from
# it. needs-input outranks done; a session reports its most urgent state.

set -euo pipefail

usage() {
    cat <<'EOF' >&2
Usage: session-attention.sh [--exclude <session>] [--color <fallback>]

  Without --color, prints one line per session needing attention:
    <session>\t<state>\t<window-title-bg>\t<window-title-fg>
  using the window-title colours agent-state.sh applies for that state.

  With --color, prints only the window-title background of the most urgent
  session, or <fallback> when none needs attention.

  --exclude skips a session (usually the current one, '#S').
EOF
}

exclude=""
color_mode=""
fallback=""
while [ $# -gt 0 ]; do
    case "$1" in
        --exclude|--color)
            [ $# -ge 2 ] || { usage; exit 1; }
            if [ "$1" = "--exclude" ]; then
                exclude="$2"
            else
                color_mode=1
                fallback="$2"
            fi
            shift 2
            ;;
        *)
            usage
            exit 1
            ;;
    esac
done

if ! command -v tmux >/dev/null 2>&1 || ! tmux list-sessions >/dev/null 2>&1; then
    [ -n "$color_mode" ] && printf '%s\n' "$fallback"
    exit 0
fi

tmux_option_is_set() {
    local option="$1"
    local raw
    raw=$(tmux show-option -gq "$option" 2>/dev/null || true)
    [ -n "$raw" ]
}

tmux_get_option_or_default() {
    local option="$1"
    local default_value="$2"
    local value
    if tmux_option_is_set "$option"; then
        value=$(tmux show-option -gqv "$option")
        printf '%s\n' "$value"
    else
        printf '%s\n' "$default_value"
    fi
}

default_state_title_bg() {
    case "$1" in
        needs-input) printf 'yellow\n' ;;
        done) printf 'red\n' ;;
        *) printf '\n' ;;
    esac
}

default_state_title_fg() {
    case "$1" in
        needs-input) printf 'black\n' ;;
        done) printf 'black\n' ;;
        *) printf '\n' ;;
    esac
}

state_rank() {
    case "$1" in
        needs-input) printf '2\n' ;;
        *) printf '1\n' ;;
    esac
}

ATTENTION_STATES=$(tmux_get_option_or_default "@agent-indicator-session-dots-attention-states" "needs-input,done")

declare -A attention_state_map
IFS=',' read -ra STATE_ARRAY <<< "$ATTENTION_STATES"
for s in "${STATE_ARRAY[@]}"; do
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    [ -n "$s" ] && attention_state_map["$s"]=1
done

declare -A seen_sessions
while IFS= read -r line; do
    [ -z "$line" ] && continue
    # Format: TMUX_AGENT_SESSION_SEEN_<session>=1
    seen_session="${line#TMUX_AGENT_SESSION_SEEN_}"
    [ "${seen_session##*=}" = "1" ] && seen_sessions["${seen_session%=*}"]=1
done < <(tmux show-environment -g 2>/dev/null | grep '^TMUX_AGENT_SESSION_SEEN_' || true)

declare -A session_state
while IFS= read -r line; do
    [ -z "$line" ] && continue
    # Format: TMUX_AGENT_PANE_%xx_STATE=<state>
    pane_id="${line#TMUX_AGENT_PANE_}"
    pane_id="${pane_id%%_STATE=*}"
    state="${line#*_STATE=}"
    [ -n "${attention_state_map[$state]:-}" ] || continue
    session=$(tmux display-message -p -t "$pane_id" '#{session_name}' 2>/dev/null || true)
    [ -n "$session" ] || continue
    [ "$session" != "$exclude" ] || continue
    [ -z "${seen_sessions[$session]:-}" ] || continue
    current="${session_state[$session]:-}"
    if [ -z "$current" ] || [ "$(state_rank "$state")" -gt "$(state_rank "$current")" ]; then
        session_state["$session"]="$state"
    fi
done < <(tmux show-environment -g 2>/dev/null | grep '^TMUX_AGENT_PANE_.*_STATE=' || true)

title_bg() {
    tmux_get_option_or_default "@agent-indicator-$1-window-title-bg" "$(default_state_title_bg "$1")"
}

title_fg() {
    tmux_get_option_or_default "@agent-indicator-$1-window-title-fg" "$(default_state_title_fg "$1")"
}

if [ -n "$color_mode" ]; then
    best=""
    for session in "${!session_state[@]}"; do
        state="${session_state[$session]}"
        if [ -z "$best" ] || [ "$(state_rank "$state")" -gt "$(state_rank "$best")" ]; then
            best="$state"
        fi
    done
    color=""
    [ -n "$best" ] && color=$(title_bg "$best")
    printf '%s\n' "${color:-$fallback}"
    exit 0
fi

for session in "${!session_state[@]}"; do
    state="${session_state[$session]}"
    printf '%s\t%s\t%s\t%s\n' "$session" "$state" "$(title_bg "$state")" "$(title_fg "$state")"
done
