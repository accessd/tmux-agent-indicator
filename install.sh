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
  --no-codex           Skip Codex hooks setup
  --no-opencode        Skip OpenCode plugin setup
  --uninstall-claude   Remove Claude hooks/status-line wrapper from ~/.claude/settings.json
  --uninstall-codex    Remove tmux-agent-indicator Codex hooks from ~/.codex/hooks.json
  --uninstall-opencode Remove tmux-agent-indicator OpenCode plugin from ~/.config/opencode/plugins/
  -h, --help           Show this help

When any --uninstall-* option is given, only the requested removals run
(nothing is copied or installed).

Environment:
  CLAUDE_CONFIG_DIR    Claude config dir (default: ~/.claude)
  CODEX_CONFIG_DIR     Codex config dir override (default: $CODEX_HOME, then ~/.codex)
  CODEX_HOME           Codex home dir (default: ~/.codex)
  XDG_CONFIG_HOME      Base for the OpenCode config dir (default: ~/.config)
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
            shift
            ;;
        --uninstall-codex)
            UNINSTALL_CODEX=true
            shift
            ;;
        --uninstall-opencode)
            UNINSTALL_OPENCODE=true
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

# Any --uninstall-* flag makes the run uninstall-only: nothing is copied and no
# integration is installed.
DO_COPY=true
if [ "$UNINSTALL_CLAUDE" = true ] || [ "$UNINSTALL_CODEX" = true ] || [ "$UNINSTALL_OPENCODE" = true ]; then
    DO_COPY=false
    INSTALL_CLAUDE=false
    INSTALL_CODEX=false
    INSTALL_OPENCODE=false
fi

# Hook commands and the status line embed this path, so it must be absolute.
if [ "$DO_COPY" = true ]; then
    mkdir -p "$TARGET_DIR"
    TARGET_DIR="$(cd "$TARGET_DIR" && pwd)"
fi

CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
CODEX_DIR="${CODEX_CONFIG_DIR:-${CODEX_HOME:-$HOME/.codex}}"
OPENCODE_CFG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/opencode"

# Auto-detect agents: skip integration if agent not found on system
if [ "$INSTALL_CLAUDE" = true ] && ! command -v claude >/dev/null 2>&1 && [ ! -d "$CLAUDE_DIR" ]; then
    INSTALL_CLAUDE=false
    echo "Claude not detected, skipping hooks setup"
fi

if [ "$INSTALL_CODEX" = true ] && ! command -v codex >/dev/null 2>&1 && [ ! -d "$CODEX_DIR" ]; then
    INSTALL_CODEX=false
    echo "Codex not detected, skipping hooks setup"
fi

if [ "$INSTALL_OPENCODE" = true ] && ! command -v opencode >/dev/null 2>&1 && [ ! -d "$OPENCODE_CFG_DIR" ]; then
    INSTALL_OPENCODE=false
    echo "OpenCode not detected, skipping plugin setup"
fi

if [ "$DO_COPY" = true ]; then
    mkdir -p "$TARGET_DIR/scripts" "$TARGET_DIR/hooks" "$TARGET_DIR/plugins" "$TARGET_DIR/licenses"

    cp "$SCRIPT_DIR/agent-indicator.tmux" "$TARGET_DIR/"
    cp "$SCRIPT_DIR/README.md" "$TARGET_DIR/"
    cp "$SCRIPT_DIR/LICENSE" "$TARGET_DIR/"
    cp "$SCRIPT_DIR/setup.sh" "$TARGET_DIR/"
    # Copy whole runtime directories so sourced helpers (e.g. scripts/lib/) and
    # every plugin file are included.
    for runtime_dir in scripts hooks plugins licenses; do
        cp -R "$SCRIPT_DIR/$runtime_dir/." "$TARGET_DIR/$runtime_dir/"
    done
    find "$TARGET_DIR/scripts" -name __pycache__ -type d -prune -exec rm -rf {} +

    chmod +x "$TARGET_DIR/agent-indicator.tmux" "$TARGET_DIR/setup.sh"
    find "$TARGET_DIR/scripts" -type f \( -name '*.sh' -o -name '*.py' \) -exec chmod +x {} +
