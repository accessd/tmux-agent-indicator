# Codex daemon hook routing

## Problem and implementation

A shared Codex app-server executes hooks with its own environment. Its inherited
`TMUX_PANE` can point at the first client even when another client submits the
prompt or finishes a turn. The adapter deliberately ignores that value as a target.

For embedded Codex, the nearest native `codex` ancestor identifies the controlling
TTY. A daemon with no TTY stops that ancestry search, even if its parent was the
first TUI client.

For the shared local daemon, configure:

```toml
[tui]
terminal_title = ["app-name", "thread-id"]
```

The client publishes a title such as `codex | 019a1234-1234-7234-8234-1234567...`.
Codex 0.164.0 truncates the UUID to 29 characters. The adapter:

1. Lists panes on registered tmux sockets and the inherited socket.
2. Keeps titles in the configured format with a live native Codex process on the pane TTY.
3. Connects over WebSocket to `$CODEX_HOME/app-server-control/app-server-control.sock`
   (`CODEX_HOME` defaults to `~/.codex`).
4. Enumerates full IDs with paginated `thread/loaded/list`, rejecting colliding prefixes.
5. Uses `thread/read` with `includeTurns: false` to verify the concrete ID and the
   hook's `session_id` against the thread's `sessionId`.
6. Requires exactly one matching pane, rechecks its title and process, then invokes
   the existing state script with the explicit socket and pane.

Only `initialize`, `initialized`, `thread/loaded/list`, and `thread/read` are sent.
The adapter does not resume threads, subscribe clients, or change Codex settings.
API discovery has a three-second deadline. Errors are best effort: hooks exit
successfully, emit a diagnostic on stderr, and leave styles unchanged.

Plugin bootstrap registers each socket in a private per-user temporary directory.
Reload the plugin on every existing tmux server after installation. Dead registry
entries are ignored. Registration and lookup must use the same temporary directory.
The installer builds the adapter and replaces this plugin's old hooks while
preserving foreign hooks and the user's title configuration. Trust the installed
hook definitions through Codex `/hooks` before using them.

## Boundaries

- Verified with the managed Codex 0.164.0 binary and its default local control socket.
  Remote/custom endpoints are unsupported. All discovered clients are expected to
  use the same local daemon; separate `CODEX_HOME` instances with copied thread IDs
  are outside the supported configuration.
- Missing/replaced titles, exited clients, unavailable API, prefix collisions,
  and multiple clients displaying the same session result in no styling changes.
- Hook `session_id` identifies a session tree, while the title identifies its
  concrete displayed thread. Matching both supports displayed descendants, but
  hooks cannot distinguish background descendants within that same session tree.
- Initial title publication must precede the hook. The adapter does not guess a
  target during startup. A later hook can establish state once the title exists.
- `off` and focus-driven clearing continue through the existing state machine.

## Verification

```bash
./tests/run-all.sh
env -u GOROOT go test -race ./cmd/codex-hook
env -u GOROOT go vet ./cmd/codex-hook
python3 tests/test-codex-hook-native.py /absolute/path/to/codex
```

The native test starts two real TUI clients in one cwd on a scratch app-server.
It invokes the production adapter with synthetic hook payloads and the real API,
checking all four styles, wrong inherited pane, duplicate/replaced titles, a false
full session ID sharing the title prefix, and stale titles. Authentication is
read through a symlink if available. No prompts or inference requests are sent;
user config, installed hooks, and live sessions are unchanged.

Go tests use isolated real tmux panes and a fake WebSocket server to cover
pagination, unsolicited notifications, prefix collisions in the full inventory,
foreign sessions, mismatched event types, unavailable API, and daemon ancestry.
Installer tests cover repeated migration, uninstall, and preservation of foreign
hooks and title settings. Existing tests cover focus resets and empty styles.

Real automatic prompt/permission/stop delivery, child-thread navigation, reconnect,
and nested tmux still require manual UX verification before release. The native
test verifies the adapter and real client identity, not automatic hook delivery.

## Primary-source evidence

- [Hook environment snapshot](https://github.com/openai/codex/blob/rust-v0.164.0/codex-rs/hooks/src/registry.rs)
  and [hook execution](https://github.com/openai/codex/blob/rust-v0.164.0/codex-rs/hooks/src/engine/command_runner.rs).
- [Title rendering and truncation](https://github.com/openai/codex/blob/rust-v0.164.0/codex-rs/tui/src/chatwidget/status_surfaces.rs)
  and [client terminal output](https://github.com/openai/codex/blob/092d3acd6bec3e3a14bdc7e7a2810ab628ab759d/codex-rs/tui/src/terminal_title.rs#L67-L108).
- [Thread/session identity and loaded-list protocol](https://github.com/openai/codex/blob/rust-v0.164.0/codex-rs/app-server-protocol/src/protocol/v2/thread.rs).
- [Default local endpoint verification](https://github.com/openai/codex/blob/rust-v0.164.0/codex-rs/tui/src/startup_orchestration.rs#L109-L133).

A per-pane protocol relay was considered. Arbitrary Unix `--remote` endpoints
change workspace classification; the native title plus read-only API approach
preserves normal client launch behavior and requires no proxy process.
