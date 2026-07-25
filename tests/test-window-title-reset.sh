#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/tests/lib/tmux-test-lib.sh"

trap cleanup_test_server EXIT

setup_test_server "window-title-reset"
create_other_window
tmux_cmd select-window -t ai:other

run_state needs-input
before_style="$(get_window_option "$WIN" "window-status-style")"
before_current_style="$(get_window_option "$WIN" "window-status-current-style")"
assert_non_empty "$before_style" "window-status-style should be set in needs-input"
assert_non_empty "$before_current_style" "window-status-current-style should be set in needs-input"

sleep 0.1

while_away_style="$(get_window_option "$WIN" "window-status-style")"
while_away_current_style="$(get_window_option "$WIN" "window-status-current-style")"
assert_non_empty "$while_away_style" "window-status-style should stay set while away from source window"
assert_non_empty "$while_away_current_style" "window-status-current-style should stay set while away from source window"

tmux_cmd select-window -t ai:main
sleep 0.1

after_return_style="$(get_window_option "$WIN" "window-status-style")"
after_return_current_style="$(get_window_option "$WIN" "window-status-current-style")"
assert_empty "$after_return_style" "window-status-style should reset after returning to source window"
assert_empty "$after_return_current_style" "window-status-current-style should reset after returning to source window"

pass "window title styles reset only when returning to source window"