fi

if [ "$INSTALL_CLAUDE" = true ] || [ "$UNINSTALL_CLAUDE" = true ]; then
    CLAUDE_SETTINGS="$CLAUDE_DIR/settings.json"
    CLAUDE_TEMPLATE="$TARGET_DIR/hooks/claude-hooks.json"

    if [ "$INSTALL_CLAUDE" = true ]; then
        mkdir -p "$CLAUDE_DIR"
        echo "Claude detected"
        echo "  Hooks/status line -> $CLAUDE_SETTINGS"
    fi

    if [ "$INSTALL_CLAUDE" = true ] || [ -f "$CLAUDE_SETTINGS" ]; then
        if [ "$UNINSTALL_CLAUDE" = true ]; then
            CLAUDE_MODE="uninstall"
        else
            CLAUDE_MODE="install"
        fi

        python3 - "$CLAUDE_SETTINGS" "$CLAUDE_TEMPLATE" "$TARGET_DIR" "$CLAUDE_MODE" <<'PY'
import base64
import copy
import json
import os
import pathlib
import shlex
import shutil
import stat
import sys
import tempfile

settings_path = pathlib.Path(sys.argv[1])
template_path = pathlib.Path(sys.argv[2])
target_dir = sys.argv[3]
mode = sys.argv[4]
default_install_dir = "$HOME/.tmux/plugins/tmux-agent-indicator"


def fail(message):
    print(f"tmux-agent-indicator: {message}", file=sys.stderr)
    sys.exit(1)


def load_json_object(path):
    """Return (parsed object, original text); abort without touching the file on bad input."""
    if not path.exists():
        return {}, None
    try:
        original = path.read_bytes().decode("utf-8-sig")
        data = {} if not original.strip() else json.loads(original)
    except (OSError, ValueError) as error:
        fail(f"cannot parse {path}: {error}\n  Fix the file and re-run; it was left untouched.")
    if not isinstance(data, dict):
        fail(f"{path} does not contain a JSON object; it was left untouched.")
    return data, original


def write_atomic(path, text, original):
    """Back up the previous content to <file>.bak, then replace via same-dir temp file + rename."""
    if original == text:
        return
    real = os.path.realpath(path)
    file_mode = None
    if os.path.exists(real):
        file_mode = stat.S_IMODE(os.stat(real).st_mode)
        shutil.copy2(real, real + ".bak")
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(real), prefix=os.path.basename(real) + ".tmp.")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(text)
            handle.flush()
            os.fsync(handle.fileno())
        if file_mode is not None:
            os.chmod(tmp, file_mode)
        os.replace(tmp, real)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


settings, original = load_json_object(settings_path)
before = copy.deepcopy(settings)

hooks = settings.get("hooks", {})
if not isinstance(hooks, dict):
    fail(f'"hooks" in {settings_path} is not a JSON object; it was left untouched.')
had_hooks = "hooks" in settings

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
    if not isinstance(entries, list):
        continue

    cleaned_entries = []
    for entry in entries:
        if not isinstance(entry, dict):
            cleaned_entries.append(entry)
            continue

        hook_items = entry.get("hooks", [])
        if not isinstance(hook_items, list):
            cleaned_entries.append(entry)
            continue

        cleaned_hook_items = []
        for hook_item in hook_items:
            if not isinstance(hook_item, dict):
                cleaned_hook_items.append(hook_item)
                continue

            cmd = hook_item.get("command", "")
            if isinstance(cmd, str) and is_plugin_command(cmd):
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

