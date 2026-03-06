#!/usr/bin/env bash
# Set pane/window state for an AI agent.

set -euo pipefail

usage() {
    cat <<'EOF' >&2
Usage: agent-state.sh --agent <name> --state <running|needs-input|done|off>
EOF
}

if ! command -v tmux >/dev/null 2>&1 || [ -z "${TMUX:-}" ]; then
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

tmux_get_env() {
    local key="$1"
    tmux show-environment -g "$key" 2>/dev/null | sed 's/^[^=]*=//' || true
}

tmux_set_env() {
    tmux set-environment -g "$1" "$2"
}

tmux_unset_env() {
    tmux set-environment -gu "$1" 2>/dev/null || true
}

is_enabled() {
    case "$1" in
        on|true|yes|1) return 0 ;;
        *) return 1 ;;
    esac
}

default_state_bg() {
    case "$1" in
        running) printf 'default\n' ;;
        needs-input) printf 'default\n' ;;
        done) printf 'default\n' ;;
        *) printf 'default\n' ;;
    esac
}

default_state_border() {
    case "$1" in
        running) printf 'default\n' ;;
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
        needs-input) printf 'black\n' ;;
        done) printf 'black\n' ;;
        *) printf '\n' ;;
    esac
}

save_window_option_once() {
    local window_id="$1"
    local option="$2"
    local env_key="$3"
    local marker="__UNSET__"
    local existing saved

    existing=$(tmux_get_env "$env_key")
    if [ -n "$existing" ]; then
        return
    fi

    saved=$(tmux show-window-option -qvt "$window_id" "$option" 2>/dev/null || true)
    if [ -z "$saved" ]; then
        tmux_set_env "$env_key" "$marker"
    else
        tmux_set_env "$env_key" "$saved"
    fi
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

apply_window_title_style() {
    local window_id="$1"
    local bg="$2"
    local fg="$3"
    local mark_done="${4:-}"
    local status_key="TMUX_AGENT_WINDOW_${window_id}_ORIG_STATUS_STYLE"
    local current_key="TMUX_AGENT_WINDOW_${window_id}_ORIG_STATUS_CURRENT_STYLE"
    local done_key="TMUX_AGENT_WINDOW_${window_id}_DONE"

    if [ -z "$bg" ] || [ -z "$fg" ]; then
        return
    fi

    save_window_option_once "$window_id" "window-status-style" "$status_key"
    save_window_option_once "$window_id" "window-status-current-style" "$current_key"
    tmux set-window-option -qt "$window_id" window-status-style "bg=$bg,fg=$fg"
    tmux set-window-option -qt "$window_id" window-status-current-style "bg=$bg,fg=$fg"
    if [ "$mark_done" = "done" ]; then
        tmux_set_env "$done_key" "1"
    fi
}

clear_window_title_style() {
    local window_id="$1"
    [ -z "$window_id" ] && return
    local status_key="TMUX_AGENT_WINDOW_${window_id}_ORIG_STATUS_STYLE"
    local current_key="TMUX_AGENT_WINDOW_${window_id}_ORIG_STATUS_CURRENT_STYLE"
    local done_key="TMUX_AGENT_WINDOW_${window_id}_DONE"

    restore_window_option "$window_id" "window-status-style" "$status_key"
    restore_window_option "$window_id" "window-status-current-style" "$current_key"
    tmux_unset_env "$done_key"
}

# --- Window-name icon functions ------------------------------------------------

# All known icon characters used for stripping suffixes.
DEFAULT_NEEDS_INPUT_ICON=""
DEFAULT_DONE_ICON=""

get_highest_urgency_icon() {
    local window_id="$1"
    local needs_input_icon="$2"
    local done_icon="$3"
    local has_needs_input=0
    local has_done=0
    local line pane_candidate pane_state

    while IFS= read -r line; do
        [ -z "$line" ] && continue
        pane_candidate="${line#TMUX_AGENT_PANE_}"
        pane_candidate="${pane_candidate%%_STATE=*}"
        # Check this pane belongs to the target window.
        local pane_window
        pane_window=$(tmux display-message -p -t "$pane_candidate" '#{window_id}' 2>/dev/null || true)
        [ "$pane_window" != "$window_id" ] && continue
        pane_state="${line#*_STATE=}"
        case "$pane_state" in
            needs-input) has_needs_input=1 ;;
            done) has_done=1 ;;
        esac
    done < <(tmux show-environment -g 2>/dev/null | grep "^TMUX_AGENT_PANE_.*_STATE=" || true)

    if [ "$has_needs_input" = "1" ]; then
        printf '%s\n' "$needs_input_icon"
    elif [ "$has_done" = "1" ]; then
        printf '%s\n' "$done_icon"
    fi
}

