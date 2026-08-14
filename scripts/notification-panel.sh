#!/usr/bin/env bash
# Select a live agent CLI session.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=SCRIPTDIR/process-detection.sh
source "$SCRIPT_DIR/process-detection.sh"
PIN_OPTION="@agent-indicator-pinned-panes"

tmux_option_is_set() {
    local option="$1"
    local raw
    raw=$(tmux show-option -gq "$option" 2>/dev/null || true)
    [ -n "$raw" ]
}

tmux_get_option_or_default() {
    local option="$1"
    local default_value="$2"

    if tmux_option_is_set "$option"; then
        tmux show-option -gqv "$option"
    else
        printf '%s\n' "$default_value"
    fi
}

toggle_pin() {
    local pane_id="$1"
    local pins next="" candidate
    local -a pane_ids

    [[ "$pane_id" =~ ^%[0-9]+$ ]] || return 1
    pins=$(tmux show-option -gqv "$PIN_OPTION" 2>/dev/null || true)
    IFS=',' read -r -a pane_ids <<< "$pins"

    if [[ ",$pins," == *",$pane_id,"* ]]; then
        for candidate in "${pane_ids[@]}"; do
            [ -n "$candidate" ] || continue
            [ "$candidate" = "$pane_id" ] && continue
            next+="${next:+,}$candidate"
        done
    else
        next="${pins:+$pins,}$pane_id"
    fi

    if [ -n "$next" ]; then
        tmux set-option -gq "$PIN_OPTION" "$next"
    else
        tmux set-option -gu "$PIN_OPTION" 2>/dev/null || true
    fi
}

all_sessions=false
if [ "${1:-}" = "--all" ]; then
    all_sessions=true
    shift
fi

if [ "${1:-}" = "--toggle-pin" ]; then
    [ "$#" -eq 2 ] || exit 1
    toggle_pin "$2"
    exit
fi

