#!/usr/bin/env python3
"""Verify the production hook adapter with two native Codex TUIs; submits no prompts."""

import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys
import tempfile
import time


root = Path(__file__).resolve().parents[1]
binary = str(Path(sys.argv[1]).resolve())
version = subprocess.check_output([binary, "--version"], text=True).strip()
sock = f"agent-hook-native-{os.getpid()}"
env = dict(os.environ)
env.pop("TMUX", None)
env.pop("TMUX_PANE", None)


def tmux(*args):
    return subprocess.check_output(["tmux", "-L", sock, *args], env=env, text=True).strip()


def wait_for_title(pane):
    for _ in range(200):
        title = tmux("display-message", "-p", "-t", pane, "#{pane_title}")
        screen = tmux("capture-pane", "-p", "-t", pane)
        ids = re.findall(r"[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}", screen)
        if ids and title == f"codex | {ids[-1][:29]}...":
            return ids[-1], title
        time.sleep(0.1)
    raise RuntimeError(f"Codex did not publish its ID in pane {pane}; title={title!r}")


with tempfile.TemporaryDirectory(prefix="codex-hook-native-", dir="/tmp") as scratch:
    scratch = Path(scratch)
    home = scratch / "home"
    home.mkdir()
    project = scratch / "project"
    project.mkdir()
    auth = Path.home() / ".codex/auth.json"
    if auth.exists():
        (home / "auth.json").symlink_to(auth)
    (home / "config.toml").write_text(
        '[tui]\nterminal_title = ["app-name", "thread-id"]\nstatus_line = ["session-id"]\n'
        f'\n[projects.{json.dumps(str(project))}]\ntrust_level = "trusted"\n'
    )
    control = home / "app-server-control/app-server-control.sock"
    control.parent.mkdir(mode=0o700)
    server = None
    try:
        first = tmux("-f", "/dev/null", "new-session", "-d", "-x", "120", "-y", "40",
                     "-s", "probe", "-P", "-F", "#{pane_id}")
        second = tmux("split-window", "-d", "-h", "-t", first, "-P", "-F", "#{pane_id}")
        tmux_socket = tmux("display-message", "-p", "-t", first, "#{socket_path}")
        server_env = dict(env, CODEX_HOME=str(home), TMUX=f"{tmux_socket},0,0", TMUX_PANE=first)
        with (scratch / "server.log").open("w") as log:
            server = subprocess.Popen([binary, "app-server", "--listen", f"unix://{control}"],
                                      env=server_env, cwd=project, stdout=log, stderr=log)
        for _ in range(100):
            if control.exists():
                break
            if server.poll() is not None:
                raise RuntimeError("Scratch app-server exited")
            time.sleep(0.1)
        assert control.exists(), "Scratch app-server did not start"
        command = shlex.join(["env", f"CODEX_HOME={home}", binary,
                              "--remote", f"unix://{control}", "-C", str(project)])
        for pane in (first, second):
            tmux("send-keys", "-t", pane, command, "Enter")
        first_id, first_title = wait_for_title(first)
        second_id, second_title = wait_for_title(second)
        assert first_id != second_id
        print(f"PASS: {version}, two real TUI clients share a scratch app-server and cwd")

        hook_binary = scratch / "plugin/bin/codex-hook"
        hook_binary.parent.mkdir(parents=True)
        subprocess.run(["go", "build", "-o", str(hook_binary), "./cmd/codex-hook"], cwd=root,
                       env={k: v for k, v in env.items() if k != "GOROOT"}, check=True)
        (scratch / "plugin/scripts").symlink_to(root / "scripts", target_is_directory=True)
        server_env["TMPDIR"] = str(scratch)
        server_env["TMUX_AGENT_STORE_BIN"] = "/nonexistent"
        subprocess.run([str(hook_binary), "--register-tmux", tmux_socket], env=server_env, check=True)

        def hook(session, state="done"):
            event = {"running": "UserPromptSubmit", "needs-input": "PermissionRequest", "done": "Stop"}[state]
            subprocess.run([str(hook_binary), "--state", state],
                           input=json.dumps({"session_id": session, "hook_event_name": event}),
                           env=server_env, text=True, check=True)

        def clear():
            subprocess.run([str(root / "scripts/agent-state.sh"), "--agent", "codex", "--state", "off"],
                           env=dict(server_env, TMUX_PANE=second), check=True)

        for state, color in (("running", "colour17"), ("needs-input", "colour18"), ("done", "colour19")):
            tmux("set-option", "-g", f"@agent-indicator-{state}-bg", color)
            hook(second_id, state)
            assert tmux("show-environment", "-g", f"TMUX_AGENT_PANE_{second}_STATE").endswith(f"={state}")
            assert tmux("show-options", "-p", "-v", "-t", second, "window-style") == f"bg={color}"
        clear()
        assert tmux("show-options", "-p", "-v", "-t", second, "window-style") == "bg=default"
        untouched = subprocess.run(["tmux", "-L", sock, "show-environment", "-g", f"TMUX_AGENT_PANE_{first}_STATE"],
                                   env=env, capture_output=True)
        assert untouched.returncode != 0
        print("PASS: production adapter + real API route running/needs-input/done; off restores styles")

        tmux("select-pane", "-t", first, "-T", second_title)
        hook(second_id)
        assert tmux("show-options", "-p", "-v", "-t", second, "window-style") == "bg=default"
        tmux("select-pane", "-t", first, "-T", first_title)
        tmux("select-pane", "-t", second, "-T", "other application")
        hook(second_id)
        assert tmux("show-options", "-p", "-v", "-t", second, "window-style") == "bg=default"
        tmux("select-pane", "-t", second, "-T", second_title)
        collision = second_id[:29] + ("0000000" if second_id[29:] != "0000000" else "1111111")
        hook(collision)
        assert tmux("show-options", "-p", "-v", "-t", second, "window-style") == "bg=default"
        print("PASS: duplicate/replaced titles and false session with same truncated prefix are rejected")

        tmux("respawn-pane", "-k", "-t", second)
        tmux("select-pane", "-t", second, "-T", second_title)
        time.sleep(0.3)
        hook(second_id)
        assert tmux("show-options", "-p", "-v", "-t", second, "window-style") == "bg=default"
        print("PASS: stale title after client exit is rejected")
        print("No inference requests, user config edits, or installed hook changes.")
    finally:
        subprocess.run(["tmux", "-L", sock, "kill-server"], env=env,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        if server is not None:
            server.terminate()
            try:
                server.wait(timeout=5)
            except subprocess.TimeoutExpired:
                server.kill()
                server.wait()
