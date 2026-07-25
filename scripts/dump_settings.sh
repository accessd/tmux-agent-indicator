#!/usr/bin/env bash
  # Dump all tmux-agent-indicator settings

  options=(
      @agent-indicator-indicator-enabled
      @agent-indicator-background-enabled
      @agent-indicator-border-enabled
      @agent-indicator-reset-on-focus
      @agent-indicator-processes
      @agent-indicator-icons
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
      val=$(tmux show-option -gqv "$opt" 2>/dev/null)
      if [ -n "$val" ]; then
          printf '%-50s %s\n' "$opt" "$val"
      else
          printf '%-50s %s\n' "$opt" "(not set)"
      fi
  done
