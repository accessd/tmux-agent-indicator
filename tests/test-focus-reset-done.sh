#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/tests/lib/tmux-test-lib.sh"

trap cleanup_test_server EXIT

setup_test_server "focus-reset-done"

run_state "done"
tmux_cmd run-shell "$ROOT_DIR/scripts/pane-focus-in.sh \"$PANE\" \"$WIN\""

status_style_after="$(get_window_option "$WIN" "window-status-style")"
current_style_after="$(get_window_option "$WIN" "window-status-current-style")"
state_after="$(get_env "TMUX_AGENT_PANE_${PANE}_STATE")"

assert_empty "$status_style_after" "window-status-style should reset after done focus-in"
assert_empty "$current_style_after" "window-status-current-style should reset after done focus-in"
assert_empty "$state_after" "done state env should reset after done focus-in"

first_done_pane="$(tmux_cmd split-window -d -P -F '#{pane_id}' -t "$PANE")"
second_done_pane="$(tmux_cmd split-window -d -P -F '#{pane_id}' -t "$PANE")"
tmux_cmd set-option -g @agent-indicator-done-bg colour22
tmux_cmd run-shell "TMUX_PANE=$first_done_pane \"$ROOT_DIR/scripts/agent-state.sh\" --agent claude --state done"
tmux_cmd run-shell "TMUX_PANE=$second_done_pane \"$ROOT_DIR/scripts/agent-state.sh\" --agent codex --state done"

second_style_before="$(tmux_cmd show-options -pv -p -t "$second_done_pane" window-style)"
[ "$second_style_before" = "bg=colour22" ] || fail "second done pane style should be applied: $second_style_before"

tmux_cmd select-pane -t "$first_done_pane"
second_style_unfocused="$(tmux_cmd show-options -pv -p -t "$second_done_pane" window-style)"
[ "$second_style_unfocused" = "bg=colour22" ] || fail "second done pane style should remain until focus: $second_style_unfocused"

tmux_cmd select-pane -t "$second_done_pane"
second_style_after="$(tmux_cmd show-options -pv -p -t "$second_done_pane" window-style)"

[ "$second_style_after" = "bg=default" ] || fail "second done pane style should reset on focus: $second_style_after"

pass "done focus reset clears styles and pane state"
