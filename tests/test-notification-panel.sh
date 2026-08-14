#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/tmux-test-lib.sh
source "$ROOT_DIR/tests/lib/tmux-test-lib.sh"

test_dir="$(mktemp -d)"
trap 'cleanup_test_server; rm -rf "$test_dir"' EXIT
project_a="$test_dir/project-a"
project_b="$test_dir/project-b"
mkdir -p "$project_a" "$project_b"

setup_test_server "notification-panel"
tmux_cmd rename-window -t "$WIN" z-needs
create_other_window
tmux_cmd rename-window -t "$OTHER_WIN" a-done

RUNNING_PANE="$(tmux_cmd new-window -dP -F '#{pane_id}' -t ai -n n-running)"
IDLE_OFF_PANE="$(tmux_cmd new-window -dP -F '#{pane_id}' -t ai -n a-idle-off)"
IDLE_MISMATCH_PANE="$(tmux_cmd new-window -dP -F '#{pane_id}' -t ai -n b-idle-mismatch)"
STALE_HOOK_PANE="$(tmux_cmd new-window -dP -F '#{pane_id}' -t ai -n stale-hook)"
PI_PANE="$(tmux_cmd -f /dev/null new-session -dP -F '#{pane_id}' -s beta -n c-idle-missing)"

tmux_cmd respawn-pane -k -c "$project_a" -t "$PANE"
tmux_cmd respawn-pane -k -c "$project_b" -t "$OTHER_PANE"
tmux_cmd respawn-pane -k -c "$project_a" -t "$RUNNING_PANE"
tmux_cmd respawn-pane -k -c "$project_b" -t "$IDLE_OFF_PANE"
tmux_cmd respawn-pane -k -c "$project_a" -t "$IDLE_MISMATCH_PANE"
tmux_cmd respawn-pane -k -c "$project_b" -t "$PI_PANE"

tmux_cmd set-environment -g "TMUX_AGENT_PANE_${PANE}_STATE" needs-input
tmux_cmd set-environment -g "TMUX_AGENT_PANE_${PANE}_AGENT" claude
tmux_cmd set-environment -g "TMUX_AGENT_PANE_${OTHER_PANE}_STATE" "done"
tmux_cmd set-environment -g "TMUX_AGENT_PANE_${OTHER_PANE}_AGENT" codex
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
tmux_cmd select-pane -t "$RUNNING_PANE" -T "Refactor release workflow"
tmux_cmd select-pane -t "$IDLE_OFF_PANE" -T "$(hostname -s)"
tmux_cmd select-pane -t "$PI_PANE" -T "π - accessd"
tmux_cmd set-option -g @agent-indicator-pinned-panes "$PI_PANE"

binding="$(tmux_cmd list-keys -T root | rg 'M-i.*display-popup')"
for expected in display-popup -E 'Agent sessions' '-h "100%"' '-w 42' '-x "#{client_width}"' '-y 0' notification-panel.sh; do
    case "$binding" in
        *"$expected"*) ;;
        *) fail "Alt+i binding should contain $expected: $binding" ;;
    esac
done
case "$binding" in
    *'notification-panel.sh --all'*) fail "Alt+i should default to the current tmux session" ;;
esac

all_binding="$(tmux_cmd list-keys -T root | rg 'M-I.*display-popup')"
for expected in display-popup -E 'All agent sessions' '-h "100%"' '-w 42' '-x "#{client_width}"' '-y 0' 'notification-panel.sh --all'; do
    case "$all_binding" in
        *"$expected"*) ;;
        *) fail "Alt+Shift+i binding should contain $expected: $all_binding" ;;
    esac
done

real_tmux="$(command -v tmux)"
capture="$test_dir/fzf-input"
current_capture="$test_dir/fzf-current-input"
bash3_capture="$test_dir/bash3-input"
fzf_args="$test_dir/fzf-args"
command_log="$test_dir/tmux-commands"
ps_map="$test_dir/ps-map"

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
map_process "$RUNNING_PANE" opencode
map_process "$IDLE_OFF_PANE" cursor
map_process "$IDLE_MISMATCH_PANE" aider
map_process "$PI_PANE" pi

cat > "$test_dir/fzf" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "--help" ]; then
    printf '%s\n' '--read0' '--id-nth'
    exit
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

tmux_cmd run-shell -t "$PANE" "PATH=\"$test_dir:\$PATH\" TMUX_PANE=\"$PANE\" REAL_TMUX=\"$real_tmux\" FZF_ARGS=\"$fzf_args\" FZF_CAPTURE=\"$current_capture\" TMUX_COMMAND_LOG=\"$command_log\" PS_MAP=\"$ps_map\" \"$ROOT_DIR/scripts/notification-panel.sh\""

tmux_cmd run-shell -t "$PANE" "PATH=\"$test_dir:\$PATH\" TMUX_PANE=\"$PANE\" REAL_TMUX=\"$real_tmux\" FZF_ARGS=\"$fzf_args\" FZF_CAPTURE=\"$capture\" TMUX_COMMAND_LOG=\"$command_log\" PS_MAP=\"$ps_map\" \"$ROOT_DIR/scripts/notification-panel.sh\" --all"

