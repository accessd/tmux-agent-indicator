#!/usr/bin/env bash
# Dump all tmux-agent-indicator settings.
# Options set to '' are shown as '' (skip semantics); unset ones as (not set).

set -euo pipefail

if ! command -v tmux >/dev/null 2>&1; then
    exit 0
fi
if ! tmux display-message -p '#{session_name}' >/dev/null 2>&1; then
    exit 0
fi

options=(
    @agent-indicator-indicator-enabled
    @agent-indicator-background-enabled
    @agent-indicator-border-enabled
    @agent-indicator-reset-on-focus
    @agent-indicator-processes
    @agent-indicator-icons
    @agent-indicator-state-icons
    @agent-indicator-limits-enabled
    @agent-indicator-limits-providers
    @agent-indicator-limits-cache-seconds
    @agent-indicator-animation-enabled
    @agent-indicator-animation-speed
    @agent-indicator-notification-enabled
    @agent-indicator-notification-states
    @agent-indicator-notification-format
    @agent-indicator-notification-duration
    @agent-indicator-notification-command
    @agent-indicator-session-dots-active
    @agent-indicator-session-dots-inactive
    @agent-indicator-session-dots-attention
    @agent-indicator-session-dots-color
    @agent-indicator-session-dots-active-color
    @agent-indicator-session-dots-attention-color
    @agent-indicator-session-dots-attention-states
)

for state in running needs-input "done"; do
    options+=(
        "@agent-indicator-${state}-enabled"
        "@agent-indicator-${state}-bg"
        "@agent-indicator-${state}-border"
        "@agent-indicator-${state}-window-title-bg"
        "@agent-indicator-${state}-window-title-fg"
    )
done

for opt in "${options[@]}"; do
    # `show-option -gq` prints `name value` for a set option (even when the
    # value is empty) and nothing for an unset one; `-v` alone cannot tell
    # the two apart.
    raw=$(tmux show-option -gq "$opt" 2>/dev/null || true)
    if [ -z "$raw" ]; then
        printf '%-50s %s\n' "$opt" "(not set)"
        continue
    fi
    val=$(tmux show-option -gqv "$opt" 2>/dev/null || true)
    if [ -z "$val" ]; then
        val="''"
    fi
    printf '%-50s %s\n' "$opt" "$val"
done