declare -a state_panes state_values agent_panes agent_values
state_panes=()
state_values=()
agent_panes=()
agent_values=()
while IFS='=' read -r key value; do
    case "$key" in
        TMUX_AGENT_PANE_*_STATE)
            pane_id="${key#TMUX_AGENT_PANE_}"
            pane_id="${pane_id%_STATE}"
            state_panes[${#state_panes[@]}]="$pane_id"
            state_values[${#state_values[@]}]="$value"
            ;;
        TMUX_AGENT_PANE_*_AGENT)
            pane_id="${key#TMUX_AGENT_PANE_}"
            pane_id="${pane_id%_AGENT}"
            agent_panes[${#agent_panes[@]}]="$pane_id"
            agent_values[${#agent_values[@]}]="$value"
            ;;
    esac
done < <(tmux show-environment -g 2>/dev/null)

pane_state() {
    local pane_id="$1"
    local index

    for ((index = 0; index < ${#state_panes[@]}; index++)); do
        if [ "${state_panes[$index]}" = "$pane_id" ]; then
            printf '%s\n' "${state_values[$index]}"
            return
        fi
    done
}

pane_hook_agent() {
    local pane_id="$1"
    local index

    for ((index = 0; index < ${#agent_panes[@]}; index++)); do
        if [ "${agent_panes[$index]}" = "$pane_id" ]; then
            printf '%s\n' "${agent_values[$index]}"
            return
        fi
    done
}

processes=$(tmux_get_option_or_default "@agent-indicator-processes" "$AGENT_INDICATOR_DEFAULT_PROCESSES")
pinned_panes=$(tmux show-option -gqv "$PIN_OPTION" 2>/dev/null || true)
host_name=$(hostname -s 2>/dev/null || hostname 2>/dev/null || true)
current_session_id=$(tmux display-message -p -t "${TMUX_PANE:-}" '#{session_id}')
pane_snapshot=$(tmux list-panes -a -F $'#{pane_id}\t#{pane_tty}\t#{session_id}\t#{session_name}\t#{window_id}\t#{window_name}\t#{pane_index}\t#{pane_current_path}\t#{pane_title}')

truncate_text() {
    local value="$1"
    local max_length="$2"

    if [ "${#value}" -le "$max_length" ]; then
        printf '%s\n' "$value"
    else
        printf '%s…\n' "${value:0:max_length-1}"
    fi
}

sanitize_pane_title() {
    local title="$1"
    local agent="$2"
    local repo="$3"
    local lower

    title=$(printf '%s' "$title" | tr '\t\r\n' '   ' | sed -E \
        -e 's/^[[:space:]]+//' \
        -e 's/[[:space:]]+$//' \
        -e 's/^[✳✦◇◆●○◐◑◒◓⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏]+[[:space:]-]*//')
    if [ "$agent" = "pi" ]; then
        title="${title#π - }"
    fi
    lower=$(printf '%s' "$title" | tr '[:upper:]' '[:lower:]')

    case "$lower" in
        ""|agent|claude|"claude code"|codex|aider|cursor|opencode|pi|ready|idle|done|working|thinking|running|"action required")
            return 1
            ;;
        "claude ready"|"claude code ready"|"codex ready"|"cursor agent"|"codex - action required"|"claude code - action required")
            return 1
            ;;
    esac
    [[ "$lower" =~ ^terminal[[:space:]][0-9]+$ ]] && return 1
    [[ "$title" =~ ^(~|/|[A-Za-z]:[\\/]) ]] && return 1
    if [[ "$title" != *" "* && "$title" == *[\\/]* ]]; then
        return 1
    fi
    [ "$title" = "$repo" ] && return 1
    [ -n "$host_name" ] && [ "$title" = "$host_name" ] && return 1

    truncate_text "$title" 30
}

resolve_summary() {
    local title="$1"
    local agent="$2"
    local window="$3"
    local repo="$4"
    local summary

    if summary=$(sanitize_pane_title "$title" "$agent" "$repo"); then
        printf '%s\n' "$summary"
    elif [ -n "$repo" ]; then
        truncate_text "$repo" 30
    else
        truncate_text "$window" 30
    fi
}

agent_mark() {
    case "$1" in
        claude) printf 'C\n' ;;
        codex) printf 'X\n' ;;
        opencode) printf 'O\n' ;;
        pi) printf 'π\n' ;;
        aider) printf 'A\n' ;;
        cursor) printf 'Cu\n' ;;
        *) printf '%s\n' "${1:0:2}" ;;
    esac
}

status_heading() {
    local state="$1"
    local count="$2"

    case "$state" in
        needs-input) printf '❗ NEEDS INPUT  %s\n' "$count" ;;
        done) printf '✅ DONE  %s\n' "$count" ;;
        running) printf '⚡ RUNNING  %s\n' "$count" ;;
        idle) printf '💤 IDLE  %s\n' "$count" ;;
    esac
}

directory_heading() {
    local path="$1"
    local name="$2"

    if [ -z "$name" ]; then
        name="${path:-unknown}"
    fi
    printf '▾ %s\n' "$(truncate_text "$name" 34)"
}

render_rows() {
    local pane_id pane_tty session_id session window_id window pane_index path pane_title
    local agent hook_agent state rank pin_rank location repo summary mark

    while IFS=$'\t' read -r pane_id pane_tty session_id session window_id window pane_index path pane_title; do
        if [ "$all_sessions" = false ] && [ "$session_id" != "$current_session_id" ]; then
            continue
        fi
        if ! agent=$(agent_indicator_detect_process "$pane_tty" "$processes"); then
            continue
        fi

        state="idle"
        hook_agent=$(pane_hook_agent "$pane_id")
        if [ "$hook_agent" = "$agent" ]; then
            case "$(pane_state "$pane_id")" in
                running) state="running" ;;
                needs-input) state="needs-input" ;;
                done) state="done" ;;
            esac
        fi

        case "$state" in
            needs-input) rank=1 ;;
            done) rank=2 ;;
            running) rank=3 ;;
            idle) rank=4 ;;
        esac

        if [[ ",$pinned_panes," == *",$pane_id,"* ]]; then
            pin_rank=0
        else
            pin_rank=1
        fi
        location="$session:$window.$pane_index"
        repo="${path%/}"
        repo="${repo##*/}"
        summary=$(resolve_summary "$pane_title" "$agent" "$window" "$repo")
        mark=$(agent_mark "$agent")

        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$pane_id" "$session_id" "$window_id" "$rank" "$pin_rank" "$session" "$window" \
            "$pane_index" "$state" "$agent" "$location" "$path" "$summary" "$repo" "$mark"
    done <<< "$pane_snapshot" | LC_ALL=C sort -t $'\t' \
        -k4,4n -k12,12 -k5,5n -k6,6 -k7,7 -k8,8n -k2,2 -k3,3 -k1,1
}

