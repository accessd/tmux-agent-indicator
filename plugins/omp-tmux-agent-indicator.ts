// tmux-agent-indicator extension for oh-my-pi (omp).
// Install to ~/.omp/agent/extensions/ (copy or symlink).
// Tracks session state and calls agent-state.sh to update tmux pane visuals.
import { existsSync, realpathSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import type { ExtensionAPI } from "@oh-my-pi/pi-coding-agent";

type State = "running" | "needs-input" | "done" | "off";

export default function tmuxAgentIndicator(pi: ExtensionAPI) {
	if (!process.env.TMUX) return;

	// The checkout this file lives in (when symlinked from it), then the plugin
	// tmux loaded, then the TPM default.
	const scripts = [
		dirname(dirname(realpathSync(fileURLToPath(import.meta.url)))),
		process.env.TMUX_AGENT_INDICATOR_DIR,
		`${process.env.HOME}/.tmux/plugins/tmux-agent-indicator`,
	]
		.filter((dir): dir is string => Boolean(dir))
		.map((dir) => join(dir, "scripts", "agent-state.sh"));
	const script = scripts.find((s) => existsSync(s)) ?? scripts[scripts.length - 1];

	let last: State = "off";
	// Serialize calls without blocking omp's event dispatch.
	let queue: Promise<unknown> = Promise.resolve();

	const set = (state: State, { reset = false } = {}) => {
		if (state === last) return;
		last = state;
		const states: State[] = reset ? ["off", state] : [state];
		queue = queue.then(async () => {
			for (const s of states) {
				// Non-fatal: tmux may not be available.
				await pi.exec("bash", [script, "--agent", "omp", "--state", s]).catch(() => {});
			}
		});
	};

	// Subagent sessions share this factory; only the session in the pane counts.
	const main = (ctx: { agent?: { kind?: string } }) => ctx.agent?.kind !== "sub";

	pi.on("agent_start", (_e, ctx) => {
		if (main(ctx)) set("running", { reset: true });
	});
	pi.on("agent_end", (_e, ctx) => {
		if (main(ctx)) set("done");
	});
	pi.on("tool_approval_requested", (_e, ctx) => {
		if (main(ctx)) set("needs-input");
	});
	pi.on("tool_approval_resolved", (_e, ctx) => {
		if (main(ctx)) set("running");
	});
	pi.on("tool_execution_start", (e, ctx) => {
		if (main(ctx) && e.toolName === "ask") set("needs-input");
	});
	pi.on("tool_execution_end", (e, ctx) => {
		if (main(ctx) && e.toolName === "ask") set("running");
	});
	pi.on("session_shutdown", () => set("off"));
}
