#!/usr/bin/env bash
# Set pane/window state for an AI agent.

set -euo pipefail

usage() {
    cat <<'EOF' >&2
Usage: agent-state.sh --agent <name> --state <running|needs-input|done|off>
EOF
}

# Style panes via the pane-scoped window-style option rather than
# `select-pane -P`: select-pane also makes the target pane the active pane,
# which steals focus when the styled pane shares the user's current window.
# set-option -p has no focus side effect at all.
apply_pane_style() {
    tmux set-option -p -t "$1" window-style "bg=$2" 2>/dev/null || true
}

start_animation() {
    local anim_enabled existing_pid
    anim_enabled=$(tmux_get_option_or_default "@agent-indicator-animation-enabled" "off")
    if ! is_enabled "$anim_enabled"; then
        return
    fi

    existing_pid=$(tmux_get_env "TMUX_AGENT_ANIMATION_PID")
    if [ -n "$existing_pid" ] && kill -0 "$existing_pid" 2>/dev/null; then
        return
    fi

    nohup bash "$SCRIPT_DIR/animation.sh" </dev/null >/dev/null 2>&1 &
    disown
}

# Requires agent_env_load and live_panes_load.
resolve_target_pane() {
    local agent="$1"
    local line pane_candidate running_candidate="" done_candidate="" mapped_pane

    if pane_is_live "${TMUX_PANE:-}"; then
        printf '%s\n' "$TMUX_PANE"
        return
    fi

    # Literal comparison: the agent name never reaches a regex.
    while IFS= read -r line; do
        case "$line" in
            TMUX_AGENT_PANE_*"_AGENT=$agent") ;;
            *) continue ;;
        esac
        pane_candidate=$(pane_from_key "$line")
        pane_is_live "$pane_candidate" || continue
        case "${AGENT_ENV[TMUX_AGENT_PANE_${pane_candidate}_STATE]:-}" in
            running|needs-input)
                running_candidate="$pane_candidate"
                break
                ;;
            done)
                [ -n "$done_candidate" ] || done_candidate="$pane_candidate"
                ;;
        esac
    done < <(tmux show-environment -g 2>/dev/null || true)

    if [ -n "$running_candidate" ]; then
        printf '%s\n' "$running_candidate"
        return
    fi
    if [ -n "$done_candidate" ]; then
        printf '%s\n' "$done_candidate"
        return
    fi

    mapped_pane="${AGENT_ENV[TMUX_AGENT_ACTIVE_PANE_${agent}]:-}"
    if pane_is_live "$mapped_pane"; then
        printf '%s\n' "$mapped_pane"
        return
    fi

    tmux display-message -p '#{pane_id}' 2>/dev/null || true
}

# display-message -d needs tmux 3.2; older servers fall back to display-time.
tmux_supports_display_duration() {
    local version major minor
    version=$(tmux display-message -p '#{version}' 2>/dev/null || true)
    version="${version#next-}"
    if [[ "$version" =~ ^([0-9]+)\.([0-9]+) ]]; then
        major="${BASH_REMATCH[1]}"
        minor="${BASH_REMATCH[2]}"
        [ "$major" -gt 3 ] || { [ "$major" -eq 3 ] && [ "$minor" -ge 2 ]; }
    else
        # Development builds ("master") and vendor strings: assume modern.
        return 0
    fi
}

notify_state_change() {
    local agent="$1" state="$2" pane_id="$3"

    local notif_enabled
    notif_enabled=$(tmux_get_option_or_default "@agent-indicator-notification-enabled" "on")
    is_enabled "$notif_enabled" || return 0

    local notif_states
    notif_states=$(tmux_get_option_or_default "@agent-indicator-notification-states" "needs-input,done")
    case ",$notif_states," in
        *",${state},"*) ;;
        *) return 0 ;;
    esac

    local fmt duration
    fmt=$(tmux_get_option_or_default "@agent-indicator-notification-format" \
        "[#{agent_name}] #{agent_state} (#{session_name}:#{window_name})")
    duration=$(tmux_get_option_or_default "@agent-indicator-notification-duration" "5000")

    local session_name="" window_name="" window_index=""
    IFS=$'\t' read -r session_name window_index window_name < <(
        tmux display-message -p -t "$pane_id" $'#{session_name}\t#{window_index}\t#{window_name}' 2>/dev/null
    ) || true

    local message="$fmt"
    message="${message//\#\{agent_name\}/$agent}"
    message="${message//\#\{agent_state\}/$state}"
    message="${message//\#\{session_name\}/$session_name}"
    message="${message//\#\{window_name\}/$window_name}"
    message="${message//\#\{window_index\}/$window_index}"

    if [ -n "$duration" ] && [ "$duration" != "0" ] && tmux_supports_display_duration; then
        tmux display-message -d "$duration" "$message" || true
    else
        tmux display-message "$message" || true
    fi

    local ext_cmd
    ext_cmd=$(tmux_get_option_or_default "@agent-indicator-notification-command" "")
    if [ -n "$ext_cmd" ]; then
        # Detached from the hook's stdio so a slow command never holds the
        # agent's hook pipe open.
        AGENT_NAME="$agent" AGENT_STATE="$state" \
        AGENT_SESSION="$session_name" AGENT_WINDOW="$window_name" \
        bash -c "$ext_cmd" </dev/null >/dev/null 2>&1 &
    fi
}

