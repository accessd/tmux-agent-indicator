#!/usr/bin/env bash
# Select a live agent CLI session.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIN_OPTION="@agent-indicator-pinned-panes"
STORE_BIN="${TMUX_AGENT_STORE_BIN:-$SCRIPT_DIR/../bin/agent-store}"

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

[ -x "$STORE_BIN" ] || {
    printf 'agent-store is required for the agent sessions panel. Run install.sh.\n' >&2
    exit 1
}

panel_needs_input_color=$(tmux_get_option_or_default "@agent-indicator-panel-needs-input-color" "yellow")
panel_done_color=$(tmux_get_option_or_default "@agent-indicator-panel-done-color" "green")
panel_running_color=$(tmux_get_option_or_default "@agent-indicator-panel-running-color" "blue")
panel_needs_input_bg=$(tmux_get_option_or_default "@agent-indicator-panel-needs-input-bg" "yellow")
panel_done_bg=$(tmux_get_option_or_default "@agent-indicator-panel-done-bg" "green")
panel_running_bg=$(tmux_get_option_or_default "@agent-indicator-panel-running-bg" "blue")
panel_needs_input_fg=$(tmux_get_option_or_default "@agent-indicator-panel-needs-input-fg" "black")
panel_done_fg=$(tmux_get_option_or_default "@agent-indicator-panel-done-fg" "black")
panel_running_fg=$(tmux_get_option_or_default "@agent-indicator-panel-running-fg" "white")
pinned_panes=$(tmux show-option -gqv "$PIN_OPTION" 2>/dev/null || true)
host_name=$(hostname -s 2>/dev/null || hostname 2>/dev/null || true)
current_session_id=$(tmux display-message -p -t "${TMUX_PANE:-}" '#{session_id}')
panel_width=$(tmux display-message -p -t "${TMUX_PANE:-}" '#{pane_width}')
# fzf uses two columns for its pointer and leaves the last terminal column unused.
fzf_item_width=$((panel_width - 3))

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
    local description="$5"
    local summary

    if [ -n "$description" ]; then
        truncate_text "$description" 34
    elif summary=$(sanitize_pane_title "$title" "$agent" "$repo"); then
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

ansi_color_code() {
    local color="$1"
    local layer="${2:-fg}"
    local number
    local base=30 bright=90 extended=38

    if [ "$layer" = "bg" ]; then
        base=40
        bright=100
        extended=48
    fi

    case "$color" in
        black) printf '%s\n' "$base" ;;
        red) printf '%s\n' "$((base + 1))" ;;
        green) printf '%s\n' "$((base + 2))" ;;
        yellow) printf '%s\n' "$((base + 3))" ;;
        blue) printf '%s\n' "$((base + 4))" ;;
        magenta) printf '%s\n' "$((base + 5))" ;;
        cyan) printf '%s\n' "$((base + 6))" ;;
        white) printf '%s\n' "$((base + 7))" ;;
        brightblack) printf '%s\n' "$bright" ;;
        brightred) printf '%s\n' "$((bright + 1))" ;;
        brightgreen) printf '%s\n' "$((bright + 2))" ;;
        brightyellow) printf '%s\n' "$((bright + 3))" ;;
        brightblue) printf '%s\n' "$((bright + 4))" ;;
        brightmagenta) printf '%s\n' "$((bright + 5))" ;;
        brightcyan) printf '%s\n' "$((bright + 6))" ;;
        brightwhite) printf '%s\n' "$((bright + 7))" ;;
        colour*)
            number="${color#colour}"
            if [[ "$number" =~ ^[0-9]+$ ]] && [ "$number" -le 255 ]; then
                printf '%s;5;%s\n' "$extended" "$number"
            else
                return 1
            fi
            ;;
        *) return 1 ;;
    esac
}

card_style() {
    local state="$1"
    local bg fg bg_code fg_code codes=""

    case "$state" in
        needs-input) bg="$panel_needs_input_bg"; fg="$panel_needs_input_fg" ;;
        done) bg="$panel_done_bg"; fg="$panel_done_fg" ;;
        running) bg="$panel_running_bg"; fg="$panel_running_fg" ;;
        idle) return ;;
    esac

    if bg_code=$(ansi_color_code "$bg" bg); then
        codes="$bg_code"
    fi
    if fg_code=$(ansi_color_code "$fg"); then
        codes="${codes:+$codes;}$fg_code"
    fi
    [ -n "$codes" ] && printf '\033[%sm' "$codes"
}

status_icon_glyph() {
    local state="$1"

    case "$state" in
        needs-input) printf '◆\n' ;;
        done) printf '✓\n' ;;
        running) printf '●\n' ;;
        idle) printf '○\n' ;;
    esac
}

