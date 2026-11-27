#!/usr/bin/env bash
# User per-window styles must come back after the plugin styled the window.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/tests/lib/tmux-test-lib.sh"

trap cleanup_test_server EXIT

setup_test_server "window-option-restore"
create_other_window
tmux_cmd select-window -t ai:other

tmux_cmd set-option -w -t "$WIN" pane-active-border-style "fg=blue"
tmux_cmd set-option -w -t "$WIN" window-status-style "fg=magenta"
tmux_cmd set-option -w -t "$WIN" window-status-current-style "fg=cyan"

assert_user_styles() {
    local context="$1"
    [ "$(get_window_option "$WIN" pane-active-border-style)" = "fg=blue" ] \
        || fail "pane-active-border-style not restored after $context: $(get_window_option "$WIN" pane-active-border-style)"
    [ "$(get_window_option "$WIN" window-status-style)" = "fg=magenta" ] \
        || fail "window-status-style not restored after $context: $(get_window_option "$WIN" window-status-style)"
    [ "$(get_window_option "$WIN" window-status-current-style)" = "fg=cyan" ] \
        || fail "window-status-current-style not restored after $context: $(get_window_option "$WIN" window-status-current-style)"
}

run_state needs-input
[ "$(get_window_option "$WIN" pane-active-border-style)" = "fg=yellow,bold" ] \
    || fail "needs-input border should be applied: $(get_window_option "$WIN" pane-active-border-style)"
[ "$(get_window_option "$WIN" window-status-style)" = "bg=yellow,fg=black" ] \
    || fail "needs-input title should be applied: $(get_window_option "$WIN" window-status-style)"

run_state off
assert_user_styles "off"

run_state "done"
[ "$(get_window_option "$WIN" window-status-style)" = "bg=red,fg=black" ] \
    || fail "done title should be applied: $(get_window_option "$WIN" window-status-style)"
tmux_cmd select-window -t ai:main
tmux_cmd run-shell "$ROOT_DIR/scripts/pane-focus-in.sh \"$PANE\" \"$WIN\""
assert_user_styles "done focus reset"

# Windows without user styles go back to unset (inherit the global value).
tmux_cmd set-option -w -t "$WIN" -u pane-active-border-style
tmux_cmd set-option -w -t "$WIN" -u window-status-style
tmux_cmd set-option -w -t "$WIN" -u window-status-current-style
tmux_cmd select-window -t ai:other
run_state needs-input
run_state off
assert_empty "$(tmux_cmd show-options -wqv -t "$WIN" pane-active-border-style)" "unset border should stay unset"
assert_empty "$(tmux_cmd show-options -wqv -t "$WIN" window-status-style)" "unset title style should stay unset"

pass "user per-window styles are restored after needs-input/off and done focus reset"
