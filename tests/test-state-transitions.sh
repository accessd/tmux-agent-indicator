#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/tests/lib/tmux-test-lib.sh"

trap cleanup_test_server EXIT

setup_test_server "state-transitions"

run_state running
run_state needs-input
run_state "done"
run_state off

state_after="$(get_env "TMUX_AGENT_PANE_${PANE}_STATE")"
assert_empty "$state_after" "pane state should be cleared after off"

indicator_after="$(run_indicator_capture "$PANE")"
assert_empty "$indicator_after" "indicator should be empty after off"

pass "state transitions running -> needs-input -> done -> off"
