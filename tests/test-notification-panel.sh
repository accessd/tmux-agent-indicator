#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/tmux-test-lib.sh
source "$ROOT_DIR/tests/lib/tmux-test-lib.sh"

test_dir="$(mktemp -d)"
store_bin="$test_dir/agent-store"
store_dir="$test_dir/store"
(cd "$ROOT_DIR" && env -u GOROOT go build -o "$store_bin" ./cmd/agent-store)
cleanup() {
    TMUX_AGENT_STORE_DIR="$store_dir" "$store_bin" stop >/dev/null 2>&1 || true
    cleanup_test_server
    rm -rf "$test_dir"
}
trap cleanup EXIT
project_a="$test_dir/project-a"
project_b="$test_dir/project-b"
mkdir -p "$project_a" "$project_b"

setup_test_server "notification-panel"
tmux_cmd rename-window -t "$WIN" z-needs
create_other_window
tmux_cmd rename-window -t "$OTHER_WIN" a-done
WINDOW_PEER_PANE="$(tmux_cmd split-window -dP -F '#{pane_id}' -t "$OTHER_PANE")"

RUNNING_PANE="$(tmux_cmd new-window -dP -F '#{pane_id}' -t ai -n n-running)"
IDLE_OFF_PANE="$(tmux_cmd new-window -dP -F '#{pane_id}' -t ai -n a-idle-off)"
IDLE_MISMATCH_PANE="$(tmux_cmd new-window -dP -F '#{pane_id}' -t ai -n b-idle-mismatch)"
STALE_HOOK_PANE="$(tmux_cmd new-window -dP -F '#{pane_id}' -t ai -n stale-hook)"
PI_PANE="$(tmux_cmd -f /dev/null new-session -dP -F '#{pane_id}' -s beta -n c-idle-missing)"

tmux_cmd respawn-pane -k -c "$project_a" -t "$PANE"
tmux_cmd respawn-pane -k -c "$project_b" -t "$OTHER_PANE"
tmux_cmd respawn-pane -k -c "$project_b" -t "$WINDOW_PEER_PANE"
tmux_cmd respawn-pane -k -c "$project_a" -t "$RUNNING_PANE"
tmux_cmd respawn-pane -k -c "$project_b" -t "$IDLE_OFF_PANE"
tmux_cmd respawn-pane -k -c "$project_a" -t "$IDLE_MISMATCH_PANE"
tmux_cmd respawn-pane -k -c "$project_b" -t "$PI_PANE"

tmux_cmd set-environment -g "TMUX_AGENT_PANE_${PANE}_STATE" needs-input
tmux_cmd set-environment -g "TMUX_AGENT_PANE_${PANE}_AGENT" claude
tmux_cmd set-environment -g "TMUX_AGENT_PANE_${OTHER_PANE}_STATE" "done"
tmux_cmd set-environment -g "TMUX_AGENT_PANE_${OTHER_PANE}_AGENT" codex
tmux_cmd set-environment -g "TMUX_AGENT_PANE_${OTHER_PANE}_DESCRIPTION" "Implement live status across panes"
tmux_cmd set-environment -g "TMUX_AGENT_PANE_${WINDOW_PEER_PANE}_STATE" running
tmux_cmd set-environment -g "TMUX_AGENT_PANE_${WINDOW_PEER_PANE}_AGENT" claude
tmux_cmd set-environment -g "TMUX_AGENT_PANE_${RUNNING_PANE}_STATE" running
tmux_cmd set-environment -g "TMUX_AGENT_PANE_${RUNNING_PANE}_AGENT" opencode
tmux_cmd set-environment -g "TMUX_AGENT_PANE_${IDLE_OFF_PANE}_STATE" off
tmux_cmd set-environment -g "TMUX_AGENT_PANE_${IDLE_OFF_PANE}_AGENT" cursor
tmux_cmd set-environment -g "TMUX_AGENT_PANE_${IDLE_MISMATCH_PANE}_STATE" "done"
tmux_cmd set-environment -g "TMUX_AGENT_PANE_${IDLE_MISMATCH_PANE}_AGENT" claude
tmux_cmd set-environment -g "TMUX_AGENT_PANE_${STALE_HOOK_PANE}_STATE" needs-input
tmux_cmd set-environment -g "TMUX_AGENT_PANE_${STALE_HOOK_PANE}_AGENT" claude
tmux_cmd select-pane -t "$PANE" -T "✳ Review nodes API questions"
tmux_cmd select-pane -t "$OTHER_PANE" -T "⠋ Fix deployment headers"
tmux_cmd select-pane -t "$WINDOW_PEER_PANE" -T "Review release notes"
tmux_cmd select-pane -t "$RUNNING_PANE" -T "Refactor release workflow"
tmux_cmd select-pane -t "$IDLE_OFF_PANE" -T "$(hostname -s)"
tmux_cmd select-pane -t "$PI_PANE" -T "π - accessd"
tmux_cmd set-option -g @agent-indicator-pinned-panes "$PI_PANE"

