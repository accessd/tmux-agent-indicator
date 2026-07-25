#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/tests/lib/tmux-test-lib.sh"

trap cleanup_test_server EXIT

setup_test_server "pane-style-preserves-focus"

target_pane="$(tmux_cmd split-window -d -P -F '#{pane_id}' -t "$PANE")"
tmux_cmd set-option -g @agent-indicator-done-bg colour52
tmux_cmd resize-pane -Z -t "$PANE"

active_before="$(tmux_cmd display-message -p -t "$WIN" '#{pane_id}')"
zoom_before="$(tmux_cmd display-message -p -t "$WIN" '#{window_zoomed_flag}')"

tmux_cmd run-shell "TMUX_PANE=$target_pane \"$ROOT_DIR/scripts/agent-state.sh\" --agent claude --state done"

active_after="$(tmux_cmd display-message -p -t "$WIN" '#{pane_id}')"
zoom_after="$(tmux_cmd display-message -p -t "$WIN" '#{window_zoomed_flag}')"
target_style="$(tmux_cmd show-options -p -v -t "$target_pane" window-style)"

[ "$active_after" = "$active_before" ] || fail "styling changed active pane: $active_before -> $active_after"
[ "$zoom_after" = "$zoom_before" ] || fail "styling changed zoom state: $zoom_before -> $zoom_after"
[ "$target_style" = "bg=colour52" ] || fail "target pane style was not applied: $target_style"

tmux_cmd run-shell "TMUX_PANE=$target_pane \"$ROOT_DIR/scripts/agent-state.sh\" --agent claude --state off"

active_after="$(tmux_cmd display-message -p -t "$WIN" '#{pane_id}')"
zoom_after="$(tmux_cmd display-message -p -t "$WIN" '#{window_zoomed_flag}')"
target_style="$(tmux_cmd show-options -p -v -t "$target_pane" window-style)"

[ "$active_after" = "$active_before" ] || fail "reset changed active pane: $active_before -> $active_after"
[ "$zoom_after" = "$zoom_before" ] || fail "reset changed zoom state: $zoom_before -> $zoom_after"
[ "$target_style" = "bg=default" ] || fail "target pane style was not reset: $target_style"

pass "pane styling preserves active pane and zoom"