# Pane background for a state. '' leaves the background untouched, 'default'
# resets it; the focused pane is never tinted.
apply_state_background() {
    local bg
    if [ "$pane_id" = "$active_pane_id" ]; then
        return
    fi
    if ! is_enabled "$background_enabled"; then
        reset_pane_style "$pane_id"
        return
    fi
    bg=$(state_option "$state" bg)
    if [ -z "$bg" ]; then
        :
    elif [ "$bg" = "default" ]; then
        reset_pane_style "$pane_id"
    else
        apply_pane_style "$pane_id" "$bg"
    fi
}

# Record which window-wide styling this pane asks for; window_refresh_styles
# turns the contributions of all panes into the actual window options.
# Border: '' keeps the pane's previous contribution, 'default' drops it.
# Title: only while the pane's window is not the active one and both colours
# are set.
record_state_contributions() {
    local border title_bg title_fg
    local title_key="TMUX_AGENT_PANE_${pane_id}_TITLE"
    local border_key="TMUX_AGENT_PANE_${pane_id}_BORDER"

    title_bg=$(state_option "$state" window-title-bg)
    title_fg=$(state_option "$state" window-title-fg)
    if [ "$window_id" != "$active_window_id" ] && [ -n "$title_bg" ] && [ -n "$title_fg" ]; then
        tmux_set_env "$title_key" "$state"
    else
        tmux_unset_env "$title_key"
    fi

    if ! is_enabled "$border_enabled"; then
        tmux_unset_env "$border_key"
        return
    fi
    border=$(state_option "$state" border)
    if [ -z "$border" ]; then
        :
    elif [ "$border" = "default" ]; then
        tmux_unset_env "$border_key"
    else
        tmux_set_env "$border_key" "$state"
    fi
}

refresh_pane_windows() {
    window_refresh_styles "$window_id"
    if [ -n "$previous_window_id" ] && [ "$previous_window_id" != "$window_id" ]; then
        window_refresh_styles "$previous_window_id"
    fi
}

enter_state() {
    local previous_state="${AGENT_ENV[$state_key]:-}"
    local previous_pending="${AGENT_ENV[$pending_reset_key]:-}"

    if [ "$state" = "running" ]; then
        # Clean slate for a new turn: the user may have answered from this
        # very pane, so no focus hook cleared the done/needs-input visuals.
        case "$previous_state" in
            done|needs-input) reset_pane_style "$pane_id" ;;
            *) [ "$previous_pending" != "1" ] || reset_pane_style "$pane_id" ;;
        esac
        clear_pane_keys "$pane_id" TITLE BORDER
    fi

    tmux_set_envs "$state_key" "$state" "$agent_key" "$agent" "$window_key" "$window_id" \
        "TMUX_AGENT_ACTIVE_PANE_${agent}" "$pane_id"
    if [ "$state" = "done" ]; then
        tmux_set_envs "$done_key" "1" "$done_window_key" "$window_id"
    else
        clear_pane_keys "$pane_id" DONE DONE_WINDOW PENDING_RESET
    fi

    apply_state_background
    record_state_contributions

    if [ "$state" = "done" ]; then
        if is_enabled "$reset_on_focus"; then
            tmux_set_env "$pending_reset_key" "1"
        else
            reset_pane_style "$pane_id"
            clear_pane_keys "$pane_id"
        fi
    fi

    refresh_pane_windows
    if [ "$state" = "running" ]; then
        start_animation
    else
        stop_animation_if_idle
    fi
    notify_state_change "$agent" "$state" "$pane_id"
}

leave_state() {
    clear_pane_keys "$pane_id"
    tmux_unset_envs "TMUX_AGENT_ACTIVE_PANE_${agent}"
    reset_pane_style "$pane_id"
    refresh_pane_windows
    stop_animation_if_idle
}

agent=""
state=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --agent)
            [ "$#" -lt 2 ] && usage && exit 1
            agent="$2"
            shift 2
            ;;
        --state)
            [ "$#" -lt 2 ] && usage && exit 1
            state="$2"
            shift 2
            ;;
        *)
            usage
            exit 1
            ;;
    esac
done

if [ -z "$agent" ] || [ -z "$state" ]; then
    usage
    exit 1