apply_window_name_icon() {
    local window_id="$1"
    # $2 (icon hint) is unused; multi-pane scan determines the winning icon.

    local wn_enabled
    wn_enabled=$(tmux_get_option_or_default "@agent-indicator-window-name-enabled" "on")
    if ! is_enabled "$wn_enabled"; then
        return
    fi

    local needs_input_icon done_icon
    needs_input_icon=$(tmux_get_option_or_default "@agent-indicator-needs-input-icon" "$DEFAULT_NEEDS_INPUT_ICON")
    done_icon=$(tmux_get_option_or_default "@agent-indicator-done-icon" "$DEFAULT_DONE_ICON")

    # Multi-pane scan: pick highest-urgency icon across all panes in this window.
    local winning_icon
    winning_icon=$(get_highest_urgency_icon "$window_id" "$needs_input_icon" "$done_icon")

    # If no pane has an icon-worthy state, clear instead.
    if [ -z "$winning_icon" ]; then
        clear_window_name_icon "$window_id"
        return
    fi

    local current_name base_name
    current_name=$(tmux display-message -p -t "$window_id" '#{window_name}')

    # Strip any existing icon suffix (space + known icon at end).
    base_name="$current_name"
    base_name="${base_name% "${needs_input_icon}"}"
    base_name="${base_name% "${done_icon}"}"

    local orig_key="TMUX_AGENT_WINDOW_${window_id}_ORIG_NAME"
    local auto_rename_key="TMUX_AGENT_WINDOW_${window_id}_ORIG_AUTOMATIC_RENAME"
    local existing_orig
    existing_orig=$(tmux_get_env "$orig_key")

    # Save original name only once.
    if [ -z "$existing_orig" ]; then
        tmux_set_env "$orig_key" "$base_name"
    else
        base_name="$existing_orig"
    fi

    # Save and disable automatic-rename.
    local existing_auto
    existing_auto=$(tmux_get_env "$auto_rename_key")
    if [ -z "$existing_auto" ]; then
        local auto_val
        auto_val=$(tmux show-window-option -qvt "$window_id" "automatic-rename" 2>/dev/null || true)
        if [ -z "$auto_val" ]; then
            tmux_set_env "$auto_rename_key" "__UNSET__"
        else
            tmux_set_env "$auto_rename_key" "$auto_val"
        fi
    fi
    tmux set-window-option -t "$window_id" automatic-rename off 2>/dev/null || true

    tmux rename-window -t "$window_id" "${base_name} ${winning_icon}" 2>/dev/null || true
}

clear_window_name_icon() {
    local window_id="$1"

    local orig_key="TMUX_AGENT_WINDOW_${window_id}_ORIG_NAME"
    local auto_rename_key="TMUX_AGENT_WINDOW_${window_id}_ORIG_AUTOMATIC_RENAME"
    local marker="__UNSET__"

    local orig_name
    orig_name=$(tmux_get_env "$orig_key")
    if [ -z "$orig_name" ]; then
        return
    fi

    local wn_enabled
    wn_enabled=$(tmux_get_option_or_default "@agent-indicator-window-name-enabled" "on")

    local needs_input_icon done_icon
    needs_input_icon=$(tmux_get_option_or_default "@agent-indicator-needs-input-icon" "$DEFAULT_NEEDS_INPUT_ICON")
    done_icon=$(tmux_get_option_or_default "@agent-indicator-done-icon" "$DEFAULT_DONE_ICON")

    # Multi-pane scan: if another pane still has an icon-worthy state, re-apply instead.
    if is_enabled "$wn_enabled"; then
        local winning_icon
        winning_icon=$(get_highest_urgency_icon "$window_id" "$needs_input_icon" "$done_icon")
        if [ -n "$winning_icon" ]; then
            tmux rename-window -t "$window_id" "${orig_name} ${winning_icon}" 2>/dev/null || true
            return
        fi
    fi

    # Restore original name.
    tmux rename-window -t "$window_id" "$orig_name" 2>/dev/null || true

    # Restore automatic-rename.
    local saved_auto
    saved_auto=$(tmux_get_env "$auto_rename_key")
    if [ -n "$saved_auto" ]; then
        if [ "$saved_auto" = "$marker" ]; then
            tmux set-window-option -t "$window_id" -u automatic-rename 2>/dev/null || true
        else
            tmux set-window-option -t "$window_id" automatic-rename "$saved_auto" 2>/dev/null || true
        fi
    fi

    tmux_unset_env "$orig_key"
    tmux_unset_env "$auto_rename_key"
}