status_icon() {
    local state="$1"
    local restore_style="${2:-$'\033[0m'}"
    local icon="$3"
    local color code

    case "$state" in
        needs-input) color="$panel_needs_input_color" ;;
        done) color="$panel_done_color" ;;
        running) color="$panel_running_color" ;;
        idle) color="" ;;
    esac

    if code=$(ansi_color_code "$color"); then
        printf '\033[%sm%s%s\n' "$code" "$icon" "$restore_style"
    else
        printf '%s\n' "$icon"
    fi
}

render_rows() {
    local pane_id session_id window_id session window pane_index state agent path pane_title description
    local rank pin_rank location repo summary mark
    local -a store_args

    store_args=(list)
    if [ "$all_sessions" = false ]; then
        store_args+=(--session "$current_session_id")
    fi

    while IFS=$'\t' read -r pane_id session_id window_id session window pane_index state agent path pane_title description; do
        [ -n "$pane_id" ] || continue

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
        summary=$(resolve_summary "$pane_title" "$agent" "$window" "$repo" "$description")
        mark=$(agent_mark "$agent")

        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$pane_id" "$session_id" "$window_id" "$rank" "$pin_rank" "$session" "$window" \
            "$pane_index" "$state" "$agent" "$location" "$path" "$summary" "$repo" "$mark"
    done < <("$STORE_BIN" "${store_args[@]}") | LC_ALL=C sort -t $'\t' \
        -k6,6 -k7,7 -k12,12 -k5,5n -k8,8n -k2,2 -k3,3 -k1,1
}

render_cards() {
    local rows row previous_window="" window_key
    local pane_id session_id window_id rank pin_rank session window pane_index
    local state agent location path summary repo mark heading pin display icon glyph style
    local first_line second_line

    rows=$(render_rows)
    while IFS= read -r row; do
        [ -n "$row" ] || continue
        IFS=$'\t' read -r pane_id session_id window_id rank pin_rank session window pane_index \
            state agent location path summary repo mark <<< "$row"
        heading=""
        window_key="$session_id:$window_id"
        if [ "$window_key" != "$previous_window" ]; then
            if [ "$all_sessions" = true ]; then
                heading="$session · $window"$'\n'
            else
                heading="$window"$'\n'
            fi
            previous_window="$window_key"
        fi
        if [ "$pin_rank" -eq 0 ]; then
            pin=" 📌"
        else
            pin=""
        fi
        style=$(card_style "$state")
        glyph=$(status_icon_glyph "$state")
        icon=$(status_icon "$state" "${style:-$'\033[0m'}" "$glyph")
        printf -v first_line '%-*s' "$fzf_item_width" "$glyph ${repo}${pin}"
        first_line="${icon}${first_line#"$glyph"}"
        printf -v second_line '%-*s' "$fzf_item_width" "  ${mark} ${summary}"
        display="${heading}${style}${first_line}"$'\n'"${second_line}${style:+$'\033[0m'}"

        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\0' \
            "$pane_id" "$session_id" "$window_id" "$rank" "$pin_rank" "$session" "$window" \
            "$pane_index" "$state" "$agent" "$location" "$path" "$summary" "$repo" "$mark" "$display"
    done <<< "$rows"
}

if [ "${1:-}" = "--refresh-list" ]; then
    "$STORE_BIN" sync
    render_cards
    exit
fi

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
panel_refresh_command="$panel_command --refresh-list"
if [ "$all_sessions" = true ]; then
    panel_list_command="$panel_command --all --list"
    panel_refresh_command="$panel_command --all --refresh-list"
fi
panel_channel="agent-indicator-panel-${TMUX_PANE#%}"
printf -v reload_action '%q' "reload($panel_list_command)"

if ! selection=$(render_cards | fzf \
    --read0 \
    --ansi \
    --color='fg+:-1,bg+:-1' \
    --delimiter=$'\t' \
    --with-nth=16.. \
    --accept-nth=1..3 \
    --no-sort \
    --track \
    --gap=1 \
    --gap-line='─' \
    --disabled \
    --id-nth=1 \
    --layout=reverse \
    --border=none \
    --info=inline \
    --bind='start:unbind(esc)' \
    --bind='j:down,k:up' \
    --bind='/:enable-search+unbind(j,k,r,/)+rebind(esc)+change-prompt(search> )' \
    --bind='esc:clear-query+disable-search+rebind(j,k,r,/)+change-prompt(agent sessions> )+unbind(esc)' \
    --bind="load:bg-transform[tmux wait-for $panel_channel; printf '%s\n' $reload_action]" \
    --bind="r:reload($panel_refresh_command)" \
    --bind="ctrl-p:execute-silent($panel_command --toggle-pin {1})+reload($panel_list_command)" \
    --prompt='agent sessions> ' \
    --header='Enter open · R refresh · Ctrl-P pin · Alt-I close'); then
    exit 0
fi

IFS=$'\t' read -r pane_id session_id window_id <<< "$selection"

tmux switch-client -t "$session_id" \; select-window -t "$window_id" \; select-pane -t "$pane_id"
