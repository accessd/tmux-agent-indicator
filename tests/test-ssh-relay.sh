#!/usr/bin/env bash
# States reported on a host reached through agent-ssh.sh reach the pane the
# ssh client runs in; malformed messages are ignored; disconnecting clears the
# pane. ssh itself is replaced by a stub that runs the "remote" hook against
# the forwarded socket.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/tests/lib/tmux-test-lib.sh"

relay_pid=""
cleanup() {
    [ -z "$relay_pid" ] || kill "$relay_pid" 2>/dev/null || true
    cleanup_test_server
}
trap cleanup EXIT

setup_test_server "ssh-relay"
tmux_env="$(tmux_cmd display-message -p '#{socket_path}'),0,0"
state_key="TMUX_AGENT_PANE_${PANE}_STATE"

wait_for_env_value() {
    local key="$1" expected="$2" value=""
    for _ in $(seq 1 40); do
        value="$(get_env "$key")"
        [ "$value" = "$expected" ] && return 0
        sleep 0.05
    done
    fail "$key: expected '$expected', got '$value'"
}

# Runs agent-state.sh the way a hook on the remote host does: no tmux there.
remote_hook() {
    local socket="$1" agent="$2" state="$3"
    env -u TMUX -u TMUX_PANE LC_TMUX_AGENT_SOCKET="$socket" \
        "$ROOT_DIR/scripts/agent-state.sh" --agent "$agent" --state "$state"
}

send_raw() {
    python3 -c '
import socket, sys
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect(sys.argv[1])
s.sendall(sys.argv[2].encode())
s.close()
' "$1" "$2"
}

# --- Relay: valid states apply in order, malformed ones are dropped ----------
relay_socket="$TEST_TMP_DIR/relay.sock"
TMUX="$tmux_env" "$ROOT_DIR/scripts/agent-relay.py" "$relay_socket" "$PANE" \
    "$ROOT_DIR/scripts/agent-state.sh" &
relay_pid=$!
for _ in $(seq 1 40); do
    [ -S "$relay_socket" ] && break
    sleep 0.05
done
[ -S "$relay_socket" ] || fail "relay socket was not created"
socket_mode="$(stat -c %a "$relay_socket" 2>/dev/null || stat -f %Lp "$relay_socket")"
case "$socket_mode" in
    ?00) ;;
    *) fail "relay socket must be private to the user, mode $socket_mode" ;;
esac

remote_hook "$relay_socket" claude running
remote_hook "$relay_socket" claude needs-input
wait_for_env_value "$state_key" "needs-input"
[ "$(get_env "TMUX_AGENT_PANE_${PANE}_AGENT")" = "claude" ] || fail "agent name not forwarded"

send_raw "$relay_socket" $'claude bogus\n'
send_raw "$relay_socket" $'bad;agent running\n'
send_raw "$relay_socket" $'claude running extra\n'
send_raw "$relay_socket" $'claude done\n'
wait_for_env_value "$state_key" "done"
[ "$(get_env "TMUX_AGENT_PANE_${PANE}_AGENT")" = "claude" ] || fail "malformed message changed the agent"

# A hook whose connection is gone (stale socket path) must not fail or hang.
remote_hook "$TEST_TMP_DIR/missing.sock" claude running || fail "hook failed on a missing socket"

kill "$relay_pid"
wait "$relay_pid" 2>/dev/null || true
relay_pid=""
pass "relay applies forwarded states and drops malformed messages"

# --- agent-ssh.sh: forwards during the session, clears the pane afterwards ----
tmux_cmd run-shell "TMUX_PANE=$PANE \"$ROOT_DIR/scripts/agent-state.sh\" --agent claude --state off"
stub_dir="$TEST_TMP_DIR/bin"
mkdir -p "$stub_dir"
observed="$TEST_TMP_DIR/observed"
cat > "$stub_dir/ssh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
forward=""
send_env=""
while [ "\$#" -gt 0 ]; do
    case "\$1" in
        -R) forward="\$2"; shift 2 ;;
        -o) [ "\$2" != "SendEnv=LC_TMUX_AGENT_SOCKET" ] || send_env=1; shift 2 ;;
        *) shift ;;
    esac
