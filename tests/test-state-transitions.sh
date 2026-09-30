#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/tests/lib/tmux-test-lib.sh"

trap cleanup_test_server EXIT

setup_test_server "state-transitions"

PANEL_PANE="$(tmux_cmd split-window -dP -F '#{pane_id}' -t "$PANE")"
tmux_cmd set-option -pt "$PANEL_PANE" @agent-indicator-panel 1
panel_channel="agent-indicator-panel-${PANEL_PANE#%}"
tmux_cmd wait-for "$panel_channel" \; set-environment -g PANEL_UPDATE_RECEIVED 1 &
panel_waiter=$!

rg -q -- '--state running --description-from-stdin' "$ROOT_DIR/hooks/codex-hooks.json" || fail "Codex prompt hook should capture the session description"
tmux_cmd run-shell "printf '%s' '{\"prompt\":\"Implement live status across panes\"}' | TMUX_PANE=$PANE \"$ROOT_DIR/scripts/agent-state.sh\" --agent codex --state running --description-from-stdin"
description="$(get_env "TMUX_AGENT_PANE_${PANE}_DESCRIPTION")"
[ "$description" = "Implement live status across panes" ] || fail "Codex prompt should become the pane description: $description"
for _ in $(seq 1 20); do
    [ "$(get_env PANEL_UPDATE_RECEIVED)" = "1" ] && break
    sleep 0.05
done
[ "$(get_env PANEL_UPDATE_RECEIVED)" = "1" ] || fail "agent hooks should signal every open panel"
wait "$panel_waiter"

run_state running
run_state needs-input
run_state "done"
run_state off

state_after="$(get_env "TMUX_AGENT_PANE_${PANE}_STATE")"
assert_empty "$state_after" "pane state should be cleared after off"
description_after="$(get_env "TMUX_AGENT_PANE_${PANE}_DESCRIPTION")"
assert_empty "$description_after" "pane description should be cleared after off"

indicator_after="$(run_indicator_capture "$PANE")"
assert_empty "$indicator_after" "indicator should be empty after off"

pass "state transitions running -> needs-input -> done -> off"