binding="$(tmux_cmd list-keys -T root | rg 'M-i.*run-shell')"
for expected in run-shell toggle-panel.sh '#{pane_id}'; do
    case "$binding" in
        *"$expected"*) ;;
        *) fail "Alt+i binding should contain $expected: $binding" ;;
    esac
done
case "$binding" in
    *'notification-panel.sh --all'*) fail "Alt+i should default to the current tmux session" ;;
    *display-popup*) fail "Alt+i should open a tmux pane, not a popup" ;;
esac

all_binding="$(tmux_cmd list-keys -T root | rg 'M-I.*run-shell')"
for expected in run-shell toggle-panel.sh '#{pane_id}' --all; do
    case "$all_binding" in
        *"$expected"*) ;;
        *) fail "Alt+Shift+i binding should contain $expected: $all_binding" ;;
    esac
done

real_tmux="$(command -v tmux)"
capture="$test_dir/fzf-input"
current_capture="$test_dir/fzf-current-input"
bash3_capture="$test_dir/bash3-input"
state_change_capture="$test_dir/state-change-input"
color_capture="$test_dir/color-input"
plain_capture="$test_dir/plain-input"
fzf_args="$test_dir/fzf-args"
command_log="$test_dir/tmux-commands"
ps_map="$test_dir/ps-map"
ps_call_log="$test_dir/ps-calls"

pane_tty() {
    tmux_cmd display-message -p -t "$1" '#{pane_tty}'
}

map_process() {
    local pane_id="$1"
    local agent="$2"
    local tty
    tty="$(pane_tty "$pane_id")"
    printf '%s\t%s\n' "${tty##*/}" "$agent" >> "$ps_map"
}

map_process "$PANE" claude
map_process "$OTHER_PANE" codex
map_process "$WINDOW_PEER_PANE" claude
map_process "$RUNNING_PANE" opencode
map_process "$IDLE_OFF_PANE" cursor
map_process "$IDLE_MISMATCH_PANE" aider
map_process "$STALE_HOOK_PANE" codex
map_process "$PI_PANE" pi

cat > "$test_dir/fzf" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "--help" ]; then
    printf '%s\n' '--read0' '--id-nth'
    exit
fi
if [ -n "${FZF_HOLD_FILE:-}" ]; then
    : > "${FZF_HOLD_FILE}.ready"
    while [ -e "$FZF_HOLD_FILE" ]; do
        sleep 0.02
    done
    exit 130
fi
printf '%s\n' "$*" > "$FZF_ARGS"
: > "$FZF_CAPTURE"
first=""
while IFS= read -r -d '' item; do
    printf '%s\0' "$item" >> "$FZF_CAPTURE"
    if [ -z "$first" ]; then
        first="$item"
    fi
done
first_line="${first%%$'\n'*}"
IFS=$'\t' read -r pane_id session_id window_id _ <<< "$first_line"
printf '%s\t%s\t%s\n' "$pane_id" "$session_id" "$window_id"
EOF

cat > "$test_dir/ps" <<'EOF'
#!/usr/bin/env bash
if [ -n "${PS_CALL_LOG:-}" ]; then
    printf '%s\n' "$*" >> "$PS_CALL_LOG"
fi
if [ "${1:-}" = "-ax" ]; then
    awk -F '\t' '{ print $1, $2 }' "$PS_MAP"
    exit
fi
tty=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        -t)
            tty="$2"
            shift 2
            ;;
        *) shift ;;
    esac
