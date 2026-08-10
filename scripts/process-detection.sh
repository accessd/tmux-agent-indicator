#!/usr/bin/env bash

# shellcheck disable=SC2034
AGENT_INDICATOR_DEFAULT_PROCESSES="claude,codex,aider,cursor,opencode,pi"

agent_indicator_detect_process() {
    local pane_tty="$1"
    local processes="$2"
    local commands proc
    local -a process_names

    [ -n "$pane_tty" ] || return 1
    commands=$(ps -t "$(basename "$pane_tty")" -o command= 2>/dev/null) || return 1

    IFS=',' read -r -a process_names <<< "$processes"
    for proc in "${process_names[@]}"; do
        proc="${proc#"${proc%%[![:space:]]*}"}"
        proc="${proc%"${proc##*[![:space:]]}"}"
        [ -n "$proc" ] || continue
        if grep -qw -- "$proc" <<< "$commands"; then
            printf '%s\n' "$proc"
            return 0
        fi
    done

    return 1
}
