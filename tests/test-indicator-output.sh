#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/tests/lib/tmux-test-lib.sh"

trap cleanup_test_server EXIT

setup_test_server "indicator-output"

tmux_cmd set -g status-right '#{agent_limits} #{agent_indicator}'
tmux_cmd run-shell "$ROOT_DIR/agent-indicator.tmux"
status_right=$(tmux_cmd show-option -gqv status-right)
case "$status_right" in
    *agent-limits.sh*indicator.sh*) ;;
    *) fail "status interpolation should include agent limits and indicator: $status_right" ;;
esac

run_state running
indicator_running="$(run_indicator_capture "$PANE")"
assert_non_empty "$indicator_running" "indicator should be non-empty for running state"

run_state off
indicator_off="$(run_indicator_capture "$PANE")"
assert_empty "$indicator_off" "indicator should be empty after off"

tmux_cmd set -g @agent-indicator-icons 'claude=AGENT'
tmux_cmd set -g @agent-indicator-state-icons 'running=RUN, needs-input=ASK'

run_state running
indicator_state_icon="$(run_indicator_capture "$PANE")"
case "$indicator_state_icon" in
    *RUN*) ;;
    *) fail "state icon should override agent icon for running: $indicator_state_icon" ;;
esac

run_state done
indicator_agent_fallback="$(run_indicator_capture "$PANE")"
case "$indicator_agent_fallback" in
    *AGENT*) ;;
    *) fail "agent icon should be used for states without a state icon: $indicator_agent_fallback" ;;
esac

run_state off

pass "indicator output for running/off and state icons"