done
awk -F '\t' -v tty="$tty" '$1 == tty { print $2 }' "$PS_MAP"
EOF

cat > "$test_dir/tmux" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TMUX_COMMAND_LOG"
if [ "$1" = "switch-client" ]; then
    exit 0
fi
exec "$REAL_TMUX" "$@"
EOF
chmod +x "$test_dir/fzf" "$test_dir/ps" "$test_dir/tmux"

sidebar_hold="$test_dir/sidebar-hold"
touch "$sidebar_hold"
server_path="$(tmux_cmd show-environment -g PATH | sed 's/^PATH=//')"
tmux_cmd set-environment -g PATH "$test_dir:$server_path"
tmux_cmd set-environment -g REAL_TMUX "$real_tmux"
tmux_cmd set-environment -g FZF_HOLD_FILE "$sidebar_hold"
tmux_cmd set-environment -g TMUX_COMMAND_LOG "$command_log"
tmux_cmd set-environment -g TMUX_AGENT_STORE_BIN "$store_bin"
tmux_cmd set-environment -g TMUX_AGENT_STORE_DIR "$store_dir"
tmux_cmd set-environment -g TMUX_AGENT_INDICATOR_DIR "$ROOT_DIR"
tmux_cmd run-shell -t "$PANE" "PATH=\"$test_dir:/usr/bin:/bin\" TMUX_PANE=\"$PANE\" REAL_TMUX=\"$real_tmux\" TMUX_COMMAND_LOG=\"$command_log\" PS_MAP=\"$ps_map\" PS_CALL_LOG=\"$ps_call_log\" /bin/bash \"$ROOT_DIR/scripts/notification-panel.sh\" --list >/dev/null"
[ ! -s "$ps_call_log" ] || fail "rendering a panel should read the shared store without a process snapshot"
full_height="$(tmux_cmd display-message -p -t "$PANE" '#{pane_height}')"
layout_sibling="$(tmux_cmd split-window -dP -F '#{pane_id}' -t "$PANE")"
layout_before="$(tmux_cmd display-message -p -t "$PANE" '#{window_layout}')"
session_window_count="$(tmux_cmd list-windows -t ai -F '#{window_id}' | wc -l | tr -d ' ')"
tmux_cmd run-shell -t "$PANE" "\"$ROOT_DIR/scripts/toggle-panel.sh\" \"$PANE\""
for _ in $(seq 1 20); do
    panel_pane="$(tmux_cmd list-panes -t "$WIN" -F $'#{pane_id}\t#{@agent-indicator-panel}' | awk -F '\t' '$2 == "1" { print $1; exit }')"
    [ -n "$panel_pane" ] && break
    sleep 0.05
done
[ -n "$panel_pane" ] || fail "Alt+i should open an agent sessions pane"
[ "$(tmux_cmd display-message -p -t "$panel_pane" '#{pane_active}')" = "1" ] || fail "agent sessions pane should receive keyboard focus"
[ "$(tmux_cmd display-message -p -t "$panel_pane" '#{pane_left}')" = "0" ] || fail "agent sessions pane should be on the left"
[ "$(tmux_cmd display-message -p -t "$panel_pane" '#{pane_width}')" = "42" ] || fail "agent sessions pane should be 42 columns wide"
[ "$(tmux_cmd display-message -p -t "$panel_pane" '#{pane_height}')" = "$full_height" ] || fail "agent sessions pane should span the full window height"
[ "$(tmux_cmd list-panes -s -t ai -F '#{@agent-indicator-panel}' | rg -c '^1$')" = "$session_window_count" ] || fail "Alt+i should open one panel in every window of the current session"
[ -z "$(tmux_cmd list-panes -s -t beta -F '#{@agent-indicator-panel}' | rg '^1$' || true)" ] || fail "Alt+i should not open panels in other sessions"
[ "$(wc -l < "$ps_call_log" | tr -d ' ')" = "1" ] || fail "opening every panel in a session should take one shared process snapshot"
tmux_cmd run-shell -t "$PANE" "\"$ROOT_DIR/scripts/toggle-panel.sh\" \"$PANE\""
for _ in $(seq 1 20); do
    panel_marker="$(tmux_cmd list-panes -t "$WIN" -F '#{@agent-indicator-panel}' | rg '^1$' || true)"
    [ -z "$panel_marker" ] && break
    sleep 0.05
