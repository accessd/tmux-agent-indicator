#!/usr/bin/env bash
# Reloading the plugin from another install directory (e.g. a new Nix store
# path) replaces the hooks of the previous one instead of adding to them.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/tests/lib/tmux-test-lib.sh"

INSTALL_ROOT="$(mktemp -d)"
trap 'cleanup_test_server; rm -rf "$INSTALL_ROOT"' EXIT

for dir in first second; do
    mkdir -p "$INSTALL_ROOT/$dir"
    cp "$ROOT_DIR/agent-indicator.tmux" "$INSTALL_ROOT/$dir/"
    cp -R "$ROOT_DIR/scripts" "$INSTALL_ROOT/$dir/"
done

setup_test_server "hook-dedupe"
tmux_cmd set-hook -ag pane-focus-in "run-shell 'true unrelated-user-hook'"
tmux_cmd run-shell "$INSTALL_ROOT/first/agent-indicator.tmux"
tmux_cmd run-shell "$INSTALL_ROOT/second/agent-indicator.tmux"
tmux_cmd run-shell "$INSTALL_ROOT/second/agent-indicator.tmux"

for hook in pane-focus-in after-select-window after-select-pane client-session-changed \
    pane-exited pane-died after-kill-pane window-unlinked; do
    entries="$(tmux_cmd show-hooks -g "$hook" 2>/dev/null | grep -F '/scripts/' || true)"
    count="$(printf '%s\n' "$entries" | grep -c . || true)"
    [ "$count" = "1" ] || fail "$hook should have exactly one plugin entry, got $count: $entries"
    case "$entries" in
        *"$INSTALL_ROOT/second/scripts/"*) ;;
        *) fail "$hook should point at the latest install: $entries" ;;
    esac
done

tmux_cmd show-hooks -g pane-focus-in | grep -qF 'unrelated-user-hook' || fail "unrelated hooks must be kept"

pass "hooks are deduplicated across install directories"