done
remote="\${forward%%:*}"
local_socket="\${forward#*:}"
[ -n "\$send_env" ] || { echo "no SendEnv" > "$observed"; exit 1; }
[ "\$LC_TMUX_AGENT_SOCKET" = "\$remote" ] || { echo "env/forward mismatch" > "$observed"; exit 1; }
env -u TMUX -u TMUX_PANE LC_TMUX_AGENT_SOCKET="\$local_socket" \
    "$ROOT_DIR/scripts/agent-state.sh" --agent codex --state needs-input
for _ in \$(seq 1 40); do
    state=\$(tmux show-environment -g "$state_key" 2>/dev/null || true)
    [ "\$state" = "$state_key=needs-input" ] && break
    sleep 0.05
done
printf '%s\n' "\$state" > "$observed"
exit 7
EOF
chmod +x "$stub_dir/ssh"

status=0
PATH="$stub_dir:$PATH" TMUX="$tmux_env" TMUX_PANE="$PANE" \
    "$ROOT_DIR/scripts/agent-ssh.sh" user@host || status=$?
[ "$status" = "7" ] || fail "agent-ssh.sh must exit with ssh's status, got $status"
[ "$(cat "$observed")" = "$state_key=needs-input" ] \
    || fail "state not forwarded during the ssh session: $(cat "$observed")"
assert_empty "$(get_env "$state_key")" "pane state must be cleared after ssh exits"
assert_empty "$(get_env "TMUX_AGENT_PANE_${PANE}_AGENT")" "pane agent must be cleared after ssh exits"
pass "agent-ssh.sh forwards remote states and clears them on disconnect"

# --- Closing the ssh pane must not clear another pane of the same agent -------
create_other_window
tmux_cmd run-shell "TMUX_PANE=$OTHER_PANE \"$ROOT_DIR/scripts/agent-state.sh\" --agent claude --state running"
hang_dir="$TEST_TMP_DIR/hang-bin"
wrapper_tmp="$TEST_TMP_DIR/wrapper-tmp"
mkdir -p "$hang_dir" "$wrapper_tmp"
printf '#!/bin/sh\nexec sleep 30\n' > "$hang_dir/ssh"
chmod +x "$hang_dir/ssh"
ssh_pane="$(tmux_cmd split-window -d -P -F '#{pane_id}' -t "$PANE" \
    "PATH='$hang_dir':\"\$PATH\" TMPDIR='$wrapper_tmp' '$ROOT_DIR/scripts/agent-ssh.sh' host")"
for _ in $(seq 1 40); do
    compgen -G "$wrapper_tmp/tmux-agent-ssh.*" >/dev/null && break
    sleep 0.05
done
compgen -G "$wrapper_tmp/tmux-agent-ssh.*" >/dev/null || fail "wrapper in the ssh pane did not start"
tmux_cmd run-shell "TMUX_PANE=$ssh_pane \"$ROOT_DIR/scripts/agent-state.sh\" --agent claude --state needs-input"
tmux_cmd kill-pane -t "$ssh_pane"
for _ in $(seq 1 60); do
    compgen -G "$wrapper_tmp/tmux-agent-ssh.*" >/dev/null || break
    sleep 0.05
done
compgen -G "$wrapper_tmp/tmux-agent-ssh.*" >/dev/null && fail "wrapper did not clean up after its pane closed"
[ "$(get_env "TMUX_AGENT_PANE_${OTHER_PANE}_STATE")" = "running" ] \
    || fail "closing the ssh pane cleared another pane of the same agent"
pass "closing the ssh pane leaves other panes of the agent alone"