done
[ -z "$panel_marker" ] || fail "Alt+i should close the existing agent sessions pane"
[ -z "$(tmux_cmd list-panes -s -t ai -F '#{@agent-indicator-panel}' | rg '^1$' || true)" ] || fail "Alt+i should close every panel in the current session"
[ "$(tmux_cmd display-message -p -t "$PANE" '#{window_layout}')" = "$layout_before" ] || fail "closing the agent sessions pane should restore the previous layout"

server_window_count="$(tmux_cmd list-windows -a -F '#{window_id}' | sort -u | wc -l | tr -d ' ')"
tmux_cmd run-shell -t "$PANE" "\"$ROOT_DIR/scripts/toggle-panel.sh\" \"$PANE\" --all"
for _ in $(seq 1 20); do
    server_panel_count="$(tmux_cmd list-panes -a -F '#{@agent-indicator-panel}' | rg -c '^1$' || true)"
    [ "$server_panel_count" = "$server_window_count" ] && break
    sleep 0.05
done
[ "$server_panel_count" = "$server_window_count" ] || fail "Alt+Shift+i should open one panel in every window on the tmux server"
[ "$(wc -l < "$ps_call_log" | tr -d ' ')" = "2" ] || fail "each panel set should take one shared process snapshot"
tmux_cmd run-shell -t "$PANE" "\"$ROOT_DIR/scripts/toggle-panel.sh\" \"$PANE\" --all"
[ -z "$(tmux_cmd list-panes -a -F '#{@agent-indicator-panel}' | rg '^1$' || true)" ] || fail "Alt+Shift+i should close every panel on the tmux server"
snapshot_command="$(rg '^list-panes -a .*pane_tty' "$command_log" | head -n1)"
for field in pane_id pane_tty session_id session_name window_id window_name pane_index pane_current_path pane_title; do
    case "$snapshot_command" in
        *"#{$field}"*) ;;
        *) fail "shared pane snapshot should include $field: $snapshot_command" ;;
    esac
done
tmux_cmd kill-pane -t "$layout_sibling"
rm -f "$sidebar_hold"
tmux_cmd set-environment -g PATH "$server_path"
tmux_cmd set-environment -gu REAL_TMUX
tmux_cmd set-environment -gu FZF_HOLD_FILE
tmux_cmd set-environment -gu TMUX_COMMAND_LOG
: > "$command_log"
: > "$ps_call_log"
capture_item_width=$(($(tmux_cmd display-message -p -t "$PANE" '#{pane_width}') - 3))

tmux_cmd run-shell -t "$PANE" "PATH=\"$test_dir:\$PATH\" TMUX_PANE=\"$PANE\" REAL_TMUX=\"$real_tmux\" FZF_ARGS=\"$fzf_args\" FZF_CAPTURE=\"$current_capture\" TMUX_COMMAND_LOG=\"$command_log\" PS_MAP=\"$ps_map\" PS_CALL_LOG=\"$ps_call_log\" \"$ROOT_DIR/scripts/notification-panel.sh\""

tmux_cmd run-shell -t "$PANE" "PATH=\"$test_dir:\$PATH\" TMUX_PANE=\"$PANE\" REAL_TMUX=\"$real_tmux\" FZF_ARGS=\"$fzf_args\" FZF_CAPTURE=\"$capture\" TMUX_COMMAND_LOG=\"$command_log\" PS_MAP=\"$ps_map\" PS_CALL_LOG=\"$ps_call_log\" \"$ROOT_DIR/scripts/notification-panel.sh\" --all"

