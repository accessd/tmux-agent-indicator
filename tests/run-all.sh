#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

tests=(
    "$ROOT_DIR/tests/test-agent-store.sh"
    "$ROOT_DIR/tests/test-agent-limits.sh"
    "$ROOT_DIR/tests/test-claude-hook-recovery.sh"
    "$ROOT_DIR/tests/test-state-transitions.sh"
    "$ROOT_DIR/tests/test-indicator-output.sh"
    "$ROOT_DIR/tests/test-notification-panel.sh"
    "$ROOT_DIR/tests/test-pane-style-preserves-focus.sh"
    "$ROOT_DIR/tests/test-focus-reset-done.sh"
    "$ROOT_DIR/tests/test-window-title-reset.sh"
    "$ROOT_DIR/tests/test-running-animation.sh"
)

for test_script in "${tests[@]}"; do
    echo "==> $(basename "$test_script")"
    "$test_script"
done

echo "PASS: all automated tests"
