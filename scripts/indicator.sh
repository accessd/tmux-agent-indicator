#!/usr/bin/env bash
# Status bar indicator - shows agent icon from pane state or process detection.

set -euo pipefail

# Check tmux availability and active server context
if ! command -v tmux >/dev/null 2>&1; then
    exit 0
fi
if ! tmux display-message -p '#{session_name}' >/dev/null 2>&1; then
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

trim() {
    local value="$1"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "$value"
}

icon_for_agent() {
    local agent="$1"
    local map="$2"
    local default_icon="🤖"

    IFS=',' read -r -a pairs <<< "$map"
    for pair in "${pairs[@]}"; do
        local raw_key raw_value key value
        raw_key="${pair%%=*}"
        raw_value="${pair#*=}"
        key=$(trim "$raw_key")
        value=$(trim "$raw_value")
        [ "$key" = "default" ] && default_icon="$value"
        if [ -n "$agent" ] && [ "$key" = "$agent" ] && [ -n "$value" ]; then
            printf '%s\n' "$value"
            return 0
        fi
    done

    printf '%s\n' "$default_icon"
}

is_animation_enabled() {
    case "$ANIMATION_ENABLED" in
        on|true|yes|1) return 0 ;;
        *) return 1 ;;
    esac
}

render_knight_rider() {
    local frame="$1"
    local bar_width=7
    local seg=""
    local bright="colour196"
    local trail="colour160"
    local dim="colour52"
    local i color

    for (( i = 0; i < bar_width; i++ )); do
        if [ "$i" -eq "$frame" ]; then
            color="$bright"
        elif [ "$i" -eq $((frame - 1)) ] || [ "$i" -eq $((frame + 1)) ]; then
            color="$trail"
        else
            color="$dim"
        fi
        seg="${seg}#[fg=${color}]━"
    done
    printf '%s#[default]' "$seg"
}

ICONS=$(tmux show-option -gqv "@agent-indicator-icons")
if tmux_option_is_set "@agent-indicator-icons" && [ -z "$ICONS" ]; then
    echo ""
    exit 0
fi
if ! tmux_option_is_set "@agent-indicator-icons" && [ -z "$ICONS" ]; then
    ICONS="claude=🤖,codex=🧠,opencode=💻,default=🤖"
fi
STATE_ICONS=$(tmux_get_option_or_default "@agent-indicator-state-icons" "")
PROCESSES=$(tmux_get_option_or_default "@agent-indicator-processes" "claude,codex,aider,cursor,opencode")
INDICATOR_ENABLED=$(tmux_get_option_or_default "@agent-indicator-indicator-enabled" "on")
ANIMATION_ENABLED=$(tmux_get_option_or_default "@agent-indicator-animation-enabled" "off")

case "$INDICATOR_ENABLED" in
    on|true|yes|1) ;;
    *)
        echo ""
        exit 0
        ;;
esac

# Get current pane
PANE_ID=$(tmux display-message -p '#{pane_id}')
PANE_TTY=$(tmux display-message -p '#{pane_tty}')
WINDOW_ID=$(tmux display-message -p '#{window_id}')
STATE=$(tmux_get_env "TMUX_AGENT_PANE_${PANE_ID}_STATE")
AGENT=$(tmux_get_env "TMUX_AGENT_PANE_${PANE_ID}_AGENT")

# Icon for a hook-reported state from @agent-indicator-state-icons
# (`running=…,needs-input=…,done=…`); fails when the state has none.
icon_for_state() {
    local state="$1"
    local pair key value
    IFS=',' read -r -a pairs <<< "$STATE_ICONS"
    for pair in "${pairs[@]}"; do
        key=$(trim "${pair%%=*}")
        value=$(trim "${pair#*=}")
        if [ "$key" = "$state" ] && [ -n "$value" ]; then
            printf '%s\n' "$value"
            return 0
        fi
    done
    return 1
}

output_indicator() {
    local state="$1"
    local agent="$2"
    local icon
    icon=$(icon_for_state "$state") || icon=$(icon_for_agent "$agent" "$ICONS")

    if [ "$state" = "running" ] && is_animation_enabled; then
        local frame
        frame=$(tmux_get_env "TMUX_AGENT_ANIMATION_FRAME")
        if [ -n "$frame" ]; then
            printf '%s %s\n' "$(render_knight_rider "$frame")" "$icon"
            return
        fi
    fi
    printf '%s\n' "$icon"
}

# Method 1: Pane state from hooks/scripts
if [ -n "$STATE" ] && [ "$STATE" != "off" ]; then
    output_indicator "$STATE" "$AGENT"
    exit 0
fi

# Method 2: Check other panes in current window
while IFS=' ' read -r other_pane _ other_active; do
    [ "$other_active" = "1" ] && continue
    other_state=$(tmux_get_env "TMUX_AGENT_PANE_${other_pane}_STATE")
    other_agent=$(tmux_get_env "TMUX_AGENT_PANE_${other_pane}_AGENT")
    if [ -n "$other_state" ] && [ "$other_state" != "off" ]; then
        output_indicator "$other_state" "$other_agent"
        exit 0
    fi
done < <(tmux list-panes -t "$WINDOW_ID" -F '#{pane_id} #{pane_tty} #{pane_active}')

# Method 3: Process detection fallback in current pane
if [ -n "$PANE_TTY" ]; then
    IFS=',' read -ra PROC_ARRAY <<< "$PROCESSES"
    for proc in "${PROC_ARRAY[@]}"; do
        proc=$(trim "$proc")
        [ -z "$proc" ] && continue
        # Check if process is running on this TTY
        if ps -t "$(basename "$PANE_TTY")" -o command= 2>/dev/null | grep -qw "$proc"; then
            icon_for_agent "$proc" "$ICONS"
            exit 0
        fi
    done
fi

# Method 4: Process detection in other panes of current window
while IFS=' ' read -r other_pane other_tty other_active; do
    [ "$other_active" = "1" ] && continue
    [ -n "$other_tty" ] || continue
    IFS=',' read -ra PROC_ARRAY <<< "$PROCESSES"
    for proc in "${PROC_ARRAY[@]}"; do
        proc=$(trim "$proc")
        [ -z "$proc" ] && continue
        if ps -t "$(basename "$other_tty")" -o command= 2>/dev/null | grep -qw "$proc"; then
            icon_for_agent "$proc" "$ICONS"
            exit 0
        fi
    done
done < <(tmux list-panes -t "$WINDOW_ID" -F '#{pane_id} #{pane_tty} #{pane_active}')

# No agent detected
echo ""
