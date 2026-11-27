#!/usr/bin/env bash
# Shared helpers for tmux-agent-indicator state scripts. Source it; it has no
# side effects of its own.
#
# Per-pane state lives in global tmux environment variables
# TMUX_AGENT_PANE_<pane_id>_<suffix>:
#   STATE, AGENT        hook-reported state and agent name
#   WINDOW              window the pane was in when its state last changed
#   DONE, DONE_WINDOW   done marker and the window it was reported in
#   PENDING_RESET       pane background/border reset deferred until focus
#   TITLE, BORDER       state whose window-title / active-border styling the
#                       pane currently asks for (its "contribution")
# Window-wide options are shared by every pane of a window, so they are
# recomputed from the contributions of all live panes (window_refresh_styles)
# instead of being set and cleared by whichever pane changed last.

PANE_KEY_SUFFIXES=(STATE AGENT WINDOW DONE DONE_WINDOW PENDING_RESET TITLE BORDER)
WINDOW_OPTION_UNSET_MARKER="__UNSET__"

declare -gA AGENT_ENV=()
declare -gA LIVE_PANES=()

# An option set to '' is returned as '' (callers treat that as "skip"); only an
# unset option falls back to the default. One tmux call: `show-option -v`
# prints nothing for an unset option and a line (possibly empty) otherwise.
tmux_get_option_or_default() {
    local option="$1"
    local default_value="$2"
    local raw
    raw=$(tmux show-option -gqv "$option" 2>/dev/null || true; printf '.')
    if [ "$raw" = "." ]; then
        printf '%s\n' "$default_value"
    else
        raw="${raw%.}"
        printf '%s\n' "${raw%$'\n'}"
    fi
}

tmux_get_env() {
    local line
    line=$(tmux show-environment -g "$1" 2>/dev/null || true)
    case "$line" in
        *=*) printf '%s\n' "${line#*=}" ;;
    esac
}

tmux_set_env() {
    tmux set-environment -g "$1" "$2" 2>/dev/null || true
}

tmux_unset_env() {
    tmux set-environment -gu "$1" 2>/dev/null || true
}

# Batched variants: one tmux invocation (commands chained with ';') for many
# keys. They also keep the AGENT_ENV snapshot in sync.
tmux_set_envs() {
    local args=()
    while [ "$#" -ge 2 ]; do
        [ "${#args[@]}" -eq 0 ] || args+=(";")
        args+=(set-environment -g "$1" "$2")
        AGENT_ENV["$1"]="$2"
        shift 2
    done
    [ "${#args[@]}" -eq 0 ] || tmux "${args[@]}" 2>/dev/null || true
}

tmux_unset_envs() {
    local args=() key
    for key in "$@"; do
        [ "${#args[@]}" -eq 0 ] || args+=(";")
        args+=(set-environment -gu "$key")
        unset 'AGENT_ENV[$key]'
    done
    [ "${#args[@]}" -eq 0 ] || tmux "${args[@]}" 2>/dev/null || true
}

is_enabled() {
    case "$1" in
        on|true|yes|1) return 0 ;;
        *) return 1 ;;
    esac
}

# --- State defaults (single source for every script) ------------------------

default_state_bg() {
    printf 'default\n'
}

default_state_border() {
    case "$1" in
        needs-input) printf 'yellow\n' ;;
        done) printf 'green\n' ;;
        *) printf 'default\n' ;;
    esac
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
        needs-input|done) printf 'black\n' ;;
        *) printf '\n' ;;
    esac
}

# state_option <state> <bg|border|window-title-bg|window-title-fg>
state_option() {
    local state="$1"
    local property="$2"
    local default_value
    case "$property" in
        bg) default_value=$(default_state_bg "$state") ;;
        border) default_value=$(default_state_border "$state") ;;
        window-title-bg) default_value=$(default_state_title_bg "$state") ;;
        window-title-fg) default_value=$(default_state_title_fg "$state") ;;
        *) default_value="" ;;
    esac
    tmux_get_option_or_default "@agent-indicator-${state}-${property}" "$default_value"
}

# Urgency used when several panes compete for shared styling.
state_rank() {
    case "$1" in
        needs-input) printf '3\n' ;;
        done) printf '2\n' ;;
        running) printf '1\n' ;;
        *) printf '0\n' ;;
    esac
}

state_more_urgent() {
    [ "$(state_rank "$1")" -gt "$(state_rank "$2")" ]
}

# --- Snapshots ---------------------------------------------------------------