if mode == "install":
    template_text = template_path.read_text(encoding="utf-8").replace(
        default_install_dir, json.dumps(target_dir)[1:-1]
    )
    template = json.loads(template_text)
    template_hooks = template.get("hooks", {}) if isinstance(template, dict) else {}
    for event, entries in template_hooks.items():
        if isinstance(entries, list):
            hooks.setdefault(event, []).extend(entries)

if hooks or had_hooks or mode == "install":
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

if original is not None and settings == before:
    sys.exit(0)

try:
    write_atomic(settings_path, json.dumps(settings, indent=2) + "\n", original)
except OSError as error:
    fail(f"cannot write {settings_path}: {error}")
PY
    fi
fi

if [ "$INSTALL_CODEX" = true ] || [ "$UNINSTALL_CODEX" = true ]; then
    CODEX_HOOKS="$CODEX_DIR/hooks.json"
    CODEX_TEMPLATE="$TARGET_DIR/hooks/codex-hooks.json"
    CODEX_CONFIG="$CODEX_DIR/config.toml"

    if [ "$INSTALL_CODEX" = true ]; then
        mkdir -p "$CODEX_DIR"
        echo "Codex detected"
        echo "  Hooks -> $CODEX_HOOKS (UserPromptSubmit, PermissionRequest, PostToolUse, Stop)"
        echo "  Next: run /hooks in Codex and trust the tmux-agent-indicator hooks"
    fi

    if [ "$INSTALL_CODEX" = true ] || [ -f "$CODEX_HOOKS" ]; then
        if [ "$UNINSTALL_CODEX" = true ]; then
            CODEX_MODE="uninstall"
        else
            CODEX_MODE="install"
        fi

        python3 - "$CODEX_HOOKS" "$CODEX_TEMPLATE" "$TARGET_DIR" "$CODEX_MODE" <<'PY'
import copy
import json
import os
import pathlib
import shutil
import stat
import sys
import tempfile

hooks_path = pathlib.Path(sys.argv[1])
template_path = pathlib.Path(sys.argv[2])
target_dir = sys.argv[3]
mode = sys.argv[4]
default_install_dir = "$HOME/.tmux/plugins/tmux-agent-indicator"


def fail(message):
    print(f"tmux-agent-indicator: {message}", file=sys.stderr)
    sys.exit(1)


def load_json_object(path):
    """Return (parsed object, original text); abort without touching the file on bad input."""
    if not path.exists():
        return {}, None
    try:
        original = path.read_bytes().decode("utf-8-sig")
        data = {} if not original.strip() else json.loads(original)
    except (OSError, ValueError) as error:
        fail(f"cannot parse {path}: {error}\n  Fix the file and re-run; it was left untouched.")
    if not isinstance(data, dict):
        fail(f"{path} does not contain a JSON object; it was left untouched.")
    return data, original


def write_atomic(path, text, original):
    """Back up the previous content to <file>.bak, then replace via same-dir temp file + rename."""
    if original == text:
        return
    real = os.path.realpath(path)
    file_mode = None
    if os.path.exists(real):
        file_mode = stat.S_IMODE(os.stat(real).st_mode)
        shutil.copy2(real, real + ".bak")
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(real), prefix=os.path.basename(real) + ".tmp.")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(text)
            handle.flush()
            os.fsync(handle.fileno())
        if file_mode is not None:
            os.chmod(tmp, file_mode)
        os.replace(tmp, real)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


settings, original = load_json_object(hooks_path)
before = copy.deepcopy(settings)

hooks = settings.get("hooks", {})
if not isinstance(hooks, dict):
    fail(f'"hooks" in {hooks_path} is not a JSON object; it was left untouched.')
had_hooks = "hooks" in settings

def is_plugin_command(command):
    return "scripts/agent-state.sh" in command and "--agent codex --state" in command

