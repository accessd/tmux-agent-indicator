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

pass "indicator output for running/off"
