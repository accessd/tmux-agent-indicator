#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ! command -v tmux >/dev/null 2>&1 || ! command -v python3 >/dev/null 2>&1; then
    exit 0
fi
if ! tmux display-message -p '#{session_name}' >/dev/null 2>&1; then
    exit 0
fi

tmux_get_option_or_default() {
    local option="$1"
    local default_value="$2"
    local raw value
    raw=$(tmux show-option -gq "$option" 2>/dev/null || true)
    if [ -n "$raw" ]; then
        value=$(tmux show-option -gqv "$option")
        printf '%s\n' "$value"
    else
        printf '%s\n' "$default_value"
    fi
}

enabled=$(tmux_get_option_or_default "@agent-indicator-limits-enabled" "on")
case "$enabled" in
    on|true|yes|1) ;;
    *) exit 0 ;;
esac

providers=$(tmux_get_option_or_default "@agent-indicator-limits-providers" "claude,codex")
cache_seconds=$(tmux_get_option_or_default "@agent-indicator-limits-cache-seconds" "60")

if ! [[ "$cache_seconds" =~ ^[0-9]+$ ]]; then
    cache_seconds=60
fi

exec python3 "$SCRIPT_DIR/agent-limits.py" \
    --providers "$providers" \
    --cache-seconds "$cache_seconds"