# Load every TMUX_AGENT_* global environment variable into AGENT_ENV.
agent_env_load() {
    AGENT_ENV=()
    local line
    while IFS= read -r line; do
        case "$line" in
            TMUX_AGENT_*=*) AGENT_ENV["${line%%=*}"]="${line#*=}" ;;
        esac
    done < <(tmux show-environment -g 2>/dev/null || true)
}

# Load the ids of panes that exist and whose process has not exited.
live_panes_load() {
    LIVE_PANES=()
    local pane dead
    while read -r pane dead; do
        if [ -n "$pane" ] && [ "$dead" != "1" ]; then
            LIVE_PANES["$pane"]=1
        fi
    done < <(tmux list-panes -a -F '#{pane_id} #{pane_dead}' 2>/dev/null || true)
}

# Requires live_panes_load.
pane_is_live() {
    [ -n "$1" ] && [ -n "${LIVE_PANES[$1]:-}" ]
}

# Pane id from a TMUX_AGENT_PANE_<pane_id>_<suffix> key.
pane_from_key() {
    local rest="${1#TMUX_AGENT_PANE_}"
    printf '%s\n' "${rest%%_*}"
}

# clear_pane_keys <pane_id> [suffix...]; all per-pane keys by default.
clear_pane_keys() {
    local pane_id="$1"
    shift
    local suffix keys=()
    [ "$#" -gt 0 ] || set -- "${PANE_KEY_SUFFIXES[@]}"
    for suffix in "$@"; do
        keys+=("TMUX_AGENT_PANE_${pane_id}_${suffix}")
    done
    tmux_unset_envs "${keys[@]}"
}

reset_pane_style() {
    tmux set-option -p -t "$1" window-style "bg=default" 2>/dev/null || true
}

# --- Window-wide styling -----------------------------------------------------

# The original-value bookkeeping below reads the AGENT_ENV snapshot (see
# window_refresh_styles) and keeps it in sync with what it writes.
save_window_option_once() {
    local window_id="$1"
    local option="$2"
    local env_key="$3"
    local saved

    if [ -n "${AGENT_ENV[$env_key]:-}" ]; then
        return 0
    fi
    # Window-local value only (no inheritance); empty means "not set locally".
    saved=$(tmux show-options -wqv -t "$window_id" "$option" 2>/dev/null || true)
    saved="${saved:-$WINDOW_OPTION_UNSET_MARKER}"
    tmux_set_env "$env_key" "$saved"
    AGENT_ENV["$env_key"]="$saved"
}

restore_window_option() {
    local window_id="$1"
    local option="$2"
    local env_key="$3"
    local saved="${AGENT_ENV[$env_key]:-}"

    if [ -z "$saved" ]; then
        return 0
    fi
    if [ "$saved" = "$WINDOW_OPTION_UNSET_MARKER" ]; then
        tmux set-option -wq -t "$window_id" -u "$option" 2>/dev/null || true
    else
        tmux set-option -wq -t "$window_id" "$option" "$saved" 2>/dev/null || true
    fi
    tmux_unset_env "$env_key"
    unset 'AGENT_ENV[$env_key]'
}

set_window_option_saved() {
    local window_id="$1"
    local option="$2"
    local env_key="$3"
    local value="$4"
    save_window_option_once "$window_id" "$option" "$env_key"
    tmux set-option -wq -t "$window_id" "$option" "$value" 2>/dev/null || true
}

