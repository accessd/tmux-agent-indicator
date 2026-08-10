# Testing Guide

This guide defines repeatable checks for `tmux-agent-indicator` in automated and manual modes.

## Prerequisites

- Run from repository root.
- `tmux` is installed.
- Plugin loaded with `run-shell '/path/to/agent-indicator.tmux'` (or TPM).

## Automated Mode (Isolated tmux server)

Preferred: run executable test scripts from `tests/`.

Run all checks:

```bash
./tests/run-all.sh
```

Run individual checks:

```bash
./tests/test-agent-limits.sh
./tests/test-state-transitions.sh
./tests/test-indicator-output.sh
./tests/test-notification-panel.sh
./tests/test-focus-reset-done.sh
./tests/test-window-title-reset.sh
./tests/test-running-animation.sh
```

`test-notification-panel.sh` covers the server-wide agent snapshot, status and working-directory groups, multi-line cards, terminal-title summaries, pane pins, all panel states, stale and mismatched hooks, default `pi` detection, ordering, popup close binding, and pane navigation.

Check live provider limits without the tmux cache:

```bash
python3 scripts/agent-limits.py --no-cache
```

The output contains only unexpired provider windows. Example: `C 5h 4% used · X 7d 2% used`.

Manual tmux-socket commands (below) are still useful for debugging.

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

Window-switch title reset assertion (fails if style clears before returning to source window, or does not clear after returning):

```bash
set -euo pipefail
tmux -L "$SOCK" run-shell "TMUX_PANE=$PANE \"$PWD/scripts/agent-state.sh\" --agent claude --state needs-input"
before_style="$(tmux -L "$SOCK" show-window-option -v -t "$WIN" window-status-style 2>/dev/null || true)"
before_current_style="$(tmux -L "$SOCK" show-window-option -v -t "$WIN" window-status-current-style 2>/dev/null || true)"
[ -n "$before_style" ] || { echo "FAIL: window-status-style was not applied before switch"; exit 1; }
[ -n "$before_current_style" ] || { echo "FAIL: window-status-current-style was not applied before switch"; exit 1; }

tmux -L "$SOCK" run-shell "$PWD/scripts/pane-focus-in.sh \"$OTHER_PANE\" \"$OTHER_WIN\""
while_away_style="$(tmux -L "$SOCK" show-window-option -v -t "$WIN" window-status-style 2>/dev/null || true)"
while_away_current_style="$(tmux -L "$SOCK" show-window-option -v -t "$WIN" window-status-current-style 2>/dev/null || true)"
[ -n "$while_away_style" ] || { echo "FAIL: window-status-style cleared before returning to source window"; exit 1; }
[ -n "$while_away_current_style" ] || { echo "FAIL: window-status-current-style cleared before returning to source window"; exit 1; }

tmux -L "$SOCK" run-shell "$PWD/scripts/pane-focus-in.sh \"$PANE\" \"$WIN\""
after_return_style="$(tmux -L "$SOCK" show-window-option -v -t "$WIN" window-status-style 2>/dev/null || true)"
after_return_current_style="$(tmux -L "$SOCK" show-window-option -v -t "$WIN" window-status-current-style 2>/dev/null || true)"

[ -z "$after_return_style" ] || { echo "FAIL: stale window-status-style remains after returning: $after_return_style"; exit 1; }
[ -z "$after_return_current_style" ] || { echo "FAIL: stale window-status-current-style remains after returning: $after_return_current_style"; exit 1; }
echo "PASS: window title styles reset only when returning to source window"
```

Running animation assertion (fails if animation does not tick or cleanup):

```bash
set -euo pipefail
tmux -L "$SOCK" set -g @agent-indicator-animation-enabled 'on'
tmux -L "$SOCK" set -g @agent-indicator-animation-speed '80'
tmux -L "$SOCK" run-shell "TMUX_PANE=$PANE \"$PWD/scripts/agent-state.sh\" --agent claude --state running"

anim_pid=""
for _ in $(seq 1 20); do
  anim_pid="$(tmux -L "$SOCK" show-environment -g TMUX_AGENT_ANIMATION_PID 2>/dev/null | sed 's/^[^=]*=//' || true)"
  [ -n "$anim_pid" ] && break
  sleep 0.05
done
[ -n "$anim_pid" ] || { echo "FAIL: animation PID was not created"; exit 1; }

first_frame="$(tmux -L "$SOCK" show-environment -g TMUX_AGENT_ANIMATION_FRAME 2>/dev/null | sed 's/^[^=]*=//' || true)"
[ -n "$first_frame" ] || { echo "FAIL: first animation frame is empty"; exit 1; }

tmux -L "$SOCK" run-shell "TMUX_PANE=$PANE \"$PWD/scripts/indicator.sh\" > /tmp/agent-indicator.out"
indicator_output="$(cat /tmp/agent-indicator.out)"
printf '%s' "$indicator_output" | rg -q '━' || { echo "FAIL: indicator bar is missing while running"; exit 1; }

changed=0
for _ in $(seq 1 20); do
  sleep 0.1
  next_frame="$(tmux -L "$SOCK" show-environment -g TMUX_AGENT_ANIMATION_FRAME 2>/dev/null | sed 's/^[^=]*=//' || true)"
  if [ -n "$next_frame" ] && [ "$next_frame" != "$first_frame" ]; then
    changed=1
    break
  fi
done
[ "$changed" -eq 1 ] || { echo "FAIL: animation frame did not change"; exit 1; }

tmux -L "$SOCK" run-shell "TMUX_PANE=$PANE \"$PWD/scripts/agent-state.sh\" --agent claude --state done"
sleep 0.2

anim_pid_after="$(tmux -L "$SOCK" show-environment -g TMUX_AGENT_ANIMATION_PID 2>/dev/null | sed 's/^[^=]*=//' || true)"
frame_after="$(tmux -L "$SOCK" show-environment -g TMUX_AGENT_ANIMATION_FRAME 2>/dev/null | sed 's/^[^=]*=//' || true)"
[ -z "$anim_pid_after" ] || { echo "FAIL: animation PID still present after done"; exit 1; }
[ -z "$frame_after" ] || { echo "FAIL: animation frame still present after done"; exit 1; }
echo "PASS: running animation ticks and cleans up"
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
   - With `@agent-indicator-animation-enabled on`, running state animates the status indicator.
   - Switching away keeps title styling; it clears when you focus the source pane/window again (`needs-input` and `done`).
   - With `@agent-indicator-reset-on-focus on`, done pane styling clears when focusing pane/window.
4. Validate empty-value semantics (`set -g @agent-indicator-done-bg ''` should skip background changes).
5. Validate status icon appears when agent state/process is active.

Optional screenshot capture:

```bash
screencapture -x /tmp/tmux-agent-indicator-check.png
```
