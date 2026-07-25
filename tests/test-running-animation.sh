#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/tests/lib/tmux-test-lib.sh"

trap cleanup_test_server EXIT

setup_test_server "running-animation"

tmux_cmd set -g @agent-indicator-animation-enabled "on"
tmux_cmd set -g @agent-indicator-animation-speed "80"

run_state running

anim_pid="$(wait_for_non_empty_env "TMUX_AGENT_ANIMATION_PID" 20 0.05 || true)"
assert_non_empty "$anim_pid" "animation PID should be created for running state"

first_frame="$(wait_for_non_empty_env "TMUX_AGENT_ANIMATION_FRAME" 20 0.05 || true)"
assert_non_empty "$first_frame" "animation frame should be set while running"

indicator_output="$(run_indicator_capture "$PANE")"
printf '%s' "$indicator_output" | rg -q "━" || fail \
    "status indicator should include animation bar while running"

changed=0
for _ in $(seq 1 20); do
    sleep 0.1
    next_frame="$(get_env "TMUX_AGENT_ANIMATION_FRAME")"
    if [ -n "$next_frame" ] && [ "$next_frame" != "$first_frame" ]; then
        changed=1
        break
    fi
done
[ "$changed" -eq 1 ] || fail "animation frame did not change"

run_state "done"
sleep 0.2

anim_pid_after="$(get_env "TMUX_AGENT_ANIMATION_PID")"
frame_after="$(get_env "TMUX_AGENT_ANIMATION_FRAME")"

assert_empty "$anim_pid_after" "animation PID should clear after done"
assert_empty "$frame_after" "animation frame should clear after done"

pass "running animation ticks and cleans up"
