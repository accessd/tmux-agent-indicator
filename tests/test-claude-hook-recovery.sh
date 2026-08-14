#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT

CLAUDE_DIR="$TEST_DIR/claude"
SETTINGS="$CLAUDE_DIR/settings.json"
TARGET_DIR="$TEST_DIR/plugin"
mkdir -p "$CLAUDE_DIR"

cat > "$SETTINGS" <<'JSON'
{
  "hooks": {
    "PostToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "printf foreign-post-tool-use"
          }
        ]
      }
    ]
  }
}
JSON

hook_count() {
    local event="$1"
    local needle="$2"
    python3 - "$SETTINGS" "$event" "$needle" <<'PY'
import json
import sys

settings_path, event, needle = sys.argv[1:]
settings = json.load(open(settings_path, encoding="utf-8"))
commands = [
    hook.get("command", "")
    for entry in settings.get("hooks", {}).get(event, [])
    for hook in entry.get("hooks", [])
]
print(sum(needle in command for command in commands))
PY
}

install_claude_hooks() {
    CLAUDE_CONFIG_DIR="$CLAUDE_DIR" "$ROOT_DIR/install.sh" \
        --target-dir "$TARGET_DIR" --no-codex --no-opencode >/dev/null
}

install_claude_hooks
install_claude_hooks

running_command="scripts/agent-state.sh --agent claude --state running"
for event in PostToolUse PostToolUseFailure; do
    [ "$(hook_count "$event" "$running_command")" = "1" ] || {
        echo "FAIL: $event should restore Claude state to running exactly once"
        exit 1
    }
done
[ "$(hook_count PostToolUse 'printf foreign-post-tool-use')" = "1" ] || {
    echo "FAIL: install should preserve foreign Claude hooks"
    exit 1
}

CLAUDE_CONFIG_DIR="$CLAUDE_DIR" "$ROOT_DIR/install.sh" \
    --target-dir "$TARGET_DIR" --uninstall-claude --no-codex --no-opencode >/dev/null

for event in PostToolUse PostToolUseFailure; do
    [ "$(hook_count "$event" "$running_command")" = "0" ] || {
        echo "FAIL: uninstall should remove the $event recovery hook"
        exit 1
    }
done
[ "$(hook_count PostToolUse 'printf foreign-post-tool-use')" = "1" ] || {
    echo "FAIL: uninstall should preserve foreign Claude hooks"
    exit 1
}

echo "PASS: Claude tool completion restores running state"
