#!/usr/bin/env bash
# Interactive color setup wizard for tmux-agent-indicator.

set -euo pipefail

if [[ ! -t 0 ]]; then
    # Under `curl | bash` stdin is not a terminal; fall back to the controlling one.
    if [[ -t 1 ]] && ( exec </dev/tty ) 2>/dev/null; then
        exec </dev/tty
    else
        echo "setup.sh requires an interactive terminal." >&2
        exit 1
    fi
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENT_STATE="$SCRIPT_DIR/scripts/agent-state.sh"

if [ ! -f "$AGENT_STATE" ]; then
    echo "Cannot find scripts/agent-state.sh" >&2
    exit 1
fi

STATES=(running needs-input "done")
PROPS=(bg border window-title-bg window-title-fg)

# -- Presets --
# Values match agent-state.sh defaults and README preset blocks.
# Empty string means "do not apply this property" (disabled).

declare -A PRESET_DEFAULT=(
    [running-bg]="default"
    [running-border]="default"
    [running-window-title-bg]=""
    [running-window-title-fg]=""
    [needs-input-bg]="default"
    [needs-input-border]="yellow"
    [needs-input-window-title-bg]="yellow"
    [needs-input-window-title-fg]="black"
    [done-bg]="default"
    [done-border]="green"
    [done-window-title-bg]="red"
    [done-window-title-fg]="black"
)

declare -A PRESET_BALANCED=(
    [running-bg]=""
    [running-border]=""
    [running-window-title-bg]=""
    [running-window-title-fg]=""
    [needs-input-bg]="colour223"
    [needs-input-border]="colour214"
    [needs-input-window-title-bg]="yellow"
    [needs-input-window-title-fg]="black"
    [done-bg]=""
    [done-border]="colour34"
    [done-window-title-bg]="colour34"
    [done-window-title-fg]="black"
)

declare -A PRESET_HIGH_CONTRAST=(
    [running-bg]="colour52"
    [running-border]="colour196"
    [running-window-title-bg]=""
    [running-window-title-fg]=""
    [needs-input-bg]="colour94"
    [needs-input-border]="colour226"
    [needs-input-window-title-bg]="yellow"
    [needs-input-window-title-fg]="black"
    [done-bg]=""
    [done-border]="colour46"
    [done-window-title-bg]="colour46"
    [done-window-title-fg]="black"
)

declare -A PRESET_SUBTLE=(
    [running-bg]=""
    [running-border]="colour244"
    [running-window-title-bg]=""
    [running-window-title-fg]=""
    [needs-input-bg]=""
    [needs-input-border]="colour220"
    [needs-input-window-title-bg]="yellow"
    [needs-input-window-title-fg]="black"
    [done-bg]=""
    [done-border]="colour70"
    [done-window-title-bg]="colour238"
    [done-window-title-fg]="colour194"
)

declare -A CONFIG

load_preset() {
    local key
    case "$1" in
        default)
            for key in "${!PRESET_DEFAULT[@]}"; do CONFIG[$key]="${PRESET_DEFAULT[$key]}"; done ;;
        balanced)
            for key in "${!PRESET_BALANCED[@]}"; do CONFIG[$key]="${PRESET_BALANCED[$key]}"; done ;;
        high-contrast)
            for key in "${!PRESET_HIGH_CONTRAST[@]}"; do CONFIG[$key]="${PRESET_HIGH_CONTRAST[$key]}"; done ;;
        subtle)
            for key in "${!PRESET_SUBTLE[@]}"; do CONFIG[$key]="${PRESET_SUBTLE[$key]}"; done ;;
    esac
}

display_value() {
    if [ -z "$1" ]; then
        printf "(disabled)"
    else
        printf "%s" "$1"
    fi
}

prop_label() {
    case "$1" in
        bg) printf "Pane background" ;;
        border) printf "Border color" ;;
        window-title-bg) printf "Window title bg" ;;
        window-title-fg) printf "Window title fg" ;;
    esac
}

print_summary() {
    printf "\n%-14s  %-12s  %-12s  %-16s  %-16s\n" \
        "State" "Border" "Pane BG" "Title BG" "Title FG"
    printf "%-14s  %-12s  %-12s  %-16s  %-16s\n" \
        "-----" "------" "-------" "--------" "--------"
    local state
    for state in "${STATES[@]}"; do
        printf "%-14s  %-12s  %-12s  %-16s  %-16s\n" \
            "$state" \
            "$(display_value "${CONFIG[${state}-border]}")" \
            "$(display_value "${CONFIG[${state}-bg]}")" \
            "$(display_value "${CONFIG[${state}-window-title-bg]}")" \
            "$(display_value "${CONFIG[${state}-window-title-fg]}")"
    done
    printf "\n"
}

apply_options_to_tmux() {
    local state prop key
    for state in "${STATES[@]}"; do
        for prop in "${PROPS[@]}"; do
            key="${state}-${prop}"
            tmux set-option -g "@agent-indicator-${key}" "${CONFIG[$key]}"
        done
    done
}

