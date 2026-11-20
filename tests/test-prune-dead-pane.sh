#!/usr/bin/env bash
# Closing a pane drops its agent state, restores window styling it caused and
# lets the running animation exit.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/tests/lib/tmux-test-lib.sh"

trap cleanup_test_server EXIT

run_pane_state() {
    tmux_cmd run-shell "TMUX_PANE=$1 \"$REPO_ROOT/scripts/agent-state.sh\" --agent $3 --state $2"
}

wait_until() {
    for _ in $(seq 1 60); do
        if "$@"; then
            return 0
        fi
        sleep 0.05
    done
    return 1
}

pane_keys() {
    tmux_cmd show-environment -g 2>/dev/null | grep -F "TMUX_AGENT_PANE_$1_" || true
}

no_pane_keys() {
    [ -z "$(pane_keys "$1")" ]
}

env_empty() {
    [ -z "$(get_env "$1")" ]
}

title_unset() {
    [ -z "$(get_window_option "$WIN" window-status-style)" ]
}

# Treat zombie ('Z') processes as exited: in PID namespaces whose PID 1 does
# not reap orphans, kill -0 still succeeds on a defunct animation process.
pid_exited() {
    local pid="$1" stat
    kill -0 "$pid" 2>/dev/null || return 0
    stat=$(ps -o stat= -p "$pid" 2>/dev/null | tr -d '[:space:]' || true)
    [ -n "$stat" ] || return 0
    case "$stat" in
        Z*) return 0 ;;
    esac
    return 1
}

setup_test_server "prune-dead-pane"
create_other_window
tmux_cmd set -g @agent-indicator-animation-enabled "on"
tmux_cmd set -g @agent-indicator-animation-speed "50"

# kill-pane of a running pane: state pruned, animation exits.
running_pane="$(tmux_cmd split-window -d -P -F '#{pane_id}' -t "$PANE")"
run_pane_state "$running_pane" running claude
anim_pid="$(wait_for_non_empty_env "TMUX_AGENT_ANIMATION_PID" 40 0.05 || true)"
assert_non_empty "$anim_pid" "animation should start"
tmux_cmd kill-pane -t "$running_pane"
wait_until no_pane_keys "$running_pane" || fail "state of killed pane was not pruned: $(pane_keys "$running_pane")"
wait_until env_empty "TMUX_AGENT_ANIMATION_PID" || fail "animation PID should clear after the running pane is killed"
wait_until env_empty "TMUX_AGENT_ANIMATION_FRAME" || fail "animation frame should clear after the running pane is killed"
wait_until pid_exited "$anim_pid" || fail "animation process should exit after the running pane is killed"

# A pane whose process exits: window styling it caused is restored.
tmux_cmd select-window -t ai:other
exiting_pane="$(tmux_cmd split-window -d -P -F '#{pane_id}' -t "$PANE" 'sleep 1')"
run_pane_state "$exiting_pane" needs-input codex
[ "$(get_window_option "$WIN" window-status-style)" = "bg=yellow,fg=black" ] \
    || fail "needs-input title should be applied: $(get_window_option "$WIN" window-status-style)"
wait_until no_pane_keys "$exiting_pane" || fail "state of exited pane was not pruned: $(pane_keys "$exiting_pane")"
wait_until title_unset || fail "window title should be restored after the pane exits"
assert_empty "$(get_window_option "$WIN" pane-active-border-style)" "border should be restored after the pane exits"

# Stale state left by a pane closed without hooks is ignored by the animation
# and pruned by the plugin (re)load.
tmux_cmd set-environment -g "TMUX_AGENT_PANE_%999_STATE" running
tmux_cmd set-environment -g "TMUX_AGENT_PANE_%999_AGENT" claude
tmux_cmd set-environment -g "TMUX_AGENT_WINDOW_@999_ORIG_STATUS_STYLE" "__UNSET__"
tmux_cmd run-shell "TMUX_PANE=$PANE \"$REPO_ROOT/scripts/animation.sh\""
assert_empty "$(get_env "TMUX_AGENT_ANIMATION_PID")" "animation should not run for a dead pane"
assert_empty "$(pane_keys "%999")" "animation exit should prune the dead pane"
assert_empty "$(get_env "TMUX_AGENT_WINDOW_@999_ORIG_STATUS_STYLE")" "keys of a closed window should be pruned"

tmux_cmd set-environment -g "TMUX_AGENT_PANE_%998_STATE" "done"
tmux_cmd run-shell "$REPO_ROOT/agent-indicator.tmux"
assert_empty "$(pane_keys "%998")" "plugin reload should prune state of closed panes"

pass "closed panes are pruned and the animation exits"
