#!/usr/bin/env bash
# Focusing a window whose title shows done must only acknowledge done panes,
# never wipe another agent pane of that window that is still running.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/tests/lib/tmux-test-lib.sh"

trap cleanup_test_server EXIT

run_pane_state() {
    tmux_cmd run-shell "TMUX_PANE=$1 \"$REPO_ROOT/scripts/agent-state.sh\" --agent $3 --state $2"
}

wait_for_env_value() {
    local key="$1" expected="$2"
    for _ in $(seq 1 40); do
        [ "$(get_env "$key")" = "$expected" ] && return 0
        sleep 0.05
    done
    return 1
}

setup_test_server "multi-pane-focus"
create_other_window
tmux_cmd set-option -g @agent-indicator-done-bg colour22

pane_a="$PANE"
pane_b="$(tmux_cmd split-window -d -P -F '#{pane_id}' -t "$PANE")"
tmux_cmd select-window -t ai:other

run_pane_state "$pane_a" running codex
run_pane_state "$pane_b" "done" claude
[ "$(get_window_option "$WIN" window-status-style)" = "bg=red,fg=black" ] \
    || fail "done title should be applied while away: $(get_window_option "$WIN" window-status-style)"

# Selecting the window focuses pane A (the window's active pane).
tmux_cmd select-window -t ai:main
tmux_cmd run-shell "$ROOT_DIR/scripts/pane-focus-in.sh \"$pane_a\" \"$WIN\""
wait_for_env_value "TMUX_AGENT_PANE_${pane_b}_STATE" "" || fail "done pane B should be acknowledged on window focus"

[ "$(get_env "TMUX_AGENT_PANE_${pane_a}_STATE")" = "running" ] || fail "running pane A state was wiped"
[ "$(get_env "TMUX_AGENT_PANE_${pane_a}_AGENT")" = "codex" ] || fail "running pane A agent was wiped"
assert_empty "$(get_window_option "$WIN" window-status-style)" "done title should clear on window focus"
[ "$(tmux_cmd show-options -pv -t "$pane_b" window-style)" = "bg=colour22" ] \
    || fail "pane B background should stay until pane B is focused"

tmux_cmd select-pane -t "$pane_b"
tmux_cmd run-shell "$ROOT_DIR/scripts/pane-focus-in.sh \"$pane_b\" \"$WIN\""
[ "$(tmux_cmd show-options -pv -t "$pane_b" window-style)" = "bg=default" ] \
    || fail "pane B background should reset on focus"
[ "$(get_env "TMUX_AGENT_PANE_${pane_a}_STATE")" = "running" ] || fail "focusing pane B wiped running pane A"

# A focused pane that is itself running is left alone too.
run_pane_state "$pane_b" needs-input claude
tmux_cmd select-pane -t "$pane_a"
tmux_cmd run-shell "$ROOT_DIR/scripts/pane-focus-in.sh \"$pane_a\" \"$WIN\""
[ "$(get_env "TMUX_AGENT_PANE_${pane_a}_STATE")" = "running" ] || fail "focusing running pane A wiped its state"
[ "$(get_env "TMUX_AGENT_PANE_${pane_b}_STATE")" = "needs-input" ] || fail "needs-input pane B was wiped by focus elsewhere"

# In the already-active window (no done title), focusing one done pane must
# leave another done pane's state, border and background intact until focused.
pane_c="$(tmux_cmd split-window -d -P -F '#{pane_id}' -t "$pane_a")"
run_pane_state "$pane_b" "done" claude
run_pane_state "$pane_c" "done" codex
tmux_cmd select-pane -t "$pane_b"
tmux_cmd run-shell "$ROOT_DIR/scripts/pane-focus-in.sh \"$pane_b\" \"$WIN\""
assert_empty "$(get_env "TMUX_AGENT_PANE_${pane_b}_STATE")" "focused done pane B should clear"
[ "$(get_env "TMUX_AGENT_PANE_${pane_c}_STATE")" = "done" ] || fail "unfocused done pane C state was wiped when focusing pane B"
[ "$(get_window_option "$WIN" pane-active-border-style)" = "fg=green,bold" ] \
    || fail "done border should stay while pane C is still unacknowledged: $(get_window_option "$WIN" pane-active-border-style)"
[ "$(tmux_cmd show-options -pv -t "$pane_c" window-style)" = "bg=colour22" ] \
    || fail "pane C background should stay until pane C is focused"
tmux_cmd select-pane -t "$pane_c"
tmux_cmd run-shell "$ROOT_DIR/scripts/pane-focus-in.sh \"$pane_c\" \"$WIN\""
assert_empty "$(get_env "TMUX_AGENT_PANE_${pane_c}_STATE")" "focused done pane C should clear"
assert_empty "$(get_window_option "$WIN" pane-active-border-style)" "border should restore once all done panes are focused"

pass "window focus acknowledges only done panes"