render_cards() {
    local rows row previous_state="" previous_path=""
    local pane_id session_id window_id rank pin_rank session window pane_index
    local state agent location path summary repo mark heading pin details display count
    local needs_input_count=0 done_count=0 running_count=0 idle_count=0

    rows=$(render_rows)
    while IFS= read -r row; do
        [ -n "$row" ] || continue
        IFS=$'\t' read -r _ _ _ _ _ _ _ _ state _ <<< "$row"
        case "$state" in
            needs-input) needs_input_count=$((needs_input_count + 1)) ;;
            done) done_count=$((done_count + 1)) ;;
            running) running_count=$((running_count + 1)) ;;
            idle) idle_count=$((idle_count + 1)) ;;
        esac
    done <<< "$rows"

    while IFS= read -r row; do
        [ -n "$row" ] || continue
        IFS=$'\t' read -r pane_id session_id window_id rank pin_rank session window pane_index \
            state agent location path summary repo mark <<< "$row"
        heading=""
        if [ "$state" != "$previous_state" ]; then
            case "$state" in
                needs-input) count="$needs_input_count" ;;
                done) count="$done_count" ;;
                running) count="$running_count" ;;
                idle) count="$idle_count" ;;
            esac
            heading="$(status_heading "$state" "$count")"$'\n'
            previous_state="$state"
            previous_path=""
        fi
        if [ "$path" != "$previous_path" ]; then
            heading+="$(directory_heading "$path" "$repo")"$'\n'
            previous_path="$path"
        fi
        if [ "$pin_rank" -eq 0 ]; then
            pin="📌"
        else
            pin="  "
        fi
        details="$location"
        details=$(truncate_text "$details" 34)
        display="${heading}${pin} ${mark}  ${summary}"$'\n'"     ${details}"

        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\0' \
            "$pane_id" "$session_id" "$window_id" "$rank" "$pin_rank" "$session" "$window" \
            "$pane_index" "$state" "$agent" "$location" "$path" "$summary" "$repo" "$mark" "$display"
    done <<< "$rows"
}

if [ "${1:-}" = "--list" ]; then
    render_cards
    exit
fi

if ! command -v fzf >/dev/null 2>&1; then
    printf 'fzf is required for the agent sessions panel.\n'
    read -rsn1
    exit 1
fi
if ! fzf --help 2>&1 | grep -q -- '--id-nth'; then
    printf 'fzf 0.71.0 or newer is required for the agent sessions panel.\n'
    read -rsn1
    exit 1
fi

printf -v panel_command '%q' "$SCRIPT_DIR/notification-panel.sh"
panel_list_command="$panel_command --list"
if [ "$all_sessions" = true ]; then
    panel_list_command="$panel_command --all --list"
fi

# ponytail: delay EOF so a forwarded opener cannot trigger the close binding.
if ! selection=$({ render_cards; sleep 0.2; } | fzf \
    --read0 \
    --ansi \
    --delimiter=$'\t' \
    --with-nth=16.. \
    --nth=6.. \
    --accept-nth=1..3 \
    --no-sort \
    --track \
    --id-nth=1 \
    --layout=reverse \
    --border=none \
    --info=inline \
    --bind='alt-i:abort,start:unbind(alt-i),load:rebind(alt-i)' \
    --bind="ctrl-p:execute-silent($panel_command --toggle-pin {1})+reload($panel_list_command)" \
    --prompt='agent sessions> ' \
    --header='Enter open · Ctrl-P pin · Alt-I close'); then
    exit 0
fi

IFS=$'\t' read -r pane_id session_id window_id <<< "$selection"

tmux switch-client -t "$session_id" \; select-window -t "$window_id" \; select-pane -t "$pane_id"
