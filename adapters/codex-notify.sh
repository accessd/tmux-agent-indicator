#!/usr/bin/env bash
# tmux-agent-indicator adapter for Codex notify events.

set -euo pipefail

PLUGIN_DIR="${TMUX_AGENT_INDICATOR_DIR:-$HOME/.tmux/plugins/tmux-agent-indicator}"
STATE_SCRIPT="$PLUGIN_DIR/scripts/agent-state.sh"
EVENT="${1:-agent-turn-complete}"

case "$EVENT" in
    start|session-start|turn-start|working)
        STATE="running"
        ;;
    permission*|approve*|needs-input|input-required|ask-user)
        STATE="needs-input"
        ;;
    agent-turn-complete|complete|done|stop|error|fail*)
        STATE="done"
        ;;
    *)
        STATE="done"
        ;;
esac

bash "$STATE_SCRIPT" --agent codex --state "$STATE"
