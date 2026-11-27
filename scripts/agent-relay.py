#!/usr/bin/env python3
"""Apply agent states sent from a remote host to one local tmux pane.

Usage: agent-relay.py <socket> <pane_id> <agent-state.sh>

agent-ssh.sh starts the relay and forwards the socket to the remote host
(`ssh -R`). Each connection carries one line `<agent> <state>`; it is
validated and passed to agent-state.sh for the pane the ssh client runs in.
Connections are handled one at a time, so states apply in arrival order.
The relay exits once its parent (agent-ssh.sh) is gone.
"""

import os
import re
import socket
import subprocess
import sys


AGENT_RE = re.compile(r"[A-Za-z0-9._-]{1,64}")
STATES = ("running", "needs-input", "done", "off")
MAX_LINE = 256
CONNECTION_TIMEOUT = 2.0
PARENT_POLL_SECONDS = 2.0


def read_line(conn):
    data = b""
    while b"\n" not in data and len(data) <= MAX_LINE:
        chunk = conn.recv(MAX_LINE)
        if not chunk:
            break
        data += chunk
    return data.split(b"\n", 1)[0]


def parse_message(line):
    try:
        parts = line.decode("ascii").split()
    except UnicodeDecodeError:
        return None
    if len(parts) != 2:
        return None
    agent, state = parts
    if not AGENT_RE.fullmatch(agent) or state not in STATES:
        return None
    return agent, state


def serve(server, pane_id, state_script, parent_pid):
    env = dict(os.environ, TMUX_PANE=pane_id)
    while os.getppid() == parent_pid:
        try:
            conn, _ = server.accept()
        except socket.timeout:
            continue
        with conn:
            conn.settimeout(CONNECTION_TIMEOUT)
            try:
                line = read_line(conn)
            except OSError:
                continue
        message = parse_message(line)
        if message is None:
            continue
        agent, state = message
        subprocess.run(
            [state_script, "--agent", agent, "--state", state],
            env=env,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
        )


def main():
    if len(sys.argv) != 4:
        print(__doc__.strip().splitlines()[2], file=sys.stderr)
        return 2
    socket_path, pane_id, state_script = sys.argv[1:]
    parent_pid = os.getppid()

    os.umask(0o077)
    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server.bind(socket_path)
    try:
        server.listen(8)
        server.settimeout(PARENT_POLL_SECONDS)
        serve(server, pane_id, state_script, parent_pid)
    finally:
        server.close()
        try:
            os.unlink(socket_path)
        except OSError:
            pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
