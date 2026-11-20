#!/usr/bin/env bash
# '' skips a property, 'default' resets it, a disabled channel resets it.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/tests/lib/tmux-test-lib.sh"

trap cleanup_test_server EXIT

run_pane_state() {
    tmux_cmd run-shell "TMUX_PANE=$1 \"$REPO_ROOT/scripts/agent-state.sh\" --agent claude --state $2"
}

pane_bg() {
    tmux_cmd show-options -pv -t "$1" window-style 2>/dev/null || true
}

setup_test_server "empty-value-semantics"
create_other_window
agent_pane="$(tmux_cmd split-window -d -P -F '#{pane_id}' -t "$PANE")"
tmux_cmd select-window -t ai:other

# Empty values: nothing is applied.
for state in needs-input "done"; do
    tmux_cmd set -g "@agent-indicator-${state}-bg" ''
    tmux_cmd set -g "@agent-indicator-${state}-border" ''
    tmux_cmd set -g "@agent-indicator-${state}-window-title-bg" ''
done
tmux_cmd set-option -p -t "$agent_pane" window-style "bg=colour5"
tmux_cmd set-option -w -t "$WIN" pane-active-border-style "fg=blue"

for state in needs-input "done"; do
    run_pane_state "$agent_pane" "$state"
    [ "$(pane_bg "$agent_pane")" = "bg=colour5" ] || fail "'' bg should leave the pane background ($state): $(pane_bg "$agent_pane")"
    [ "$(get_window_option "$WIN" pane-active-border-style)" = "fg=blue" ] \
        || fail "'' border should leave the border ($state): $(get_window_option "$WIN" pane-active-border-style)"
    assert_empty "$(get_window_option "$WIN" window-status-style)" "'' title bg should skip title styling ($state)"
done
run_pane_state "$agent_pane" off

# 'default': background and border reset.
tmux_cmd set -g @agent-indicator-needs-input-bg 'colour52'
tmux_cmd set -g @agent-indicator-needs-input-border 'yellow'
tmux_cmd set -gu @agent-indicator-needs-input-window-title-bg
run_pane_state "$agent_pane" needs-input
[ "$(pane_bg "$agent_pane")" = "bg=colour52" ] || fail "needs-input bg should apply: $(pane_bg "$agent_pane")"
[ "$(get_window_option "$WIN" pane-active-border-style)" = "fg=yellow,bold" ] || fail "needs-input border should apply"
tmux_cmd set -g @agent-indicator-done-bg 'default'
tmux_cmd set -g @agent-indicator-done-border 'default'
run_pane_state "$agent_pane" "done"
[ "$(pane_bg "$agent_pane")" = "bg=default" ] || fail "'default' done bg should reset: $(pane_bg "$agent_pane")"
[ "$(get_window_option "$WIN" pane-active-border-style)" = "fg=blue" ] \
    || fail "'default' done border should restore the original: $(get_window_option "$WIN" pane-active-border-style)"
run_pane_state "$agent_pane" off

# Disabled channels reset, for done exactly like the other states.
tmux_cmd set -g @agent-indicator-done-bg 'colour22'
tmux_cmd set -g @agent-indicator-done-border 'green'
run_pane_state "$agent_pane" "done"
[ "$(pane_bg "$agent_pane")" = "bg=colour22" ] || fail "done bg should apply: $(pane_bg "$agent_pane")"
tmux_cmd set -g @agent-indicator-background-enabled off
tmux_cmd set -g @agent-indicator-border-enabled off
run_pane_state "$agent_pane" needs-input
run_pane_state "$agent_pane" "done"
[ "$(pane_bg "$agent_pane")" = "bg=default" ] || fail "disabled background should reset for done: $(pane_bg "$agent_pane")"
[ "$(get_window_option "$WIN" pane-active-border-style)" = "fg=blue" ] \
    || fail "disabled border should restore the original for done: $(get_window_option "$WIN" pane-active-border-style)"

pass "empty, default and disabled values for bg, border and title"
