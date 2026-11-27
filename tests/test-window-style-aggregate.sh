#!/usr/bin/env bash
# Window title and active-border styles are shared by all panes of a window:
# they show the most urgent pane state and are restored only when no pane
# needs them any more.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/tests/lib/tmux-test-lib.sh"

trap cleanup_test_server EXIT

run_pane_state() {
    tmux_cmd run-shell "TMUX_PANE=$1 \"$REPO_ROOT/scripts/agent-state.sh\" --agent $3 --state $2"
}

expect_styles() {
    local title="$1" border="$2" context="$3"
    local actual_title actual_current actual_border
    actual_title="$(get_window_option "$WIN" window-status-style)"
    actual_current="$(get_window_option "$WIN" window-status-current-style)"
    actual_border="$(get_window_option "$WIN" pane-active-border-style)"
    [ "$actual_title" = "$title" ] || fail "$context: window-status-style '$actual_title' != '$title'"
    [ "$actual_current" = "$title" ] || fail "$context: window-status-current-style '$actual_current' != '$title'"
    [ "$actual_border" = "$border" ] || fail "$context: pane-active-border-style '$actual_border' != '$border'"
}

setup_test_server "window-style-aggregate"
create_other_window

pane_a="$PANE"
pane_b="$(tmux_cmd split-window -d -P -F '#{pane_id}' -t "$PANE")"
tmux_cmd select-window -t ai:other

run_pane_state "$pane_b" needs-input claude
expect_styles "bg=yellow,fg=black" "fg=yellow,bold" "B needs-input"

run_pane_state "$pane_a" running codex
expect_styles "bg=yellow,fg=black" "fg=yellow,bold" "A running while B needs-input"

run_pane_state "$pane_a" "done" codex
expect_styles "bg=yellow,fg=black" "fg=yellow,bold" "needs-input outranks done"

run_pane_state "$pane_b" off claude
expect_styles "bg=red,fg=black" "fg=green,bold" "B off leaves A done"

run_pane_state "$pane_a" running codex
expect_styles "" "" "A running restores the window"

run_pane_state "$pane_b" "done" claude
run_pane_state "$pane_a" off codex
expect_styles "bg=red,fg=black" "fg=green,bold" "A off keeps B done"

run_pane_state "$pane_b" off claude
expect_styles "" "" "all panes off"

pass "window styles aggregate over the window's agent panes"