# --- Border style functions ---------------------------------------------------

apply_active_border_style() {
    local window_id="$1"
    local border="$2"
    local orig_key="TMUX_AGENT_WINDOW_${window_id}_ORIG_ACTIVE_BORDER_STYLE"
    save_window_option_once "$window_id" "pane-active-border-style" "$orig_key"
    tmux set-window-option -qt "$window_id" pane-active-border-style "fg=$border,bold"
}

restore_active_border_style() {
    local window_id="$1"
    local orig_key="TMUX_AGENT_WINDOW_${window_id}_ORIG_ACTIVE_BORDER_STYLE"
    restore_window_option "$window_id" "pane-active-border-style" "$orig_key"
}

reset_pane_style() {
    local pane_id="$1"
    local active
    active=$(tmux display-message -p '#{pane_id}')
    tmux select-pane -t "$pane_id" -P "bg=default"
    if [ "$pane_id" != "$active" ]; then
        tmux select-pane -t "$active"
    fi
}

apply_pane_style() {
    local pane_id="$1"
    local bg="$2"
    local active
    active=$(tmux display-message -p '#{pane_id}')
    tmux select-pane -t "$pane_id" -P "bg=$bg"
    if [ "$pane_id" != "$active" ]; then
        tmux select-pane -t "$active"
    fi
}

pane_exists() {
    local pane_id="$1"
    [ -n "$pane_id" ] || return 1
    tmux display-message -p -t "$pane_id" '#{pane_id}' >/dev/null 2>&1
}

start_animation() {
    local anim_enabled
    anim_enabled=$(tmux_get_option_or_default "@agent-indicator-animation-enabled" "off")
    if ! is_enabled "$anim_enabled"; then
        return
    fi

    # Check if animation process is already alive.
    local existing_pid
    existing_pid=$(tmux_get_env "TMUX_AGENT_ANIMATION_PID")
    if [ -n "$existing_pid" ] && kill -0 "$existing_pid" 2>/dev/null; then
        return
    fi

    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    nohup bash "$script_dir/animation.sh" >/dev/null 2>&1 &
    disown
}

stop_animation() {
    local pid
    pid=$(tmux_get_env "TMUX_AGENT_ANIMATION_PID")
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null || true
    fi
    tmux set-environment -gu TMUX_AGENT_ANIMATION_PID 2>/dev/null || true
    tmux set-environment -gu TMUX_AGENT_ANIMATION_FRAME 2>/dev/null || true
}

