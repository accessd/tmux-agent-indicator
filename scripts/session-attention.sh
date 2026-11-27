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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/state-lib.sh
source "$SCRIPT_DIR/state-lib.sh"

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

# Session of every live pane (closed panes may still have stale state keys).
declare -A pane_session
while read -r pane_id dead session; do
    [ -n "$pane_id" ] && [ "$dead" != "1" ] || continue
    [ -n "${pane_session[$pane_id]:-}" ] || pane_session["$pane_id"]="$session"
done < <(tmux list-panes -a -F '#{pane_id} #{pane_dead} #{session_name}' 2>/dev/null || true)

agent_env_load
declare -A session_state
for key in "${!AGENT_ENV[@]}"; do
    case "$key" in
        TMUX_AGENT_PANE_*_STATE) ;;
        *) continue ;;
    esac
    state="${AGENT_ENV[$key]}"
    [ -n "$state" ] && [ -n "${attention_state_map[$state]:-}" ] || continue
    pane_id=$(pane_from_key "$key")
    [ -n "$pane_id" ] || continue
    session="${pane_session[$pane_id]:-}"
    [ -n "$session" ] || continue
    [ "$session" != "$exclude" ] || continue
    [ -z "${seen_sessions[$session]:-}" ] || continue
    current="${session_state[$session]:-}"
    if [ -z "$current" ] || state_more_urgent "$state" "$current"; then
        session_state["$session"]="$state"
    fi
done

title_bg() {
    state_option "$1" window-title-bg
}

title_fg() {
    state_option "$1" window-title-fg
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