tmux_cmd set-option -g @agent-indicator-panel-needs-input-color magenta
tmux_cmd set-option -g @agent-indicator-panel-done-color colour45
tmux_cmd set-option -g @agent-indicator-panel-running-color brightblue
tmux_cmd set-option -g @agent-indicator-panel-needs-input-bg magenta
tmux_cmd set-option -g @agent-indicator-panel-done-bg colour22
tmux_cmd set-option -g @agent-indicator-panel-running-bg brightblue
tmux_cmd set-option -g @agent-indicator-panel-needs-input-fg brightwhite
tmux_cmd set-option -g @agent-indicator-panel-done-fg white
tmux_cmd set-option -g @agent-indicator-panel-running-fg black
tmux_cmd run-shell -t "$PANE" "PATH=\"$test_dir:/usr/bin:/bin\" TMUX_PANE=\"$PANE\" REAL_TMUX=\"$real_tmux\" TMUX_COMMAND_LOG=\"$command_log\" PS_MAP=\"$ps_map\" PS_CALL_LOG=\"$ps_call_log\" /bin/bash \"$ROOT_DIR/scripts/notification-panel.sh\" --all --list > \"$color_capture\""
tmux_cmd set-option -gu @agent-indicator-panel-needs-input-color
tmux_cmd set-option -gu @agent-indicator-panel-done-color
tmux_cmd set-option -gu @agent-indicator-panel-running-color
tmux_cmd set-option -gu @agent-indicator-panel-needs-input-bg
tmux_cmd set-option -gu @agent-indicator-panel-done-bg
tmux_cmd set-option -gu @agent-indicator-panel-running-bg
tmux_cmd set-option -gu @agent-indicator-panel-needs-input-fg
tmux_cmd set-option -gu @agent-indicator-panel-done-fg
tmux_cmd set-option -gu @agent-indicator-panel-running-fg

tmux_cmd run-shell -t "$PANE" "PATH=\"$test_dir:/usr/bin:/bin\" TMUX_PANE=\"$PANE\" REAL_TMUX=\"$real_tmux\" TMUX_COMMAND_LOG=\"$command_log\" PS_MAP=\"$ps_map\" PS_CALL_LOG=\"$ps_call_log\" /bin/bash \"$ROOT_DIR/scripts/notification-panel.sh\" --list > \"$bash3_capture\""
bash3_record_count="$(LC_ALL=C tr -cd '\000' < "$bash3_capture" | wc -c | tr -d ' ')"
[ "$bash3_record_count" = "6" ] || fail "current-session panel should render under the macOS system Bash used by tmux panes"

current_record_count="$(LC_ALL=C tr -cd '\000' < "$current_capture" | wc -c | tr -d ' ')"
[ "$current_record_count" = "6" ] || fail "Alt+i should list only live agents from the current tmux session"
if rg -a -q "^${PI_PANE}"$'\t' "$current_capture"; then
    fail "current-session panel should exclude agents from other tmux sessions"
fi
record_count="$(LC_ALL=C tr -cd '\000' < "$capture" | wc -c | tr -d ' ')"
[ "$record_count" = "7" ] || fail "Alt+Shift+i should list every live agent pane and exclude stale hooks"
escape=$'\033'
rg -a -F -q "${escape}[43;30m${escape}[33m◆${escape}[43;30m" "$capture" || fail "needs-input card should default to yellow background"
rg -a -F -q "${escape}[42;30m${escape}[32m✓${escape}[42;30m" "$capture" || fail "done card should default to green background"
rg -a -F -q "${escape}[44;37m${escape}[34m●${escape}[44;37m" "$capture" || fail "running card should default to blue background"
rg -a -F -q "${escape}[45;97m${escape}[35m◆${escape}[45;97m" "$color_capture" || fail "needs-input card colors should be configurable"
rg -a -F -q "${escape}[48;5;22;37m${escape}[38;5;45m✓${escape}[48;5;22;37m" "$color_capture" || fail "card colors should accept colour0..255"
rg -a -F -q "${escape}[104;30m${escape}[94m●${escape}[104;30m" "$color_capture" || fail "card colors should accept bright variants"
rg -q -- '--prompt=agent sessions> ' "$fzf_args" || fail "panel prompt should describe agent sessions"
rg -q -- '--header=Enter open · R refresh · Ctrl-P pin · Alt-I close' "$fzf_args" || fail "panel header should describe card actions"
for expected_arg in --read0 --ansi --color=fg+:-1,bg+:-1 --no-sort --track --id-nth=1 --with-nth=16.. --accept-nth=1..3; do
    rg -F -q -- "$expected_arg" "$fzf_args" || fail "panel should pass $expected_arg to fzf"
done
if rg -q -- '--nth=' "$fzf_args"; then
    fail "search should match the displayed card after --with-nth transforms it"