resolve_target_pane() {
    local agent="$1"
    local pane=""
    local agent_active_key="TMUX_AGENT_ACTIVE_PANE_${agent}"
    local mapped_pane
    local running_candidate=""
    local done_candidate=""
    local line pane_candidate state_candidate

    if [ -n "${TMUX_PANE:-}" ] && pane_exists "$TMUX_PANE"; then
        pane="$TMUX_PANE"
    fi

    if [ -z "$pane" ]; then
        while IFS= read -r line; do
            [ -z "$line" ] && continue
            pane_candidate="${line#TMUX_AGENT_PANE_}"
            pane_candidate="${pane_candidate%%_AGENT=*}"
            if ! pane_exists "$pane_candidate"; then
                continue
            fi
            state_candidate=$(tmux_get_env "TMUX_AGENT_PANE_${pane_candidate}_STATE")
            case "$state_candidate" in
                running|needs-input)
                    running_candidate="$pane_candidate"
                    break
                    ;;
                done)
                    if [ -z "$done_candidate" ]; then
                        done_candidate="$pane_candidate"
                    fi
                    ;;
            esac
        done < <(tmux show-environment -g | rg "^TMUX_AGENT_PANE_.*_AGENT=${agent}$" || true)

        if [ -n "$running_candidate" ]; then
            pane="$running_candidate"
        elif [ -n "$done_candidate" ]; then
            pane="$done_candidate"
        fi
    fi

    if [ -z "$pane" ]; then
        mapped_pane=$(tmux_get_env "$agent_active_key")
        if pane_exists "$mapped_pane"; then
            pane="$mapped_pane"
        fi
    fi

    if [ -z "$pane" ]; then
        pane=$(tmux display-message -p '#{pane_id}')
    fi

    printf '%s\n' "$pane"
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

    local session_name window_name window_index
    session_name=$(tmux display-message -p -t "$pane_id" '#S')
    window_name=$(tmux display-message -p -t "$pane_id" '#W')
    window_index=$(tmux display-message -p -t "$pane_id" '#I')

    local message="$fmt"
    message="${message//\#\{agent_name\}/$agent}"
    message="${message//\#\{agent_state\}/$state}"
    message="${message//\#\{session_name\}/$session_name}"
    message="${message//\#\{window_name\}/$window_name}"
    message="${message//\#\{window_index\}/$window_index}"

    if [ -n "$duration" ] && [ "$duration" != "0" ]; then
        tmux display-message -d "$duration" "$message" || true
    else
        tmux display-message "$message" || true
    fi

    local ext_cmd
    ext_cmd=$(tmux_get_option_or_default "@agent-indicator-notification-command" "")
    if [ -n "$ext_cmd" ]; then
        AGENT_NAME="$agent" AGENT_STATE="$state" \
        AGENT_SESSION="$session_name" AGENT_WINDOW="$window_name" \
        bash -c "$ext_cmd" 2>/dev/null &
    fi
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

pane_id=$(resolve_target_pane "$agent")
window_id=$(tmux display-message -p -t "$pane_id" '#{window_id}')
active_window_id=$(tmux display-message -p '#{window_id}')
active_pane_id=$(tmux display-message -p '#{pane_id}')

background_enabled=$(tmux_get_option_or_default "@agent-indicator-background-enabled" "on")
border_enabled=$(tmux_get_option_or_default "@agent-indicator-border-enabled" "on")
reset_on_focus=$(tmux_get_option_or_default "@agent-indicator-reset-on-focus" "on")

state_key="TMUX_AGENT_PANE_${pane_id}_STATE"
agent_key="TMUX_AGENT_PANE_${pane_id}_AGENT"
done_key="TMUX_AGENT_PANE_${pane_id}_DONE"
done_window_key="TMUX_AGENT_PANE_${pane_id}_DONE_WINDOW"
pending_reset_key="TMUX_AGENT_PANE_${pane_id}_PENDING_RESET"

if [ "$state" != "off" ]; then
    state_enabled=$(tmux_get_option_or_default "@agent-indicator-${state}-enabled" "on")
    if ! is_enabled "$state_enabled"; then
        state="off"
    fi
fi

case "$state" in
    running|needs-input|done)
        state_bg=$(tmux_get_option_or_default "@agent-indicator-${state}-bg" "$(default_state_bg "$state")")
        state_border=$(tmux_get_option_or_default "@agent-indicator-${state}-border" "$(default_state_border "$state")")
        state_title_bg=$(tmux_get_option_or_default "@agent-indicator-${state}-window-title-bg" "$(default_state_title_bg "$state")")
        state_title_fg=$(tmux_get_option_or_default "@agent-indicator-${state}-window-title-fg" "$(default_state_title_fg "$state")")
        ;;
esac

