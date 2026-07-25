#!/usr/bin/env bash
# Installer/updater for tmux-agent-indicator.

set -euo pipefail

SCRIPT_DIR=""
TMP_SOURCE_DIR=""

SCRIPT_SOURCE=""
case "${0:-}" in
    bash|-bash|sh|-sh)
        ;;
    *)
        SCRIPT_SOURCE="${0}"
        ;;
esac

if [ -z "$SCRIPT_SOURCE" ] && [ -n "${BASH_SOURCE+set}" ] && [ "${#BASH_SOURCE[@]}" -gt 0 ]; then
    SCRIPT_SOURCE="${BASH_SOURCE[0]}"
fi

if [ -n "$SCRIPT_SOURCE" ] && [ -f "$SCRIPT_SOURCE" ]; then
    SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_SOURCE")" && pwd)"
fi

if [ -z "$SCRIPT_DIR" ] || [ ! -f "$SCRIPT_DIR/agent-indicator.tmux" ]; then
    INSTALL_REPO="${TMUX_AGENT_INSTALL_REPO:-accessd/tmux-agent-indicator}"
    INSTALL_REF="${TMUX_AGENT_INSTALL_REF:-main}"
    ARCHIVE_URL="https://codeload.github.com/${INSTALL_REPO}/tar.gz/refs/heads/${INSTALL_REF}"

    if ! command -v curl >/dev/null 2>&1; then
        echo "curl is required for stdin-based installation" >&2
        exit 1
    fi
    if ! command -v tar >/dev/null 2>&1; then
        echo "tar is required for stdin-based installation" >&2
        exit 1
    fi

    TMP_SOURCE_DIR="$(mktemp -d)"
    trap 'rm -rf "$TMP_SOURCE_DIR"' EXIT
    curl -fsSL "$ARCHIVE_URL" | tar -xz -C "$TMP_SOURCE_DIR"
    SCRIPT_DIR="$(find "$TMP_SOURCE_DIR" -mindepth 1 -maxdepth 1 -type d | head -n 1)"

    if [ -z "$SCRIPT_DIR" ] || [ ! -f "$SCRIPT_DIR/agent-indicator.tmux" ]; then
        echo "Failed to fetch installer sources from $ARCHIVE_URL" >&2
        exit 1
    fi
fi
TARGET_DIR="${TMUX_AGENT_INSTALL_DIR:-$HOME/.tmux/plugins/tmux-agent-indicator}"
INSTALL_CLAUDE=true
INSTALL_CODEX=true
INSTALL_OPENCODE=true
UNINSTALL_CLAUDE=false
UNINSTALL_CODEX=false
UNINSTALL_OPENCODE=false

usage() {
    cat <<'EOF'
Usage: install.sh [OPTIONS]

Options:
  --target-dir <path>  Install path (default: ~/.tmux/plugins/tmux-agent-indicator)
  --no-claude          Skip Claude hooks setup
  --no-codex           Skip Codex notify setup
  --no-opencode        Skip OpenCode plugin setup
  --uninstall-claude   Remove Claude hooks/status-line wrapper from ~/.claude/settings.json
  --uninstall-codex    Remove tmux-agent-indicator Codex notify from ~/.codex/config.toml
  --uninstall-opencode Remove tmux-agent-indicator OpenCode plugin from ~/.config/opencode/plugins/
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
        --no-opencode)
            INSTALL_OPENCODE=false
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
        --uninstall-opencode)
            UNINSTALL_OPENCODE=true
            INSTALL_OPENCODE=false
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

# Auto-detect agents: skip integration if agent not found on system
if [ "$INSTALL_CLAUDE" = true ] && [ "$UNINSTALL_CLAUDE" = false ]; then
    CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
    if ! command -v claude >/dev/null 2>&1 && [ ! -d "$CLAUDE_DIR" ]; then
        INSTALL_CLAUDE=false
        echo "Claude not detected, skipping hooks setup"
    fi
fi

if [ "$INSTALL_CODEX" = true ] && [ "$UNINSTALL_CODEX" = false ]; then
    CODEX_DIR="${CODEX_CONFIG_DIR:-$HOME/.codex}"
    if ! command -v codex >/dev/null 2>&1 && [ ! -d "$CODEX_DIR" ]; then
        INSTALL_CODEX=false
        echo "Codex not detected, skipping notify setup"
    fi
fi