# Recompute window-status-style, window-status-current-style and
# pane-active-border-style of a window from the TITLE/BORDER contributions of
# its live panes: the most urgent contribution wins; once no pane contributes,
# the value the window had before the plugin touched it is restored.
window_refresh_styles() {
    local window_id="$1"
    [ -n "$window_id" ] || return 0

    local status_key="TMUX_AGENT_WINDOW_${window_id}_ORIG_STATUS_STYLE"
    local current_key="TMUX_AGENT_WINDOW_${window_id}_ORIG_STATUS_CURRENT_STYLE"
    local border_key="TMUX_AGENT_WINDOW_${window_id}_ORIG_ACTIVE_BORDER_STYLE"
    local pane dead contribution title_state="" border_state=""
    local title_bg="" title_fg="" border=""

    agent_env_load
    while read -r pane dead; do
        [ -n "$pane" ] && [ "$dead" != "1" ] || continue
        contribution="${AGENT_ENV[TMUX_AGENT_PANE_${pane}_TITLE]:-}"
        if [ -n "$contribution" ] && state_more_urgent "$contribution" "$title_state"; then
            title_state="$contribution"
        fi
        contribution="${AGENT_ENV[TMUX_AGENT_PANE_${pane}_BORDER]:-}"
        if [ -n "$contribution" ] && state_more_urgent "$contribution" "$border_state"; then
            border_state="$contribution"
        fi
    done < <(tmux list-panes -t "$window_id" -F '#{pane_id} #{pane_dead}' 2>/dev/null || true)

    if [ -n "$title_state" ]; then
        title_bg=$(state_option "$title_state" window-title-bg)
        title_fg=$(state_option "$title_state" window-title-fg)
    fi
    if [ -n "$title_bg" ] && [ -n "$title_fg" ]; then
        set_window_option_saved "$window_id" window-status-style "$status_key" "bg=$title_bg,fg=$title_fg"
        set_window_option_saved "$window_id" window-status-current-style "$current_key" "bg=$title_bg,fg=$title_fg"
    else
        restore_window_option "$window_id" window-status-style "$status_key"
        restore_window_option "$window_id" window-status-current-style "$current_key"
    fi

    if [ -n "$border_state" ] && is_enabled "$(tmux_get_option_or_default "@agent-indicator-border-enabled" "on")"; then
        border=$(state_option "$border_state" border)
    fi
    if [ -n "$border" ] && [ "$border" != "default" ]; then
        set_window_option_saved "$window_id" pane-active-border-style "$border_key" "fg=$border,bold"
    else
        restore_window_option "$window_id" pane-active-border-style "$border_key"
    fi
}

# --- Liveness, pruning, animation -------------------------------------------

# True when a pane that still exists is in the running state.
any_live_pane_running() {
    local key
    agent_env_load
    live_panes_load
    for key in "${!AGENT_ENV[@]}"; do
        case "$key" in
            TMUX_AGENT_PANE_*_STATE) ;;
            *) continue ;;
        esac
        [ "${AGENT_ENV[$key]}" = "running" ] || continue
        if pane_is_live "$(pane_from_key "$key")"; then
            return 0
        fi
    done
    return 1
}

# Drop state of panes that were closed (or whose process exited), drop keys of
# windows that no longer exist, and recompute the styling of windows that lost
# a pane. Idempotent; registered on pane/window exit hooks.
prune_dead_panes() {
    local key pane window
    local stale_keys=()
    local -A affected_windows=()
    local -A live_windows=()

    live_panes_load
    # No panes at all means the server is unreachable or exiting: keep state.
    [ "${#LIVE_PANES[@]}" -gt 0 ] || return 0
    while read -r window; do
        if [ -n "$window" ]; then
            live_windows["$window"]=1
        fi
    done < <(tmux list-windows -a -F '#{window_id}' 2>/dev/null || true)

    agent_env_load
    for key in "${!AGENT_ENV[@]}"; do
        case "$key" in
            TMUX_AGENT_PANE_*)
                pane=$(pane_from_key "$key")
                ! pane_is_live "$pane" || continue
                case "$key" in
                    *_WINDOW)
                        window="${AGENT_ENV[$key]}"
                        if [ -n "$window" ]; then
                            affected_windows["$window"]=1
                        fi
                        ;;
                esac
                stale_keys+=("$key")
                ;;
            TMUX_AGENT_ACTIVE_PANE_*)
                pane_is_live "${AGENT_ENV[$key]}" || stale_keys+=("$key")
                ;;
            TMUX_AGENT_WINDOW_*)
                window="${key#TMUX_AGENT_WINDOW_}"
                window="${window%%_*}"
                if [ -z "$window" ] || [ -z "${live_windows[$window]:-}" ]; then
                    stale_keys+=("$key")
                fi
                ;;
        esac
    done
    [ "${#stale_keys[@]}" -eq 0 ] || tmux_unset_envs "${stale_keys[@]}"

    for window in "${!affected_windows[@]}"; do
        if [ -n "${live_windows[$window]:-}" ]; then
            window_refresh_styles "$window"
        fi
    done
}

stop_animation() {
    local pid
    pid=$(tmux_get_env "TMUX_AGENT_ANIMATION_PID")
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null || true
    fi
    tmux_unset_envs "TMUX_AGENT_ANIMATION_PID" "TMUX_AGENT_ANIMATION_FRAME"
}

# The animation is global; keep it while any live pane is still running.
stop_animation_if_idle() {
    if [ -z "$(tmux_get_env "TMUX_AGENT_ANIMATION_PID")" ]; then
        return 0
    fi
    if ! any_live_pane_running; then
        stop_animation
    fi
}