for event in list(hooks.keys()):
    entries = hooks.get(event, [])
    if not isinstance(entries, list):
        continue

    cleaned_entries = []
    for entry in entries:
        if not isinstance(entry, dict):
            cleaned_entries.append(entry)
            continue

        hook_items = entry.get("hooks", [])
        if not isinstance(hook_items, list):
            cleaned_entries.append(entry)
            continue

        cleaned_hook_items = []
        for hook_item in hook_items:
            if not isinstance(hook_item, dict):
                cleaned_hook_items.append(hook_item)
                continue

            command = hook_item.get("command", "")
            if isinstance(command, str) and is_plugin_command(command):
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

if mode == "install":
    template_text = template_path.read_text(encoding="utf-8").replace(
        default_install_dir, json.dumps(target_dir)[1:-1]
    )
    template = json.loads(template_text)
    template_hooks = template.get("hooks", {}) if isinstance(template, dict) else {}
    for event, entries in template_hooks.items():
        if isinstance(entries, list):
            hooks.setdefault(event, []).extend(entries)

if hooks or had_hooks or mode == "install":
    settings["hooks"] = hooks

if original is not None and settings == before:
    sys.exit(0)

try:
    write_atomic(hooks_path, json.dumps(settings, indent=2) + "\n", original)
except OSError as error:
    fail(f"cannot write {hooks_path}: {error}")
PY
    fi

    if [ -f "$CODEX_CONFIG" ]; then
        python3 - "$CODEX_CONFIG" <<'PY'
import pathlib
import re
import sys

config_path = pathlib.Path(sys.argv[1])
text = config_path.read_text(encoding="utf-8")
updated = re.sub(
    r'(?m)^[ \t]*notify[ \t]*=[ \t]*\[\s*"bash"\s*,\s*".*/adapters/codex-notify\.sh"\s*\][ \t]*\n?',
    "",
    text,
)
if updated != text:
    config_path.write_text(updated, encoding="utf-8")
PY
    fi
fi

OPENCODE_PLUGIN_NAME="opencode-tmux-agent-indicator.js"
OPENCODE_PLUGINS_DIR="$OPENCODE_CFG_DIR/plugins"

if [ "$INSTALL_OPENCODE" = true ]; then
    echo "OpenCode detected"
    echo "  Plugin -> $OPENCODE_PLUGINS_DIR/$OPENCODE_PLUGIN_NAME"
    mkdir -p "$OPENCODE_PLUGINS_DIR"
    cp "$TARGET_DIR/plugins/$OPENCODE_PLUGIN_NAME" "$OPENCODE_PLUGINS_DIR/$OPENCODE_PLUGIN_NAME"
fi

if [ "$UNINSTALL_OPENCODE" = true ]; then
    rm -f "$OPENCODE_PLUGINS_DIR/$OPENCODE_PLUGIN_NAME"
fi

if [ "$DO_COPY" = true ]; then
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
fi

if [ "$UNINSTALL_CLAUDE" = true ]; then
    echo "Removed tmux-agent-indicator Claude hooks/status-line wrapper from: $CLAUDE_DIR/settings.json"
fi

if [ "$UNINSTALL_CODEX" = true ]; then
    echo "Removed tmux-agent-indicator Codex hooks from: $CODEX_DIR/hooks.json"
fi

if [ "$UNINSTALL_OPENCODE" = true ]; then
    echo "Removed tmux-agent-indicator OpenCode plugin from: $OPENCODE_CFG_DIR/plugins/"
fi

if [ "$DO_COPY" = true ]; then
    # Under `curl | bash` stdin is the script, so prompt on the controlling
    # terminal instead. Only do so when stdout is also a terminal.
    if [ -t 1 ] && ( exec </dev/tty ) 2>/dev/null; then
        printf "\nConfigure colors now? [Y/n]: "
        read -r setup_reply </dev/tty || setup_reply="n"
        case "${setup_reply:-Y}" in
            [nN]*) ;;
            *) bash "$TARGET_DIR/setup.sh" </dev/tty ;;
        esac
    else
        echo ""
        echo "To configure colors interactively:"
        echo "  bash $TARGET_DIR/setup.sh"
    fi
fi