if [ "$INSTALL_OPENCODE" = true ] && [ "$UNINSTALL_OPENCODE" = false ]; then
    OPENCODE_CFG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/opencode"
    if ! command -v opencode >/dev/null 2>&1 && [ ! -d "$OPENCODE_CFG_DIR" ]; then
        INSTALL_OPENCODE=false
        echo "OpenCode not detected, skipping plugin setup"
    fi
fi

mkdir -p "$TARGET_DIR/scripts" "$TARGET_DIR/hooks" "$TARGET_DIR/adapters" "$TARGET_DIR/plugins"

cp "$SCRIPT_DIR/agent-indicator.tmux" "$TARGET_DIR/"
cp "$SCRIPT_DIR/README.md" "$TARGET_DIR/"
cp "$SCRIPT_DIR/LICENSE" "$TARGET_DIR/"
cp "$SCRIPT_DIR/scripts/"*.sh "$TARGET_DIR/scripts/"
cp "$SCRIPT_DIR/scripts/"*.py "$TARGET_DIR/scripts/"
cp "$SCRIPT_DIR/hooks/"*.json "$TARGET_DIR/hooks/"
cp "$SCRIPT_DIR/adapters/"*.sh "$TARGET_DIR/adapters/"
cp "$SCRIPT_DIR/plugins/"*.js "$TARGET_DIR/plugins/"
cp "$SCRIPT_DIR/setup.sh" "$TARGET_DIR/"

chmod +x "$TARGET_DIR/agent-indicator.tmux" "$TARGET_DIR/scripts/"*.sh "$TARGET_DIR/scripts/"*.py "$TARGET_DIR/adapters/"*.sh "$TARGET_DIR/setup.sh"

if [ "$INSTALL_CLAUDE" = true ] || [ "$UNINSTALL_CLAUDE" = true ]; then
    CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
    CLAUDE_SETTINGS="$CLAUDE_DIR/settings.json"
    mkdir -p "$CLAUDE_DIR"
    if [ ! -f "$CLAUDE_SETTINGS" ] && [ "$INSTALL_CLAUDE" = true ]; then
        printf '{}\n' > "$CLAUDE_SETTINGS"
    fi

    if [ "$INSTALL_CLAUDE" = true ]; then
        echo "Claude detected"
        echo "  Hooks/status line -> $CLAUDE_SETTINGS"
    fi

    if [ -f "$CLAUDE_SETTINGS" ]; then
        if [ "$UNINSTALL_CLAUDE" = true ]; then
            CLAUDE_MODE="uninstall"
        else
            CLAUDE_MODE="install"
        fi

        python3 - "$CLAUDE_SETTINGS" "$TARGET_DIR" "$CLAUDE_MODE" <<'PY'
import base64
import json
import pathlib
import shlex
import sys

settings_path = pathlib.Path(sys.argv[1])
target_dir = sys.argv[2]
mode = sys.argv[3]

try:
    settings = json.loads(settings_path.read_text(encoding="utf-8"))
except Exception:
    settings = {}

hooks = settings.setdefault("hooks", {})

def unwrap_statusline(command):
    try:
        parts = shlex.split(command)
    except ValueError:
        return False, ""
    for index, part in enumerate(parts):
        if not part.endswith("/scripts/agent-limits.py"):
            continue
        if parts[index + 1:index + 2] != ["claude-statusline"]:
            continue
        if index + 2 == len(parts):
            return True, ""
        if parts[index + 2:index + 3] != ["--previous-command-base64"]:
            continue
        if index + 3 >= len(parts):
            return False, ""
        try:
            previous = base64.b64decode(parts[index + 3]).decode("utf-8")
        except Exception:
            return False, ""
        return True, previous
    return False, ""

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
    "UserPromptSubmit": [
        f"\"${{TMUX_AGENT_INDICATOR_DIR:-{target_dir}}}\"/scripts/agent-state.sh --agent claude --state off",
        f"\"${{TMUX_AGENT_INDICATOR_DIR:-{target_dir}}}\"/scripts/agent-state.sh --agent claude --state running",
    ],
    "PermissionRequest": [
        f"\"${{TMUX_AGENT_INDICATOR_DIR:-{target_dir}}}\"/scripts/agent-state.sh --agent claude --state needs-input",
    ],
    "Stop": [
        f"\"${{TMUX_AGENT_INDICATOR_DIR:-{target_dir}}}\"/scripts/agent-state.sh --agent claude --state done",
    ],
}

