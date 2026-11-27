#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/tests/lib/tmux-test-lib.sh"

trap cleanup_test_server EXIT

setup_test_server "indicator-output"

tmux_cmd set -g status-right '#{agent_limits} #{agent_indicator}'
tmux_cmd run-shell "$ROOT_DIR/agent-indicator.tmux"
status_right=$(tmux_cmd show-option -gqv status-right)
case "$status_right" in
    *agent-limits.sh*"indicator.sh '#{pane_id}'"*) ;;
    *) fail "status interpolation should include agent limits and indicator: $status_right" ;;
esac

run_state running
indicator_running="$(run_indicator_capture "$PANE")"
assert_non_empty "$indicator_running" "indicator should be non-empty for running state"

run_state off
indicator_off="$(run_indicator_capture "$PANE")"
assert_empty "$indicator_off" "indicator should be empty after off"

tmux_cmd set -g @agent-indicator-icons 'claude=AGENT'
tmux_cmd set -g @agent-indicator-state-icons 'running=RUN, needs-input=ASK'

run_state running
indicator_state_icon="$(run_indicator_capture "$PANE")"
case "$indicator_state_icon" in
    *RUN*) ;;
    *) fail "state icon should override agent icon for running: $indicator_state_icon" ;;
esac

run_state "done"
indicator_agent_fallback="$(run_indicator_capture "$PANE")"
case "$indicator_agent_fallback" in
    *AGENT*) ;;
    *) fail "agent icon should be used for states without a state icon: $indicator_agent_fallback" ;;
esac

run_state off

# The status line passes `#{pane_id}`: the indicator renders exactly that pane,
# whatever pane tmux considers current for the (client-less) status job.
create_other_window
tmux_cmd run-shell "TMUX_PANE=$OTHER_PANE \"$ROOT_DIR/scripts/agent-state.sh\" --agent claude --state running"
indicator_arg_pane="$(run_indicator_capture "$PANE" "$OTHER_PANE")"
case "$indicator_arg_pane" in
    *RUN*) ;;
    *) fail "pane id argument should select the pane to render: $indicator_arg_pane" ;;
esac
indicator_arg_main="$(run_indicator_capture "$OTHER_PANE" "$PANE")"
assert_empty "$indicator_arg_main" "pane id argument should not show another window's state"
indicator_bad_arg="$(run_indicator_capture "$PANE" '%99999')"
assert_empty "$indicator_bad_arg" "unknown pane id should render nothing"
tmux_cmd run-shell "TMUX_PANE=$OTHER_PANE \"$ROOT_DIR/scripts/agent-state.sh\" --agent claude --state off"

# Process detection matches the executable name, not any command-line word.
tmux_cmd set -g @agent-indicator-icons 'claude=CLAUDE,codex=CODEX,default=DEF'
tmux_cmd set -g @agent-indicator-state-icons ''
printf 'read -t 300\n' > "$TEST_TMP_DIR/claude"
printf 'read -t 300\n' > "$TEST_TMP_DIR/codex"

start_proc_pane() {
    local name="$1"
    local cmd="$2"
    tmux_cmd new-window -d -P -F '#{pane_id}' -t ai -n "$name" bash -c "$cmd"
}

wait_for_indicator() {
    local pane_id="$1"
    local out=""
    for _ in $(seq 1 40); do
        out="$(run_indicator_capture "$pane_id" "$pane_id")"
        if [ -n "$out" ]; then
            printf '%s' "$out"
            return 0
        fi
        sleep 0.1
    done
    return 1
}

# argv[0] is the agent: `claude ...`
argv0_pane="$(start_proc_pane proc-argv0 "exec -a claude bash -c 'read -t 300'")"
argv0_out="$(wait_for_indicator "$argv0_pane" || true)"
[ "$argv0_out" = "CLAUDE" ] || fail "argv[0] basename should be detected as claude: '$argv0_out'"

# interpreter running the agent script: `node /path/codex` and versioned `python3.12 /path/claude`
node_pane="$(start_proc_pane proc-node "exec -a node bash '$TEST_TMP_DIR/codex'")"
node_out="$(wait_for_indicator "$node_pane" || true)"
[ "$node_out" = "CODEX" ] || fail "interpreter script basename should be detected as codex: '$node_out'"

py_pane="$(start_proc_pane proc-py "exec -a python3.12 bash '$TEST_TMP_DIR/claude'")"
py_out="$(wait_for_indicator "$py_pane" || true)"
[ "$py_out" = "CLAUDE" ] || fail "versioned python interpreter script basename should be detected as claude: '$py_out'"

# an agent name that is merely an argument of another program is not an agent
editor_pane="$(start_proc_pane proc-editor "exec -a vim bash '$TEST_TMP_DIR/claude'")"
sleep 0.5
editor_out="$(run_indicator_capture "$editor_pane" "$editor_pane")"
assert_empty "$editor_out" "a program merely taking claude as an argument is not an agent"

pass "indicator output for running/off, state icons, pane argument and process detection"
