#!/usr/bin/env bash
# Installer/updater for tmux-agent-indicator.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_DIR="${TMUX_AGENT_INSTALL_DIR:-$HOME/.tmux/plugins/tmux-agent-indicator}"
INSTALL_CLAUDE=true
INSTALL_CODEX=true
UNINSTALL_CLAUDE=false
UNINSTALL_CODEX=false

usage() {
    cat <<'EOF'
Usage: install.sh [OPTIONS]

Options:
  --target-dir <path>  Install path (default: ~/.tmux/plugins/tmux-agent-indicator)
  --no-claude          Skip Claude hooks setup
  --no-codex           Skip Codex notify setup
  --uninstall-claude   Remove tmux-agent-indicator Claude hooks from ~/.claude/settings.json
  --uninstall-codex    Remove tmux-agent-indicator Codex notify from ~/.codex/config.toml
  -h, --help           Show this help
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --target-dir)
            [ "$#" -lt 2 ] && usage && exit 1
            TARGET_DIR="$2"
            shift 2
            ;;
        --no-claude)
            INSTALL_CLAUDE=false
            shift
            ;;
        --no-codex)
            INSTALL_CODEX=false
            shift
            ;;
        --uninstall-claude)
            UNINSTALL_CLAUDE=true
            INSTALL_CLAUDE=false
            shift
            ;;
        --uninstall-codex)
            UNINSTALL_CODEX=true
            INSTALL_CODEX=false
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage
            exit 1
            ;;
    esac
done

mkdir -p "$TARGET_DIR/scripts" "$TARGET_DIR/hooks" "$TARGET_DIR/adapters"

cp "$SCRIPT_DIR/agent-indicator.tmux" "$TARGET_DIR/"
cp "$SCRIPT_DIR/README.md" "$TARGET_DIR/"
cp "$SCRIPT_DIR/LICENSE" "$TARGET_DIR/"
cp "$SCRIPT_DIR/scripts/"*.sh "$TARGET_DIR/scripts/"
cp "$SCRIPT_DIR/hooks/"*.json "$TARGET_DIR/hooks/"
cp "$SCRIPT_DIR/adapters/"*.sh "$TARGET_DIR/adapters/"

chmod +x "$TARGET_DIR/agent-indicator.tmux" "$TARGET_DIR/scripts/"*.sh "$TARGET_DIR/adapters/"*.sh

if [ "$INSTALL_CLAUDE" = true ] || [ "$UNINSTALL_CLAUDE" = true ]; then
    CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
    CLAUDE_SETTINGS="$CLAUDE_DIR/settings.json"
    mkdir -p "$CLAUDE_DIR"
    if [ ! -f "$CLAUDE_SETTINGS" ] && [ "$INSTALL_CLAUDE" = true ]; then
        printf '{}\n' > "$CLAUDE_SETTINGS"
    fi

    if [ -f "$CLAUDE_SETTINGS" ]; then
        if [ "$UNINSTALL_CLAUDE" = true ]; then
            CLAUDE_MODE="uninstall"
        else
            CLAUDE_MODE="install"
        fi

        python3 - "$CLAUDE_SETTINGS" "$TARGET_DIR" "$CLAUDE_MODE" <<'PY'
import json
import pathlib
import sys

settings_path = pathlib.Path(sys.argv[1])
target_dir = sys.argv[2]
mode = sys.argv[3]

try:
    settings = json.loads(settings_path.read_text(encoding="utf-8"))
except Exception:
    settings = {}

hooks = settings.setdefault("hooks", {})

def is_plugin_command(command):
    return "scripts/agent-state.sh" in command and "--agent claude --state" in command

for event in list(hooks.keys()):
    entries = hooks.get(event, [])
    cleaned_entries = []
    for entry in entries:
        hook_items = entry.get("hooks", [])
        cleaned_hook_items = []
        for hook_item in hook_items:
            cmd = hook_item.get("command", "")
            if is_plugin_command(cmd):
                continue
            cleaned_hook_items.append(hook_item)

        if hook_items and not cleaned_hook_items:
            continue

        if cleaned_hook_items != hook_items:
            updated = dict(entry)
            updated["hooks"] = cleaned_hook_items
            cleaned_entries.append(updated)
        else:
            cleaned_entries.append(entry)

    if cleaned_entries:
        hooks[event] = cleaned_entries
    else:
        hooks.pop(event, None)

events = {
    "UserPromptSubmit": f"\"${{TMUX_AGENT_INDICATOR_DIR:-{target_dir}}}\"/scripts/agent-state.sh --agent claude --state running",
    "PermissionRequest": f"\"${{TMUX_AGENT_INDICATOR_DIR:-{target_dir}}}\"/scripts/agent-state.sh --agent claude --state needs-input",
    "Stop": f"\"${{TMUX_AGENT_INDICATOR_DIR:-{target_dir}}}\"/scripts/agent-state.sh --agent claude --state done",
}

if mode == "install":
    for event, command in events.items():
        entries = hooks.get(event, [])
        entries.append({
            "matcher": "",
            "hooks": [{"type": "command", "command": command}],
        })
        hooks[event] = entries

settings["hooks"] = hooks

settings_path.write_text(json.dumps(settings, indent=2) + "\n", encoding="utf-8")
PY
    fi
fi

if [ "$INSTALL_CODEX" = true ] || [ "$UNINSTALL_CODEX" = true ]; then
    CODEX_DIR="${CODEX_CONFIG_DIR:-$HOME/.codex}"
    CODEX_CONFIG="$CODEX_DIR/config.toml"
    mkdir -p "$CODEX_DIR"

    python3 - "$CODEX_CONFIG" "$TARGET_DIR" "$UNINSTALL_CODEX" <<'PY'
import pathlib
import re
import sys

config_path = pathlib.Path(sys.argv[1])
target_dir = sys.argv[2]
uninstall = sys.argv[3].lower() == "true"
notify_line = f'notify = ["bash", "{target_dir}/adapters/codex-notify.sh"]'

if config_path.exists():
    text = config_path.read_text(encoding="utf-8")
else:
    text = ""

pattern = re.compile(r"(?m)^[ \t]*notify[ \t]*=[ \t]*.*$")
if uninstall:
    text = re.sub(
        r'(?m)^[ \t]*notify[ \t]*=[ \t]*\[\s*"bash"\s*,\s*".*/adapters/codex-notify\.sh"\s*\][ \t]*\n?',
        "",
        text,
    )
elif pattern.search(text):
    text = pattern.sub(notify_line, text, count=1)
else:
    if text and not text.endswith("\n"):
        text += "\n"
    text += notify_line + "\n"

config_path.write_text(text, encoding="utf-8")
PY
fi

cat <<EOF
Installed/updated tmux-agent-indicator in:
  $TARGET_DIR

Add to ~/.tmux.conf (TPM):
  set -g @plugin 'accessd/tmux-agent-indicator'

Or direct load:
  run-shell '$TARGET_DIR/agent-indicator.tmux'

Status example:
  set -g status-right '#{agent_indicator} | %H:%M'

If using minimal-tmux-status:
  set -g @minimal-tmux-status-right '#{agent_indicator} #(gitmux "#{pane_current_path}")'

Reload tmux:
  tmux source-file ~/.tmux.conf
EOF

if [ "$UNINSTALL_CLAUDE" = true ]; then
    echo "Removed tmux-agent-indicator Claude hooks from: ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json"
fi

if [ "$UNINSTALL_CODEX" = true ]; then
    echo "Removed tmux-agent-indicator Codex notify from: ${CODEX_CONFIG_DIR:-$HOME/.codex}/config.toml"
fi