# -- Preview cleanup state --
ORIG_RESET_ON_FOCUS=""
IN_PREVIEW=false
IN_COLOR_PICKER=false

cleanup() {
    if [ "$IN_COLOR_PICKER" = true ]; then
        tput cnorm 2>/dev/null || true
        tput rmcup 2>/dev/null || true
        IN_COLOR_PICKER=false
    fi
    if [ "$IN_PREVIEW" = true ] && command -v tmux >/dev/null 2>&1 && [ -n "${TMUX:-}" ]; then
        bash "$AGENT_STATE" --agent preview --state off 2>/dev/null || true
        if [ -n "$ORIG_RESET_ON_FOCUS" ]; then
            tmux set-option -g "@agent-indicator-reset-on-focus" "$ORIG_RESET_ON_FOCUS" 2>/dev/null || true
        else
            tmux set-option -gu "@agent-indicator-reset-on-focus" 2>/dev/null || true
        fi
        IN_PREVIEW=false
    fi
}

trap cleanup EXIT INT TERM

preview_states() {
    if ! command -v tmux >/dev/null 2>&1 || [ -z "${TMUX:-}" ]; then
        echo "Not inside tmux, skipping live preview."
        return
    fi

    ORIG_RESET_ON_FOCUS=$(tmux show-option -gqv "@agent-indicator-reset-on-focus" 2>/dev/null || true)
    tmux set-option -g "@agent-indicator-reset-on-focus" "on"
    IN_PREVIEW=true

    apply_options_to_tmux

    echo "Live preview (press Enter to cycle states, q to skip):"
    echo ""

    local reply

    bash "$AGENT_STATE" --agent preview --state running
    printf "  [running] Enter=next, q=skip: "
    read -r reply
    if [ "$reply" = "q" ]; then
        cleanup
        return
    fi

    bash "$AGENT_STATE" --agent preview --state needs-input
    printf "  [needs-input] Enter=next, q=skip: "
    read -r reply
    if [ "$reply" = "q" ]; then
        cleanup
        return
    fi

    bash "$AGENT_STATE" --agent preview --state "done"
    printf "  [done] Enter=finish preview: "
    read -r reply

    cleanup
}

generate_config_lines() {
    local state prop key val
    for state in "${STATES[@]}"; do
        for prop in "${PROPS[@]}"; do
            key="${state}-${prop}"
            val="${CONFIG[$key]}"
            printf "set -g @agent-indicator-%s '%s'\n" "$key" "$val"
        done
    done
}

save_to_tmux_conf() {
    local conf="${TMUX_CONF:-$HOME/.tmux.conf}"
    local begin_marker="# BEGIN tmux-agent-indicator-colors"
    local end_marker="# END tmux-agent-indicator-colors"

    local config_block
    config_block=$(generate_config_lines)

    local new_block
    new_block="$(printf '%s\n%s\n%s' "$begin_marker" "$config_block" "$end_marker")"

    if [ ! -f "$conf" ]; then
        printf '%s\n' "$new_block" > "$conf"
        echo "Created $conf with color config."
        return
    fi

    if grep -qxF "$begin_marker" "$conf"; then
        local in_block=false
        local line tmpfile
        tmpfile=$(mktemp)
        while IFS= read -r line || [ -n "$line" ]; do
            if [ "$line" = "$begin_marker" ]; then
                in_block=true
                printf '%s\n' "$new_block" >> "$tmpfile"
                continue
            fi
            if [ "$line" = "$end_marker" ]; then
                in_block=false
                continue
            fi
            if [ "$in_block" = false ]; then
                printf '%s\n' "$line" >> "$tmpfile"
            fi
        done < "$conf"
        if [ "$in_block" = true ]; then
            rm -f "$tmpfile"
            echo "Found '$begin_marker' without '$end_marker' in $conf; refusing to rewrite it." >&2
            echo "Add the missing end marker (or remove the begin marker) and run setup again." >&2
            return 1
        fi
        # Write through the existing path (keeps symlinks, mode and ownership).
        cat "$tmpfile" > "$conf"
        rm -f "$tmpfile"
        echo "Updated color config in $conf."
    else
        printf '\n%s\n' "$new_block" >> "$conf"
        echo "Appended color config to $conf."
    fi
}

# -- Color picker --

PICKED_COLOR=""

read_key() {
    local key
    read -rsn1 key
    if [[ "$key" == $'\033' ]]; then
        read -rsn2 -t 0.1 key || true
        case "$key" in
            '[A') echo "UP" ;;
            '[B') echo "DOWN" ;;
            '[C') echo "RIGHT" ;;
            '[D') echo "LEFT" ;;
            *) echo "ESC" ;;
        esac
    elif [[ "$key" == "" ]]; then
        echo "ENTER"
    else
        echo "$key"
    fi
}