fi
rg -q -- '--disabled' "$fzf_args" || fail "panel should start in navigation mode"
rg -q -- '--bind=j:down,k:up' "$fzf_args" || fail "j/k should move the panel selection"
rg -q -- '--bind=/:.*enable-search.*unbind\(j,k,r,/\).*rebind\(esc\)' "$fzf_args" || fail "/ should enter search mode and free navigation keys for the query"
rg -q -- '--bind=esc:.*clear-query.*disable-search.*rebind\(j,k,r,/\).*unbind\(esc\)' "$fzf_args" || fail "Escape should leave search mode before closing the panel"
if rg -q -- 'sleep 1' "$fzf_args"; then
    fail "panel should not poll or redraw without an event"
fi
if rg -q -- '--bind=load:reload' "$fzf_args"; then
    fail "panel event listener should not block fzf input inside reload"
fi
rg -q -- '--bind=load:bg-transform.*tmux wait-for agent-indicator-panel-[0-9]+;.*--list' "$fzf_args" || fail "panel should wait in the background and reload after an event"
rg -q -- '--bind=r:reload\(.*--list\)' "$fzf_args" || fail "r should force a full agent snapshot"
rg -q -- 'ctrl-p:execute-silent.*--toggle-pin.*\{1\}.*reload.*--list' "$fzf_args" || fail "Ctrl-P should toggle the selected pin and reload cards"
rg -q -- 'reload.*--all --list' "$fzf_args" || fail "all-sessions panel should preserve its scope after reloading cards"
rg -q -- '--gap=1' "$fzf_args" || fail "agent cards should have a visual separator"
rg -q -- '--gap-line=' "$fzf_args" || fail "agent cards should render a separator line"

actual_order=""
captured_panes=""
while IFS= read -r -d '' row; do
    first_line="${row%%$'\n'*}"
    IFS=$'\t' read -r captured_pane _ _ _ _ _ _ _ state agent location _ _ _ _ _ <<< "$first_line"
    actual_order+="${state}|${agent}|${location}"$'\n'
    captured_panes+="$captured_pane"$'\n'
done < "$capture"
actual_order="${actual_order%$'\n'}"
expected_order=$'done|codex|ai:a-done.0\nrunning|claude|ai:a-done.1\nidle|cursor|ai:a-idle-off.0\nidle|aider|ai:b-idle-mismatch.0\nrunning|opencode|ai:n-running.0\nneeds-input|claude|ai:z-needs.0\nidle|pi|beta:c-idle-missing.0'
[ "$actual_order" = "$expected_order" ] || fail "panel window/location ordering is wrong:\n$actual_order"

tmux_cmd run-shell "TMUX_PANE=$OTHER_PANE \"$ROOT_DIR/scripts/agent-state.sh\" --agent codex --state running"
tmux_cmd run-shell "TMUX_PANE=$WINDOW_PEER_PANE \"$ROOT_DIR/scripts/agent-state.sh\" --agent claude --state done"
tmux_cmd run-shell -t "$PANE" "PATH=\"$test_dir:/usr/bin:/bin\" TMUX_PANE=\"$PANE\" REAL_TMUX=\"$real_tmux\" TMUX_COMMAND_LOG=\"$command_log\" PS_MAP=\"$ps_map\" PS_CALL_LOG=\"$ps_call_log\" /bin/bash \"$ROOT_DIR/scripts/notification-panel.sh\" --all --list > \"$state_change_capture\""
state_change_order=""
while IFS= read -r -d '' row; do
    first_line="${row%%$'\n'*}"
    IFS=$'\t' read -r captured_pane _ captured_window _ _ _ _ _ captured_state _ <<< "$first_line"
    [ "$captured_window" = "$OTHER_WIN" ] || continue
    state_change_order+="$captured_pane|$captured_state"$'\n'
