// tmux-agent-indicator plugin for OpenCode.
// Install to ~/.config/opencode/plugins/ or .opencode/plugins/ (project-level).
// Tracks session state and calls agent-state.sh to update tmux pane visuals.
import { existsSync, realpathSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

// OpenCode treats every export as a plugin; keep this the only one.
export const TmuxAgentIndicator = async ({ $, client }) => {
  // The checkout this file lives in (when symlinked from it, e.g. a Nix store
  // path), then the plugin tmux loaded, then the TPM default. A copied file
  // has no ../scripts next to it and falls through to the later candidates.
  const candidates = [];
  try {
    candidates.push(dirname(dirname(realpathSync(fileURLToPath(import.meta.url)))));
  } catch {
    // non-fatal: fall back to the other candidates
  }
  candidates.push(process.env.TMUX_AGENT_INDICATOR_DIR);
  candidates.push(`${process.env.HOME}/.tmux/plugins/tmux-agent-indicator`);
  const scripts = candidates
    .filter(Boolean)
    .map((dir) => join(dir, "scripts", "agent-state.sh"));
  const script = scripts.find((s) => existsSync(s)) ?? scripts[scripts.length - 1];

  let lastState = "off";
  let idleAt = 0;

  const setState = async (state) => {
    if (state === lastState) return;
    lastState = state;
    try {
      if (state === "running") {
        await $`bash ${script} --agent opencode --state off`;
      }
      await $`bash ${script} --agent opencode --state ${state}`;
    } catch {
      // non-fatal: tmux may not be available
    }
  };

  // Subagent (task tool) sessions have a parentID and emit their own
  // status/idle/error events; only the root session drives the pane. Lookups
  // are cached as promises so concurrent events for one session resolve in
  // arrival order. A failed lookup is not cached and counts as root.
  const childLookups = new Map();
  const isChildSession = (id) => {
    if (!id) return Promise.resolve(false);
    let lookup = childLookups.get(id);
    if (!lookup) {
      lookup = (async () => {
        const res = await client.session.get({ path: { id } });
        if (!res?.data) throw new Error("session lookup failed");
        return Boolean(res.data.parentID);
      })().catch(() => {
        childLookups.delete(id);
        return false;
      });
      childLookups.set(id, lookup);
    }
    return lookup;
  };

  return {
    event: async ({ event }) => {
      if (event.type === "session.status"
          && event.properties.status.type === "busy") {
        if (await isChildSession(event.properties.sessionID)) return;
        // Guard: don't override done/error if idle fired recently (race condition)
        if (Date.now() - idleAt < 2000) return;
        await setState("running");
      }

      if (event.type === "permission.updated"
          || event.type === "permission.asked") {
        await setState("needs-input");
      }

      if (event.type === "session.idle" || event.type === "session.error") {
        if (await isChildSession(event.properties?.sessionID)) return;
        idleAt = Date.now();
        await setState("done");
      }
    },
    "permission.ask": async () => {
      await setState("needs-input");
    },
    "tool.execute.before": async (input) => {
      if (input.tool === "question") {
        await setState("needs-input");
      }
    },
  };
};
