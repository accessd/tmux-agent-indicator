#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
export CODEX_CONFIG_DIR="$TEST_DIR/codex"
export TMUX_AGENT_STORE_DIR="$TEST_DIR/store"
mkdir -p "$CODEX_CONFIG_DIR"
printf '[tui]\nterminal_title = ["cwd"]\n' > "$CODEX_CONFIG_DIR/config.toml"
cp "$CODEX_CONFIG_DIR/config.toml" "$TEST_DIR/original.toml"
cat > "$CODEX_CONFIG_DIR/hooks.json" <<'JSON'
{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"/old/plugin/scripts/agent-state.sh --agent codex --state done"},{"type":"command","command":"printf foreign-hook"}]}]}}
JSON
for _ in 1 2; do
    "$ROOT_DIR/install.sh" --target-dir "$TEST_DIR/plugin" --no-claude --no-opencode >/dev/null
done
[ -x "$TEST_DIR/plugin/bin/codex-hook" ]
cmp "$CODEX_CONFIG_DIR/config.toml" "$TEST_DIR/original.toml"
python3 - "$CODEX_CONFIG_DIR/hooks.json" <<'PY'
import json
import sys
hooks = json.load(open(sys.argv[1]))["hooks"]
commands = [hook["command"] for entries in hooks.values() for entry in entries for hook in entry["hooks"]]
assert sum("scripts/codex-hook.sh" in cmd for cmd in commands) == 3, commands
assert not any("scripts/agent-state.sh" in cmd for cmd in commands), commands
assert commands.count("printf foreign-hook") == 1, commands
PY
"$ROOT_DIR/install.sh" --target-dir "$TEST_DIR/plugin" --no-claude --no-opencode --uninstall-codex >/dev/null
python3 - "$CODEX_CONFIG_DIR/hooks.json" <<'PY'
import json
import sys
hooks = json.load(open(sys.argv[1]))["hooks"]
commands = [hook["command"] for entries in hooks.values() for entry in entries for hook in entry["hooks"]]
assert commands == ["printf foreign-hook"], commands
PY
echo "PASS: Codex hook migration is idempotent and preserves foreign hooks and title config"
