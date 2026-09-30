#!/usr/bin/env bash
# Toggle agent session panes across the requested tmux scope.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PANEL_OPTION="@agent-indicator-panel"
STORE_BIN="${TMUX_AGENT_STORE_BIN:-$SCRIPT_DIR/../bin/agent-store}"
source_pane="${1:-${TMUX_PANE:-}}"
all_sessions=false

[[ "$source_pane" =~ ^%[0-9]+$ ]] || exit 1
if [ "${2:-}" = "--all" ]; then
    all_sessions=true
fi

session_id=$(tmux display-message -p -t "$source_pane" '#{session_id}')
source_window_id=$(tmux display-message -p -t "$source_pane" '#{window_id}')
panel_panes=""
while IFS=$'\t' read -r pane_id pane_session_id is_panel; do
    [ "$is_panel" = "1" ] || continue
    if [ "$all_sessions" = true ] || [ "$pane_session_id" = "$session_id" ]; then
        panel_panes+="$pane_id"$'\n'
    fi
done < <(tmux list-panes -a -F $'#{pane_id}\t#{session_id}\t#{@agent-indicator-panel}')

if [ -n "$panel_panes" ]; then
    while IFS= read -r panel_pane; do
        [ -n "$panel_pane" ] && tmux kill-pane -t "$panel_pane"
    done <<< "$panel_panes"
    exit 0
fi

[ -x "$STORE_BIN" ] || {
    tmux display-message "agent-store is missing; run install.sh"
    exit 1
}
"$STORE_BIN" sync

printf -v panel_command '%q' "$SCRIPT_DIR/notification-panel.sh"
if [ "$all_sessions" = true ]; then
    panel_command="$panel_command --all"
    targets=$(tmux list-windows -a -F $'#{window_id}\t#{pane_id}' | awk -F '\t' '!seen[$1]++')
else
    targets=$(tmux list-windows -t "$session_id" -F $'#{window_id}\t#{pane_id}')
fi

source_panel=""
while IFS=$'\t' read -r window_id target_pane; do
    [ -n "$target_pane" ] || continue
    panel_pane=$(tmux split-window -d -h -b -f -l 42 -P -F '#{pane_id}' -t "$target_pane" "$panel_command")
    tmux set-option -pt "$panel_pane" "$PANEL_OPTION" 1
    if [ "$window_id" = "$source_window_id" ]; then
        source_panel="$panel_pane"
    fi
done <<< "$targets"

[ -n "$source_panel" ] && tmux select-pane -t "$source_panel"
