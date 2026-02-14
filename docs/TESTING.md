# Testing Guide

This guide defines repeatable checks for `tmux-agent-indicator` in automated and manual modes.

## Prerequisites

- Run from repository root.
- `tmux` is installed.
- Plugin loaded with `run-shell '/path/to/agent-indicator.tmux'` (or TPM).

## Automated Mode (Isolated tmux server)

Use a dedicated socket so tests do not affect your normal tmux session:

```bash
SOCK=agent-test-$$
tmux -L "$SOCK" -f /dev/null new-session -d -s ai -n main
tmux -L "$SOCK" set -g status-right '#{agent_indicator} | %H:%M'
tmux -L "$SOCK" run-shell "$PWD/agent-indicator.tmux"
PANE="$(tmux -L "$SOCK" display-message -p -t ai:main.0 '#{pane_id}')"
WIN="$(tmux -L "$SOCK" display-message -p -t ai:main.0 '#{window_id}')"
```

Trigger each state on the same pane:

```bash
tmux -L "$SOCK" run-shell "TMUX_PANE=$PANE \"$PWD/scripts/agent-state.sh\" --agent claude --state running"
tmux -L "$SOCK" run-shell "TMUX_PANE=$PANE \"$PWD/scripts/agent-state.sh\" --agent claude --state needs-input"
tmux -L "$SOCK" run-shell "TMUX_PANE=$PANE \"$PWD/scripts/agent-state.sh\" --agent claude --state done"
tmux -L "$SOCK" run-shell "TMUX_PANE=$PANE \"$PWD/scripts/agent-state.sh\" --agent claude --state off"
```

Core assertions:

```bash
tmux -L "$SOCK" show-window-options -vt "$WIN" | rg 'pane-active-border-style|window-status'
tmux -L "$SOCK" run-shell "TMUX_PANE=$PANE \"$PWD/scripts/indicator.sh\" > /tmp/agent-indicator.out"
cat /tmp/agent-indicator.out
```

Focus-reset check:

```bash
tmux -L "$SOCK" run-shell "TMUX_PANE=$PANE \"$PWD/scripts/agent-state.sh\" --agent claude --state done"
tmux -L "$SOCK" run-shell "$PWD/scripts/pane-focus-in.sh \"$PANE\" \"$WIN\""
tmux -L "$SOCK" show-window-options -vt "$WIN" | rg 'window-status'
```

Window-switch title reset check:

```bash
tmux -L "$SOCK" new-window -d -t ai -n other
OTHER_PANE="$(tmux -L "$SOCK" display-message -p -t ai:other.0 '#{pane_id}')"
OTHER_WIN="$(tmux -L "$SOCK" display-message -p -t ai:other.0 '#{window_id}')"
tmux -L "$SOCK" run-shell "TMUX_PANE=$PANE \"$PWD/scripts/agent-state.sh\" --agent claude --state needs-input"
tmux -L "$SOCK" run-shell "$PWD/scripts/pane-focus-in.sh \"$OTHER_PANE\" \"$OTHER_WIN\""
tmux -L "$SOCK" show-window-options -vt "$WIN" | rg 'window-status'
```

Window-switch title reset assertion (fails if stale style remains):

```bash
set -euo pipefail
tmux -L "$SOCK" run-shell "TMUX_PANE=$PANE \"$PWD/scripts/agent-state.sh\" --agent claude --state needs-input"
before_style="$(tmux -L "$SOCK" show-window-option -v -t "$WIN" window-status-style 2>/dev/null || true)"
before_current_style="$(tmux -L "$SOCK" show-window-option -v -t "$WIN" window-status-current-style 2>/dev/null || true)"
[ -n "$before_style" ] || { echo "FAIL: window-status-style was not applied before switch"; exit 1; }
[ -n "$before_current_style" ] || { echo "FAIL: window-status-current-style was not applied before switch"; exit 1; }

tmux -L "$SOCK" run-shell "$PWD/scripts/pane-focus-in.sh \"$OTHER_PANE\" \"$OTHER_WIN\""
after_style="$(tmux -L "$SOCK" show-window-option -v -t "$WIN" window-status-style 2>/dev/null || true)"
after_current_style="$(tmux -L "$SOCK" show-window-option -v -t "$WIN" window-status-current-style 2>/dev/null || true)"

[ -z "$after_style" ] || { echo "FAIL: stale window-status-style remains: $after_style"; exit 1; }
[ -z "$after_current_style" ] || { echo "FAIL: stale window-status-current-style remains: $after_current_style"; exit 1; }
echo "PASS: window title styles reset after switching windows"
```

Cleanup:

```bash
tmux -L "$SOCK" kill-server
rm -f /tmp/agent-indicator.out
```

## Manual Mode (UX validation)

1. Open tmux with two windows (`test`, `tmux-agent-indicator`) and at least two panes in the target window.
2. In one pane, run state transitions:
   `scripts/agent-state.sh --agent claude --state running|needs-input|done|off`.
3. Confirm behavior:
   - `running/needs-input/done` apply only configured non-empty properties.
   - `off` resets pane background, border style, and window title style.
   - Switching to another window clears title styling for the previous window (`needs-input` and `done`).
   - With `@agent-indicator-reset-on-focus on`, done pane styling clears when focusing pane/window.
4. Validate empty-value semantics (`set -g @agent-indicator-done-bg ''` should skip background changes).
5. Validate status icon appears when agent state/process is active.

Optional screenshot capture:

```bash
screencapture -x /tmp/tmux-agent-indicator-check.png
```
