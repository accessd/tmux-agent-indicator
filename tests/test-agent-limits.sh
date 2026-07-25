#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT

export HOME="$TEST_DIR/home"
export TMUX_AGENT_LIMITS_CACHE_DIR="$TEST_DIR/cache"
export CODEX_HOME="$HOME/.codex"
mkdir -p "$HOME" "$CODEX_HOME/sessions/2099/01/01"

cat > "$HOME/.claude.json" <<'JSON'
{
  "cachedUsageUtilization": {
    "fetchedAtMs": 4070908800000,
    "utilization": {
      "five_hour": {
        "utilization": 4,
        "resets_at": "2099-01-01T01:00:00Z"
      },
      "seven_day": {
        "utilization": 40,
        "resets_at": "2099-01-07T00:00:00Z"
      }
    }
  }
}
JSON

cat > "$CODEX_HOME/sessions/2099/01/01/rollout-test.jsonl" <<'JSONL'
{"type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":2,"window_minutes":10080,"resets_at":4071513600},"plan_type":"pro"}}}
JSONL

output=$(python3 "$ROOT_DIR/scripts/agent-limits.py" --no-cache)
[ "$output" = "C 5h 4% used · X 7d 2% used" ] || {
    echo "FAIL: unexpected limits output: $output"
    exit 1
}

cat > "$HOME/.claude.json" <<'JSON'
{
  "cachedUsageUtilization": {
    "fetchedAtMs": 1577836800000,
    "utilization": {
      "five_hour": {
        "utilization": 99,
        "resets_at": "2020-01-01T01:00:00Z"
      }
    }
  }
}
JSON

output=$(python3 "$ROOT_DIR/scripts/agent-limits.py" --providers claude --no-cache)
[ -z "$output" ] || {
    echo "FAIL: expired Claude limit should be hidden: $output"
    exit 1
}

previous_command=$(printf 'printf previous' | base64 | tr -d '\n')
output=$(printf '%s' '{"rate_limits":{"five_hour":{"used_percentage":25,"resets_at":4070908800}}}' | \
    python3 "$ROOT_DIR/scripts/agent-limits.py" claude-statusline --previous-command-base64 "$previous_command")
[ "$output" = "previous" ] || {
    echo "FAIL: Claude status-line output was not preserved: $output"
    exit 1
}

output=$(python3 "$ROOT_DIR/scripts/agent-limits.py" --providers claude --no-cache)
[ "$output" = "C 5h 25% used" ] || {
    echo "FAIL: Claude status-line cache was not used: $output"
    exit 1
}

mkdir -p "$TEST_DIR/claude"
cat > "$TEST_DIR/claude/settings.json" <<'JSON'
{
  "statusLine": {
    "type": "command",
    "command": "printf prior"
  }
}
JSON

settings_command() {
    python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["statusLine"]["command"])' "$1"
}

original=$(settings_command "$TEST_DIR/claude/settings.json")
CLAUDE_CONFIG_DIR="$TEST_DIR/claude" "$ROOT_DIR/install.sh" \
    --target-dir "$TEST_DIR/plugin" --no-codex --no-opencode >/dev/null
first=$(settings_command "$TEST_DIR/claude/settings.json")
CLAUDE_CONFIG_DIR="$TEST_DIR/claude" "$ROOT_DIR/install.sh" \
    --target-dir "$TEST_DIR/plugin" --no-codex --no-opencode >/dev/null
second=$(settings_command "$TEST_DIR/claude/settings.json")
[ "$first" = "$second" ] || {
    echo "FAIL: Claude status-line wrapper nested during reinstall"
    exit 1
}

CLAUDE_CONFIG_DIR="$TEST_DIR/claude" "$ROOT_DIR/install.sh" \
    --target-dir "$TEST_DIR/plugin" --uninstall-claude --no-codex --no-opencode >/dev/null
restored=$(settings_command "$TEST_DIR/claude/settings.json")
[ "$restored" = "$original" ] || {
    echo "FAIL: Claude status-line command was not restored: $restored"
    exit 1
}

echo "PASS: Claude and Codex agent limits"