case "$state" in
    running)
        clear_window_title_style "$window_id"
        tmux_unset_env "$done_key"
        tmux_unset_env "$done_window_key"
        tmux_unset_env "$pending_reset_key"
        tmux_set_env "$state_key" "$state"
        tmux_set_env "$agent_key" "$agent"
        tmux_set_env "TMUX_AGENT_ACTIVE_PANE_${agent}" "$pane_id"

        if [ "$pane_id" != "$active_pane_id" ]; then
            if is_enabled "$background_enabled"; then
                if [ -z "$state_bg" ]; then
                    :
                elif [ "$state_bg" = "default" ]; then
                    reset_pane_style "$pane_id"
                else
                    apply_pane_style "$pane_id" "$state_bg"
                fi
            else
                reset_pane_style "$pane_id"
            fi
        fi

        if is_enabled "$border_enabled"; then
            if [ -z "$state_border" ]; then
                :
            elif [ "$state_border" = "default" ]; then
                restore_active_border_style "$window_id"
            else
                apply_active_border_style "$window_id" "$state_border"
            fi
        else
            restore_active_border_style "$window_id"
        fi

        if [ "$window_id" != "$active_window_id" ]; then
            apply_window_title_style "$window_id" "$state_title_bg" "$state_title_fg"
        fi
        start_animation
        apply_window_name_icon "$window_id" ""
        notify_state_change "$agent" "$state" "$pane_id"
        ;;
    needs-input)
        stop_animation
        clear_window_title_style "$window_id"
        tmux_unset_env "$done_key"
        tmux_unset_env "$done_window_key"
        tmux_unset_env "$pending_reset_key"
        tmux_set_env "$state_key" "$state"
        tmux_set_env "$agent_key" "$agent"
        tmux_set_env "TMUX_AGENT_ACTIVE_PANE_${agent}" "$pane_id"

        if [ "$pane_id" != "$active_pane_id" ]; then
            if is_enabled "$background_enabled"; then
                if [ -z "$state_bg" ]; then
                    :
                elif [ "$state_bg" = "default" ]; then
                    reset_pane_style "$pane_id"
                else
                    apply_pane_style "$pane_id" "$state_bg"
                fi
            else
                reset_pane_style "$pane_id"
            fi
        fi

        if is_enabled "$border_enabled"; then
            if [ -z "$state_border" ]; then
                :
            elif [ "$state_border" = "default" ]; then
                restore_active_border_style "$window_id"
            else
                apply_active_border_style "$window_id" "$state_border"
            fi
        else
            restore_active_border_style "$window_id"
        fi

        if [ "$window_id" != "$active_window_id" ]; then
            apply_window_title_style "$window_id" "$state_title_bg" "$state_title_fg"
        fi
        apply_window_name_icon "$window_id" "$DEFAULT_NEEDS_INPUT_ICON"
        notify_state_change "$agent" "$state" "$pane_id"
        ;;
    done)
        stop_animation
        tmux_set_env "$state_key" "done"
        tmux_set_env "$agent_key" "$agent"
        tmux_set_env "$done_key" "1"
        tmux_set_env "$done_window_key" "$window_id"
        tmux_set_env "TMUX_AGENT_ACTIVE_PANE_${agent}" "$pane_id"

        if [ "$pane_id" != "$active_pane_id" ]; then
            if is_enabled "$background_enabled"; then
                if [ -z "$state_bg" ]; then
                    :
                elif [ "$state_bg" = "default" ]; then
                    reset_pane_style "$pane_id"
                else
                    apply_pane_style "$pane_id" "$state_bg"
                fi
            fi
        fi

        if is_enabled "$border_enabled"; then
            if [ -z "$state_border" ]; then
                :
            elif [ "$state_border" = "default" ]; then
                restore_active_border_style "$window_id"
            else
                apply_active_border_style "$window_id" "$state_border"
            fi
        fi

        if [ "$window_id" != "$active_window_id" ]; then
            apply_window_title_style "$window_id" "$state_title_bg" "$state_title_fg" "done"
        fi
        apply_window_name_icon "$window_id" "$DEFAULT_DONE_ICON"
        notify_state_change "$agent" "$state" "$pane_id"

        if is_enabled "$reset_on_focus"; then
            tmux_set_env "$pending_reset_key" "1"
        else
            tmux_unset_env "$pending_reset_key"
            reset_pane_style "$pane_id"
            restore_active_border_style "$window_id"
            clear_window_title_style "$window_id"
            clear_window_name_icon "$window_id"
            tmux_unset_env "$done_key"
            tmux_unset_env "$done_window_key"
            tmux_unset_env "$state_key"
            tmux_unset_env "$agent_key"
        fi
        ;;
    off)
        stop_animation
        clear_window_title_style "$window_id"
        tmux_unset_env "$done_key"
        tmux_unset_env "$done_window_key"
        tmux_unset_env "$pending_reset_key"
        tmux_unset_env "$state_key"
        tmux_unset_env "$agent_key"
        tmux_unset_env "TMUX_AGENT_ACTIVE_PANE_${agent}"
        reset_pane_style "$pane_id"
        restore_active_border_style "$window_id"
        clear_window_name_icon "$window_id"
        ;;
esac

tmux refresh-client -S >/dev/null 2>&1 || true