done < "$state_change_capture"
[ "$state_change_order" = "${OTHER_PANE}|running"$'\n'"${WINDOW_PEER_PANE}|done"$'\n' ] || fail "stored status changes should update cards without reordering them"
rg -a -q 'Implement live status across panes' "$state_change_capture" || fail "state events without a description should preserve the stored description"
tmux_cmd select-window -t "$OTHER_WIN"
tmux_cmd select-pane -t "$WINDOW_PEER_PANE"
tmux_cmd run-shell "TMUX_PANE=$WINDOW_PEER_PANE \"$ROOT_DIR/scripts/agent-state.sh\" --agent claude --state done"
tmux_cmd run-shell "TMUX_AGENT_STORE_BIN=\"$store_bin\" TMUX_AGENT_STORE_DIR=\"$store_dir\" \"$ROOT_DIR/scripts/pane-focus-in.sh\" \"$WINDOW_PEER_PANE\" \"$OTHER_WIN\""
focused_state="$(TMUX_AGENT_STORE_DIR="$store_dir" "$store_bin" list | awk -F '\t' -v pane="$WINDOW_PEER_PANE" '$1 == pane { print $7 }')"
[ "$focused_state" = "idle" ] || fail "focusing a done session should keep it registered and mark it idle: $focused_state"

case "$captured_panes" in
    *"$IDLE_MISMATCH_PANE"$'\n'*) ;;
    *) fail "agent mismatch should render the detected agent as idle" ;;
esac
case "$captured_panes" in
    *"$PI_PANE"$'\n'*) ;;
    *) fail "default process detection should include pi" ;;
esac
if [[ "$captured_panes" == *"$STALE_HOOK_PANE"$'\n'* ]]; then
    fail "stale hook without a live configured agent should be excluded"
fi
perl -pe 's/\e\[[0-9;]*m//g' "$capture" > "$plain_capture"
for heading in 'ai · a-done' 'ai · a-idle-off' 'ai · b-idle-mismatch' 'ai · n-running' 'ai · z-needs' 'beta · c-idle-missing'; do
    rg -a -q "$heading" "$plain_capture" || fail "panel should render window heading: $heading"
done
[ "$(rg -a -o 'ai · a-done' "$plain_capture" | wc -l | tr -d ' ')" = "1" ] || fail "a window heading should cover all agent cards in that window"
rg -a -U -q '◆ project-a +'$'\n''  C Review nodes API questions' "$plain_capture" || fail "Claude card should use two lines for directory and description"
rg -a -U -q '✓ project-b +'$'\n''  X Implement live status across panes' "$plain_capture" || fail "Codex hook description should override its pane title"
rg -a -U -q '○ project-b +'$'\n''  Cu project-b' "$plain_capture" || fail "hostname title should fall back to the working-directory name"
rg -a -U -q '○ project-b 📌 +'$'\n''  π ' "$plain_capture" || fail "pinned Pi card should render its pin and agent mark"
padded_lengths=$(perl -0ne 'for $line (split /\n/) { $line =~ s/\0.*//; print length($1), "\n" if $line =~ /^(◆ project-a +|  C Review nodes API questions +)$/ }' "$plain_capture")
expected_lengths="$capture_item_width"$'\n'"$capture_item_width"
[ "$padded_lengths" = "$expected_lengths" ] || fail "both card lines should fill the fzf item width: $padded_lengths"

[ -z "$(rg '^list-panes -a ' "$command_log" || true)" ] || fail "panel renders should not enumerate tmux panes"
[ ! -s "$ps_call_log" ] || fail "panel renders should not scan processes"

selected_session="$(tmux_cmd display-message -p -t "$OTHER_PANE" '#{session_id}')"
selected_window="$(tmux_cmd display-message -p -t "$OTHER_PANE" '#{window_id}')"
rg -Fqx "switch-client -t ${selected_session} ; select-window -t ${selected_window} ; select-pane -t ${OTHER_PANE}" "$command_log" || fail "selection should jump to the first ordered agent pane"

tmux_cmd run-shell "\"$ROOT_DIR/scripts/notification-panel.sh\" --toggle-pin \"$PI_PANE\""
[ -z "$(tmux_cmd show-option -gqv @agent-indicator-pinned-panes)" ] || fail "toggle should remove an existing pin"
tmux_cmd run-shell "\"$ROOT_DIR/scripts/notification-panel.sh\" --toggle-pin \"$IDLE_MISMATCH_PANE\""
[ "$(tmux_cmd show-option -gqv @agent-indicator-pinned-panes)" = "$IDLE_MISMATCH_PANE" ] || fail "toggle should add a pane pin"

pass "agent sessions panel renders grouped cards, toggles pins, and jumps to the selection"
