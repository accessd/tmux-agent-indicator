#!/usr/bin/env bash
# ssh wrapper that shows the state of agents on the remote host in the tmux
# pane the connection runs in.
# Usage: agent-ssh.sh [ssh arguments...]   (same arguments as ssh)
#
# A local relay (agent-relay.py) listens on a private socket. ssh forwards a
# random socket on the remote host to it (-R) and passes that path in
# LC_TMUX_AGENT_SOCKET, which default sshd configs accept (AcceptEnv LC_*).
# agent-state.sh on the remote host sends each state through it; the relay
# applies it to this pane. When ssh exits, the pane's agent state is cleared.

set -euo pipefail

if [ -z "${TMUX:-}" ] || [ -z "${TMUX_PANE:-}" ] || ! command -v tmux >/dev/null 2>&1; then
    exec ssh "$@"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
pane_id="$TMUX_PANE"
relay_dir=""
relay_pid=""

# The remote agent is gone with the connection: drop whatever state it left.
# Only while the pane lives: for a closed pane, agent-state.sh would pick
# another pane of the same agent, and the prune hooks clean up anyway.
clear_pane_state() {
    local agent pane_dead
    pane_dead=$(tmux display-message -p -t "$pane_id" '#{pane_dead}' 2>/dev/null || true)
    [ "$pane_dead" = "0" ] || return 0
    agent=$(tmux show-environment -g "TMUX_AGENT_PANE_${pane_id}_AGENT" 2>/dev/null || true)
    case "$agent" in
        TMUX_AGENT_PANE_*=?*) agent="${agent#*=}" ;;
        *) return 0 ;;
    esac
    TMUX_PANE="$pane_id" "$SCRIPT_DIR/agent-state.sh" --agent "$agent" --state off \
        </dev/null >/dev/null 2>&1 || true
}

cleanup() {
    if [ -n "$relay_pid" ]; then
        kill "$relay_pid" 2>/dev/null || true
        wait "$relay_pid" 2>/dev/null || true
    fi
    [ -z "$relay_dir" ] || rm -rf "$relay_dir"
    clear_pane_state
}
trap cleanup EXIT

relay_dir=$(mktemp -d "${TMPDIR:-/tmp}/tmux-agent-ssh.XXXXXX")
local_socket="$relay_dir/relay.sock"
"$SCRIPT_DIR/agent-relay.py" "$local_socket" "$pane_id" "$SCRIPT_DIR/agent-state.sh" \
    </dev/null >/dev/null 2>&1 &
relay_pid=$!

for _ in $(seq 1 40); do
    [ -S "$local_socket" ] && break
    kill -0 "$relay_pid" 2>/dev/null || break
    sleep 0.05
done
if [ ! -S "$local_socket" ]; then
    echo "agent-ssh: relay did not start (python3 missing?); connecting without agent state forwarding" >&2
    status=0
    ssh "$@" || status=$?
    exit "$status"
fi

# Random name: sshd refuses to bind over an existing path, and other users of
# the remote /tmp must not guess it. sshd creates it mode 0600.
remote_socket="/tmp/tmux-agent-indicator-$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n').sock"

status=0
LC_TMUX_AGENT_SOCKET="$remote_socket" ssh \
    -o SendEnv=LC_TMUX_AGENT_SOCKET \
    -R "$remote_socket:$local_socket" \
    "$@" || status=$?
exit "$status"