tmux_cmd run-shell -t "$PANE" "PATH=\"$test_dir:/usr/bin:/bin\" TMUX_PANE=\"$PANE\" REAL_TMUX=\"$real_tmux\" TMUX_COMMAND_LOG=\"$command_log\" PS_MAP=\"$ps_map\" /bin/bash \"$ROOT_DIR/scripts/notification-panel.sh\" --list > \"$bash3_capture\""
bash3_record_count="$(LC_ALL=C tr -cd '\000' < "$bash3_capture" | wc -c | tr -d ' ')"
[ "$bash3_record_count" = "5" ] || fail "current-session panel should render under the macOS system Bash used by tmux popups"

current_record_count="$(LC_ALL=C tr -cd '\000' < "$current_capture" | wc -c | tr -d ' ')"
[ "$current_record_count" = "5" ] || fail "Alt+i should list only live agents from the current tmux session"
if rg -a -q "^${PI_PANE}"$'\t' "$current_capture"; then
    fail "current-session panel should exclude agents from other tmux sessions"
fi
record_count="$(LC_ALL=C tr -cd '\000' < "$capture" | wc -c | tr -d ' ')"
[ "$record_count" = "6" ] || fail "Alt+Shift+i should list every live agent pane and exclude stale hooks"
rg -q -- '--bind=alt-i:abort,start:unbind\(alt-i\),load:rebind\(alt-i\)' "$fzf_args" || fail "Alt+i should close the open panel after startup"
rg -q -- '--prompt=agent sessions> ' "$fzf_args" || fail "panel prompt should describe agent sessions"
rg -q -- '--header=Enter open · Ctrl-P pin · Alt-I close' "$fzf_args" || fail "panel header should describe card actions"
for expected_arg in --read0 --ansi --no-sort --track --id-nth=1 --with-nth=16.. --nth=6.. --accept-nth=1..3; do
    rg -q -- "$expected_arg" "$fzf_args" || fail "panel should pass $expected_arg to fzf"
done
rg -q -- 'ctrl-p:execute-silent.*--toggle-pin.*\{1\}.*reload.*--list' "$fzf_args" || fail "Ctrl-P should toggle the selected pin and reload cards"
rg -q -- 'reload.*--all --list' "$fzf_args" || fail "all-sessions panel should preserve its scope after reloading cards"

actual_order=""
captured_panes=""
while IFS= read -r -d '' row; do
    first_line="${row%%$'\n'*}"
    IFS=$'\t' read -r captured_pane _ _ _ _ _ _ _ state agent location _ _ _ _ _ <<< "$first_line"
    actual_order+="${state}|${agent}|${location}"$'\n'
    captured_panes+="$captured_pane"$'\n'
done < "$capture"
actual_order="${actual_order%$'\n'}"
expected_order=$'needs-input|claude|ai:z-needs.0\ndone|codex|ai:a-done.0\nrunning|opencode|ai:n-running.0\nidle|aider|ai:b-idle-mismatch.0\nidle|pi|beta:c-idle-missing.0\nidle|cursor|ai:a-idle-off.0'
[ "$actual_order" = "$expected_order" ] || fail "panel state/location ordering is wrong:\n$actual_order"

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
for heading in '❗ NEEDS INPUT  1' '✅ DONE  1' '⚡ RUNNING  1' '💤 IDLE  3'; do
    rg -a -q "$heading" "$capture" || fail "panel should render status heading: $heading"
done
[ "$(rg -a -o '▾ project-a' "$capture" | wc -l | tr -d ' ')" = "3" ] || fail "project-a should form a directory group inside each populated status"
[ "$(rg -a -o '▾ project-b' "$capture" | wc -l | tr -d ' ')" = "2" ] || fail "project-b should form a directory group inside each populated status"
rg -a -q 'C  Review nodes API questions' "$capture" || fail "Claude title should become a card summary"
rg -a -q 'X  Fix deployment headers' "$capture" || fail "Codex spinner should be stripped from the card summary"
rg -a -q 'Cu  project-b' "$capture" || fail "hostname title should fall back to the working-directory name"
rg -a -q '📌 π ' "$capture" || fail "pinned Pi card should render its pin and agent mark"

[ "$(rg -c '^list-panes -a ' "$command_log")" = "3" ] || fail "each panel render should enumerate panes with one server-wide snapshot"
snapshot_command="$(rg '^list-panes -a ' "$command_log" | head -n1)"
for field in pane_id pane_tty session_id session_name window_id window_name pane_index pane_current_path pane_title; do
    case "$snapshot_command" in
        *"#{$field}"*) ;;
        *) fail "pane snapshot should include $field: $snapshot_command" ;;
    esac
done

selected_session="$(tmux_cmd display-message -p -t "$PANE" '#{session_id}')"
selected_window="$(tmux_cmd display-message -p -t "$PANE" '#{window_id}')"
rg -Fqx "switch-client -t ${selected_session} ; select-window -t ${selected_window} ; select-pane -t ${PANE}" "$command_log" || fail "selection should jump to the first ordered agent pane"

tmux_cmd run-shell "\"$ROOT_DIR/scripts/notification-panel.sh\" --toggle-pin \"$PI_PANE\""
[ -z "$(tmux_cmd show-option -gqv @agent-indicator-pinned-panes)" ] || fail "toggle should remove an existing pin"
tmux_cmd run-shell "\"$ROOT_DIR/scripts/notification-panel.sh\" --toggle-pin \"$IDLE_MISMATCH_PANE\""
[ "$(tmux_cmd show-option -gqv @agent-indicator-pinned-panes)" = "$IDLE_MISMATCH_PANE" ] || fail "toggle should add a pane pin"

pass "agent sessions panel renders grouped cards, toggles pins, and jumps to the selection"