if mode == "install":
    for event, commands in events.items():
        entries = hooks.get(event, [])
        for command in commands:
            entries.append({
                "matcher": "",
                "hooks": [{"type": "command", "command": command}],
            })
        hooks[event] = entries

settings["hooks"] = hooks

status_line = settings.get("statusLine")
status_command = status_line.get("command", "") if isinstance(status_line, dict) else ""
wrapped, previous_command = unwrap_statusline(status_command)

if mode == "install" and (status_line is None or isinstance(status_line, dict)):
    if not wrapped:
        previous_command = status_command
    encoded = base64.b64encode(previous_command.encode("utf-8")).decode("ascii")
    script = shlex.quote(str(pathlib.Path(target_dir) / "scripts" / "agent-limits.py"))
    command = f"{script} claude-statusline"
    if encoded:
        command += f" --previous-command-base64 {encoded}"
    updated = dict(status_line) if isinstance(status_line, dict) else {}
    updated["type"] = "command"
    updated["command"] = command
    settings["statusLine"] = updated
elif mode == "uninstall" and wrapped:
    if previous_command:
        updated = dict(status_line)
        updated["command"] = previous_command
        settings["statusLine"] = updated
    else:
        settings.pop("statusLine", None)

settings_path.write_text(json.dumps(settings, indent=2) + "\n", encoding="utf-8")
PY
    fi
fi

if [ "$INSTALL_CODEX" = true ] || [ "$UNINSTALL_CODEX" = true ]; then
    CODEX_DIR="${CODEX_CONFIG_DIR:-$HOME/.codex}"
    CODEX_CONFIG="$CODEX_DIR/config.toml"
    mkdir -p "$CODEX_DIR"

    if [ "$INSTALL_CODEX" = true ]; then
        echo "Codex detected"
        echo "  Notify -> $CODEX_CONFIG"
    fi

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

OPENCODE_PLUGIN_NAME="opencode-tmux-agent-indicator.js"

if [ "$INSTALL_OPENCODE" = true ]; then
    OPENCODE_PLUGINS_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/opencode/plugins"
    echo "OpenCode detected"
    echo "  Plugin -> $OPENCODE_PLUGINS_DIR/$OPENCODE_PLUGIN_NAME"
    mkdir -p "$OPENCODE_PLUGINS_DIR"
    cp "$TARGET_DIR/plugins/$OPENCODE_PLUGIN_NAME" "$OPENCODE_PLUGINS_DIR/$OPENCODE_PLUGIN_NAME"
fi

if [ "$UNINSTALL_OPENCODE" = true ]; then
    OPENCODE_PLUGINS_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/opencode/plugins"
    rm -f "$OPENCODE_PLUGINS_DIR/$OPENCODE_PLUGIN_NAME"
fi

cat <<EOF
Installed/updated tmux-agent-indicator in:
  $TARGET_DIR

Add to ~/.tmux.conf (TPM):
  set -g @plugin 'accessd/tmux-agent-indicator'

Or direct load:
  run-shell '$TARGET_DIR/agent-indicator.tmux'

Status example:
  set -g status-right '#{agent_limits} #{agent_indicator} | %H:%M'

If using minimal-tmux-status:
  set -g @minimal-tmux-status-right '#{agent_limits} #{agent_indicator} #(gitmux "#{pane_current_path}")'

Reload tmux:
  tmux source-file ~/.tmux.conf
EOF

if [ "$UNINSTALL_CLAUDE" = true ]; then
    echo "Removed tmux-agent-indicator Claude hooks/status-line wrapper from: ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json"
fi

if [ "$UNINSTALL_CODEX" = true ]; then
    echo "Removed tmux-agent-indicator Codex notify from: ${CODEX_CONFIG_DIR:-$HOME/.codex}/config.toml"
fi

if [ "$UNINSTALL_OPENCODE" = true ]; then
    echo "Removed tmux-agent-indicator OpenCode plugin from: ${XDG_CONFIG_HOME:-$HOME/.config}/opencode/plugins/"
fi

if [[ -t 0 ]]; then
    printf "\nConfigure colors now? [Y/n]: "
    read -r setup_reply
    case "${setup_reply:-Y}" in
        [nN]*) ;;
        *) bash "$TARGET_DIR/setup.sh" ;;
    esac
else
    echo ""
    echo "To configure colors interactively:"
    echo "  bash $TARGET_DIR/setup.sh"
fi
