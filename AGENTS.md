# Repository Guidelines

## Project Structure & Module Organization
This repository is a tmux plugin written in Bash.

- `agent-indicator.tmux`: plugin entrypoint; injects `#{agent_indicator}` and registers focus/window hooks.
- `scripts/agent-state.sh`: state machine for `running`, `needs-input`, `done`, `off`; applies/restores pane, border, and window-title styles.
- `scripts/pane-focus-in.sh`: clears deferred `done` styling when pane/window focus changes.
- `scripts/indicator.sh`: status segment renderer (icons + process/state detection).
- `hooks/claude-hooks.json`: Claude hook template.
- `docs/`: product notes and testing docs (`docs/PRD.md`, `docs/TESTING.md`, assets).

Keep runtime logic in `scripts/`; keep `agent-indicator.tmux` focused on bootstrap/hook wiring.

## Build, Test, and Development Commands
No build step is required.

- `bash -n agent-indicator.tmux scripts/*.sh install.sh`: syntax check.
- `shellcheck agent-indicator.tmux scripts/*.sh install.sh`: lint (if installed).
- `tmux source-file ~/.tmux.conf`: reload tmux config.
- `./install.sh --target-dir ~/.tmux/plugins/tmux-agent-indicator`: local install/update.

For behavior verification, use the step-by-step playbooks in `docs/TESTING.md`.

## Coding Style & Naming Conventions
- Bash with `#!/usr/bin/env bash` and `set -euo pipefail`.
- Indentation: 4 spaces, no tabs.
- Script names: lowercase kebab-case (for example `agent-state.sh`).
- Variables: uppercase for exported/config keys (`TMUX_AGENT_*`), lowercase for locals.
- Always quote expansions (`"$var"`), and keep tmux failures non-fatal where recovery is expected (`|| true`).

## Testing Guidelines
- Prefer automated tmux-socket tests first, then manual UX checks.
- Validate all four states: `running`, `needs-input`, `done`, `off`.
- Verify empty-value semantics (`''`) skip property application.
- Verify focus-driven reset behavior for done styling (pane/window focus hooks).

Use `docs/TESTING.md` as the source of truth for commands and expected results.

## Commit & Pull Request Guidelines
- Commit messages: imperative, concise subject (for example `Remove obsolete wrapper script`).
- PRs should include: intent, exact validation commands, and README/docs updates for option/behavior changes.
- Include screenshots when UI styling behavior changes (pane background, border, window title, status indicator).
