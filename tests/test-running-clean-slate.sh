#!/usr/bin/env bash
# running starts a clean slate for its pane (no separate `off` hook needed),
# repeated running reports take a fast path, and the notification command does
# not hold the hook's output open.

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

setup_test_server "running-clean-slate"
agent_pane="$(tmux_cmd split-window -d -P -F '#{pane_id}' -t "$PANE")"
tmux_cmd set -g @agent-indicator-done-bg colour22
tmux_cmd set -g @agent-indicator-needs-input-bg colour52
tmux_cmd set -g @agent-indicator-running-bg ''

# Done/needs-input tint the pane while the user is elsewhere; the user then
# answers from that pane without a focus hook firing.
for state in "done" needs-input; do
    run_pane_state "$agent_pane" "$state"
    [ "$(pane_bg "$agent_pane")" != "bg=default" ] || fail "$state background should be applied"
    tmux_cmd set-hook -gu after-select-pane
    tmux_cmd set-hook -gu pane-focus-in
    tmux_cmd select-pane -t "$agent_pane"
    run_pane_state "$agent_pane" running
    [ "$(pane_bg "$agent_pane")" = "bg=default" ] || fail "running after $state should reset the background: $(pane_bg "$agent_pane")"
    assert_empty "$(get_env "TMUX_AGENT_PANE_${agent_pane}_PENDING_RESET")" "running after $state should drop the pending reset"
    assert_empty "$(get_window_option "$WIN" pane-active-border-style)" "running after $state should restore the border"
    [ "$(get_env "TMUX_AGENT_PANE_${agent_pane}_STATE")" = "running" ] || fail "state should be running after $state"
    tmux_cmd select-pane -t "$PANE"
done

# Repeated running (PostToolUse) is a no-op: the full path would reset the
# unfocused pane to the default running background.
tmux_cmd set -gu @agent-indicator-running-bg
tmux_cmd set-option -p -t "$agent_pane" window-style "bg=colour9"
run_pane_state "$agent_pane" running
[ "$(pane_bg "$agent_pane")" = "bg=colour9" ] || fail "repeated running should take the fast path: $(pane_bg "$agent_pane")"

# needs-input -> running (permission approved) clears needs-input visuals.
run_pane_state "$agent_pane" needs-input
[ "$(get_window_option "$WIN" pane-active-border-style)" = "fg=yellow,bold" ] || fail "needs-input border should apply"
run_pane_state "$agent_pane" running
assert_empty "$(get_window_option "$WIN" pane-active-border-style)" "running after approval should restore the border"

# The notification command runs detached from the hook's stdio.
tmux_cmd set -g @agent-indicator-notification-command 'sleep 3'
start=$(date +%s)
run_pane_state "$agent_pane" needs-input
elapsed=$(( $(date +%s) - start ))
[ "$elapsed" -lt 2 ] || fail "notification command held the hook open for ${elapsed}s"

pass "running clean slate, fast path and detached notification command"