is_light_color() {
    local n=$1
    if (( n <= 15 )); then
        case $n in 7|14|15) return 0 ;; *) return 1 ;; esac
    elif (( n <= 231 )); then
        local idx=$(( n - 16 ))
        local r=$(( idx / 36 )) g=$(( (idx % 36) / 6 )) b=$(( idx % 6 ))
        if (( r + g + b > 9 )); then return 0; else return 1; fi
    else
        if (( n > 243 )); then return 0; else return 1; fi
    fi
}

pick_color() {
    local label="$1"
    local current="$2"

    # Parse current value to initial grid position
    local row=0 col=0
    if [[ "$current" =~ ^colour([0-9]+)$ ]]; then
        local n="${BASH_REMATCH[1]}"
        row=$(( n / 16 ))
        col=$(( n % 16 ))
    elif [[ "$current" =~ ^[0-9]+$ ]]; then
        row=$(( current / 16 ))
        col=$(( current % 16 ))
    else
        case "$current" in
            black)   col=0 ;;
            red)     col=1 ;;
            green)   col=2 ;;
            yellow)  col=3 ;;
            blue)    col=4 ;;
            magenta) col=5 ;;
            cyan)    col=6 ;;
            white)   col=7 ;;
        esac
    fi

    # Enter alternate screen, hide cursor
    tput smcup
    tput civis
    IN_COLOR_PICKER=true

    while true; do
        tput cup 0 0

        # Header
        printf "  %s  [current: %s]\033[K\n" "$label" "$(display_value "$current")"
        printf "\033[K\n"

        # Draw 16x16 grid
        local r c color_n
        for (( r=0; r<16; r++ )); do
            printf "  "
            for (( c=0; c<16; c++ )); do
                color_n=$(( r * 16 + c ))
                if (( r == row && c == col )); then
                    if is_light_color "$color_n"; then
                        printf "\033[48;5;%dm\033[30;1m<>\033[0m" "$color_n"
                    else
                        printf "\033[48;5;%dm\033[97;1m<>\033[0m" "$color_n"
                    fi
                else
                    printf "\033[48;5;%dm  \033[0m" "$color_n"
                fi
                if (( c < 15 )); then
                    printf " "
                fi
            done
            printf "\033[K\n"
        done

        # Footer
        local hover_n=$(( row * 16 + col ))
        printf "\033[K\n"
        printf "  colour%-3d \033[48;5;%dm    \033[0m\033[K\n" "$hover_n" "$hover_n"
        printf "\033[K\n"
        printf "  arrows=move  Enter=select  d=default  -=disable  t=type  q=keep\033[K\n"

        # Read input
        local key
        key=$(read_key)
        case "$key" in
            UP)    row=$(( (row + 15) % 16 )) ;;
            DOWN)  row=$(( (row + 1) % 16 )) ;;
            LEFT)  col=$(( (col + 15) % 16 )) ;;
            RIGHT) col=$(( (col + 1) % 16 )) ;;
            ENTER)
                PICKED_COLOR="colour${hover_n}"
                break
                ;;
            d)
                PICKED_COLOR="default"
                break
                ;;
            -)
                PICKED_COLOR=""
                break
                ;;
            t)
                tput cup 22 2
                tput cnorm
                printf "Enter value: \033[K"
                local typed_val
                read -r typed_val
                if [ -n "$typed_val" ]; then
                    PICKED_COLOR="$typed_val"
                else
                    PICKED_COLOR="$current"
                fi
                break
                ;;
            q|ESC)
                PICKED_COLOR="$current"
                break
                ;;
        esac
    done

    # Exit alternate screen, restore cursor
    IN_COLOR_PICKER=false
    tput cnorm
    tput rmcup
}

custom_prompt() {
    load_preset "default"

    local state prop key current
    for state in "${STATES[@]}"; do
        for prop in "${PROPS[@]}"; do
            key="${state}-${prop}"
            current="${CONFIG[$key]}"
            pick_color "$(prop_label "$prop") ($state)" "$current"
            CONFIG[$key]="$PICKED_COLOR"
        done
    done
}

# -- Main --

echo ""
echo "tmux-agent-indicator: Color Setup"
echo ""
echo "  1) Default        borders + window titles, no background changes"
echo "  2) Balanced       warm borders, subtle needs-input background"
echo "  3) High Contrast  vivid borders + backgrounds"
echo "  4) Subtle         muted borders, minimal window title"
echo "  5) Custom         pick each color"
echo ""
printf "  Choice [1]: "
read -r choice

case "${choice:-1}" in
    1) load_preset "default" ;;
    2) load_preset "balanced" ;;
    3) load_preset "high-contrast" ;;
    4) load_preset "subtle" ;;
    5) custom_prompt ;;
    *)
        echo "Invalid choice."
        exit 1
        ;;
esac

print_summary

preview_states

echo ""
echo "Generated config:"
echo ""
generate_config_lines
echo ""

printf "Save to ~/.tmux.conf? [Y/n]: "
read -r save_reply
case "${save_reply:-Y}" in
    [nN]*)
        echo "Not saved. Copy the lines above into your tmux.conf."
        ;;
    *)
        save_to_tmux_conf
        ;;
esac
