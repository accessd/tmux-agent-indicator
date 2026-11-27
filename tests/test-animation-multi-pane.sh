#!/usr/bin/env bash
# The global running animation must survive another pane leaving running and
# stop once no live pane is running.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/tests/lib/tmux-test-lib.sh"

trap cleanup_test_server EXIT

run_pane_state() {
    tmux_cmd run-shell "TMUX_PANE=$1 \"$REPO_ROOT/scripts/agent-state.sh\" --agent $3 --state $2"
}

wait_for_empty_env() {
    local key="$1"
    for _ in $(seq 1 40); do
        [ -z "$(get_env "$key")" ] && return 0
        sleep 0.05
    done
    return 1
}

setup_test_server "animation-multi-pane"
tmux_cmd set -g @agent-indicator-animation-enabled "on"
tmux_cmd set -g @agent-indicator-animation-speed "50"

pane_a="$PANE"
pane_b="$(tmux_cmd split-window -d -P -F '#{pane_id}' -t "$PANE")"

run_pane_state "$pane_a" running codex
anim_pid="$(wait_for_non_empty_env "TMUX_AGENT_ANIMATION_PID" 40 0.05 || true)"
assert_non_empty "$anim_pid" "animation should start for running pane A"

for state in needs-input "done" off; do
    run_pane_state "$pane_b" running claude
    run_pane_state "$pane_b" "$state" claude
    sleep 0.2
    [ "$(get_env "TMUX_AGENT_ANIMATION_PID")" = "$anim_pid" ] || fail "animation PID changed or cleared after pane B $state"
    kill -0 "$anim_pid" 2>/dev/null || fail "animation process died after pane B $state"
    assert_non_empty "$(get_env "TMUX_AGENT_ANIMATION_FRAME")" "animation frame should stay while pane A runs (B $state)"
done

run_pane_state "$pane_a" "done" codex
wait_for_empty_env "TMUX_AGENT_ANIMATION_PID" || fail "animation PID should clear once nothing runs"
wait_for_empty_env "TMUX_AGENT_ANIMATION_FRAME" || fail "animation frame should clear once nothing runs"

pass "animation survives other panes leaving running"
