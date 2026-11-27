#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/tests/lib/tmux-test-lib.sh"

trap cleanup_test_server EXIT

setup_test_server "session-attention"

tmux_cmd new-session -d -s build -n main
BUILD_PANE="$(tmux_cmd display-message -p -t build:main.0 '#{pane_id}')"

attention() {
    local out_file
    out_file="$(new_tmp_file)"
    tmux_cmd run-shell "\"$REPO_ROOT/scripts/session-attention.sh\" $* > \"$out_file\""
    cat "$out_file" 2>/dev/null || true
}

run_build_state() {
    tmux_cmd run-shell "TMUX_PANE=$BUILD_PANE \"$REPO_ROOT/scripts/agent-state.sh\" --agent omp --state $1"
}

TAB=$'\t'

assert_empty "$(attention)" "no session should need attention before any state"
[ "$(attention --color colour4)" = "colour4" ] || fail "--color should print the fallback when nothing needs attention"

run_state running
assert_empty "$(attention)" "running is not an attention state"

run_state needs-input
[ "$(attention)" = "ai${TAB}needs-input${TAB}yellow${TAB}black" ] || fail "needs-input session line: $(attention)"
assert_empty "$(attention --exclude ai)" "--exclude should drop the session"
[ "$(attention --exclude ai --color colour4)" = "colour4" ] || fail "--color should ignore excluded sessions"

run_build_state "done"
[ "$(attention --exclude ai)" = "build${TAB}done${TAB}red${TAB}black" ] || fail "done session line: $(attention --exclude ai)"
[ "$(attention --color colour4)" = "yellow" ] || fail "needs-input should outrank done for --color"

tmux_cmd set -g @agent-indicator-done-window-title-bg 'colour1'
tmux_cmd set -g @agent-indicator-done-window-title-fg 'colour15'
[ "$(attention --exclude ai)" = "build${TAB}done${TAB}colour1${TAB}colour15" ] || fail "configured title colours should be reported: $(attention --exclude ai)"

tmux_cmd set-environment -g TMUX_AGENT_SESSION_SEEN_build 1
assert_empty "$(attention --exclude ai)" "a seen session should not need attention"

run_build_state needs-input
[ "$(attention --exclude ai)" = "build${TAB}needs-input${TAB}yellow${TAB}black" ] || fail "a new state should clear the seen marker: $(attention --exclude ai)"

tmux_cmd set -g @agent-indicator-session-dots-attention-states 'done'
assert_empty "$(attention)" "only configured attention states should count"

run_state off
run_build_state off

pass "session attention listing, ranking, colours, exclusion and seen markers"