fi

case "$state" in
    running|needs-input|done|off) ;;
    *)
        usage
        exit 1
        ;;
esac

# Hooks must never hang the agent, e.g. on a stalled connection.
with_timeout() {
    if command -v timeout >/dev/null 2>&1; then
        timeout 3 "$@"
    else
        "$@"
    fi
}

# On a host reached through agent-ssh.sh, send the state to the client's pane.
# Inside tmux on that host, the session environment holds the socket of the
# connection that attached last (with LC_TMUX_AGENT_SOCKET in
# update-environment), which outlives the pane's own copy after a reconnect.
# Runs before state-lib.sh is sourced: hosts without tmux may only have bash 3.
forward_to_ssh_client() {
    local socket="${LC_TMUX_AGENT_SOCKET:-}" session_value message
    [ -n "$socket" ] || return 0
    if [ -n "${TMUX:-}" ] && [ -n "${TMUX_PANE:-}" ]; then
        session_value=$(tmux show-environment -t "$TMUX_PANE" LC_TMUX_AGENT_SOCKET 2>/dev/null || true)
        case "$session_value" in
            LC_TMUX_AGENT_SOCKET=*) socket="${session_value#*=}" ;;
            -LC_TMUX_AGENT_SOCKET) socket="" ;;
        esac
    fi
    [ -S "$socket" ] || return 0

    message="$agent $state"
    if command -v socat >/dev/null 2>&1; then
        printf '%s\n' "$message" | with_timeout socat -u - "UNIX-CONNECT:$socket" >/dev/null 2>&1 || true
    elif command -v python3 >/dev/null 2>&1; then
        with_timeout python3 -c '
import socket, sys
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.settimeout(3)
s.connect(sys.argv[1])
s.sendall((sys.argv[2] + "\n").encode())
s.close()
' "$socket" "$message" >/dev/null 2>&1 || true
    elif command -v nc >/dev/null 2>&1; then
        printf '%s\n' "$message" | with_timeout nc -w 3 -U "$socket" >/dev/null 2>&1 || true
    fi
}

forward_to_ssh_client

if ! command -v tmux >/dev/null 2>&1 || [ -z "${TMUX:-}" ]; then
    exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/state-lib.sh
source "$SCRIPT_DIR/state-lib.sh"

agent_env_load

# Fast path: per-tool-call hooks (PostToolUse) report running repeatedly.
# Nothing changes when the pane already runs this agent.
if [ "$state" = "running" ] && [ -n "${TMUX_PANE:-}" ] \
    && [ "${AGENT_ENV[TMUX_AGENT_PANE_${TMUX_PANE}_STATE]:-}" = "running" ] \
    && [ "${AGENT_ENV[TMUX_AGENT_PANE_${TMUX_PANE}_AGENT]:-}" = "$agent" ]; then
    exit 0
fi

live_panes_load
pane_id=$(resolve_target_pane "$agent")
[ -n "$pane_id" ] || exit 0
window_id=""
pane_session=""
read -r window_id pane_session < <(tmux display-message -p -t "$pane_id" '#{window_id} #{session_name}' 2>/dev/null) || true
[ -n "$window_id" ] || exit 0
active_window_id=""
active_pane_id=""
read -r active_window_id active_pane_id < <(tmux display-message -p '#{window_id} #{pane_id}' 2>/dev/null) || true

# Clear session-dots seen marker so new attention is visible
if [ -n "$pane_session" ]; then
    tmux_unset_env "TMUX_AGENT_SESSION_SEEN_${pane_session}"
fi

background_enabled=$(tmux_get_option_or_default "@agent-indicator-background-enabled" "on")
border_enabled=$(tmux_get_option_or_default "@agent-indicator-border-enabled" "on")
reset_on_focus=$(tmux_get_option_or_default "@agent-indicator-reset-on-focus" "on")

state_key="TMUX_AGENT_PANE_${pane_id}_STATE"
agent_key="TMUX_AGENT_PANE_${pane_id}_AGENT"
window_key="TMUX_AGENT_PANE_${pane_id}_WINDOW"
done_key="TMUX_AGENT_PANE_${pane_id}_DONE"
done_window_key="TMUX_AGENT_PANE_${pane_id}_DONE_WINDOW"
pending_reset_key="TMUX_AGENT_PANE_${pane_id}_PENDING_RESET"
previous_window_id="${AGENT_ENV[$window_key]:-}"

if [ "$state" != "off" ]; then
    state_enabled=$(tmux_get_option_or_default "@agent-indicator-${state}-enabled" "on")
    if ! is_enabled "$state_enabled"; then
        state="off"
    fi
fi

if [ "$state" = "off" ]; then
    leave_state
else
    enter_state
fi

tmux refresh-client -S >/dev/null 2>&1 || true
