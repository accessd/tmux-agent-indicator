#!/usr/bin/env bash

# shellcheck disable=SC2034
AGENT_INDICATOR_DEFAULT_PROCESSES="claude,codex,aider,cursor,opencode,pi"

agent_indicator_process_snapshot() {
    local processes="$1"

    ps -ax -o tty= -o command= 2>/dev/null | awk -v processes="$processes" '
        BEGIN {
            count = split(processes, names, ",")
            for (i = 1; i <= count; i++) {
                sub(/^[[:space:]]+/, "", names[i])
                sub(/[[:space:]]+$/, "", names[i])
            }
        }
        {
            tty = $1
            $1 = ""
            commands[tty] = commands[tty] " " $0
        }
        END {
            for (tty in commands) {
                for (i = 1; i <= count; i++) {
                    name = names[i]
                    if (name != "" && commands[tty] ~ ("(^|[^[:alnum:]_])(" name ")([^[:alnum:]_]|$)")) {
                        print tty "\t" name
                        break
                    }
                }
            }
        }
    '
}

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

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    if [ "${1:-}" != "--snapshot" ]; then
        exit 1
    fi
    agent_indicator_process_snapshot "${2:-$AGENT_INDICATOR_DEFAULT_PROCESSES}"
fi
