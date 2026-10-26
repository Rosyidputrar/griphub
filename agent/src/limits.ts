/**
 * Per-request limits, for chats and background runs alike. pi's agent loop
 * runs for as long as the model keeps calling tools, so without these a
 * model that keeps rephrasing a failing search (or retrying a failing
 * command) never stops, and keeps spending credits while it goes.
 *
 * A "request" is one agent run: from a prompt until the agent settles.
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

/** web_search calls per request. */
export const MAX_SEARCHES = 20;
/** Tool calls of any kind per request. */
export const MAX_TOOL_CALLS = 150;
/** Calls past MAX_TOOL_CALLS a model may still try before the run is ended for it. */
const GRACE_CALLS = 10;
/** bash commands that name no timeout of their own stop after this long. */
export const BASH_TIMEOUT_SECONDS = 600;

export interface LimitsHooks {
	/** The daily-budget refusal, or null while there is budget left. */
	budgetError(): string | null;
	/** The run was ended by a limit; tell whoever is watching. */
	stopped(reason: string): void;
}

export function limitsExtension(hooks: LimitsHooks) {
	return (pi: ExtensionAPI) => {
		let calls = 0;
		let searches = 0;
		let overBudget = false;

		pi.on("agent_start", () => {
			calls = 0;
			searches = 0;
			overBudget = false;
		});

		pi.on("tool_call", (event) => {
			calls++;
			if (overBudget) return { block: true, reason: "The daily budget is used up.", terminate: true };
			if (calls > MAX_TOOL_CALLS + GRACE_CALLS) {
				if (calls === MAX_TOOL_CALLS + GRACE_CALLS + 1) hooks.stopped(`Stopped after ${MAX_TOOL_CALLS} tool calls in one request.`);
				return { block: true, reason: "Tool-call limit reached; the run is ending.", terminate: true };
			}
			if (calls > MAX_TOOL_CALLS) {
				return {
					block: true,
					reason: `Tool-call limit for this request reached (${MAX_TOOL_CALLS}). Do not call any more tools: reply to the user now with what you have, and say what is left to do.`,
				};
			}
			if (event.toolName === "web_search" && ++searches > MAX_SEARCHES) {
				return {
					block: true,
					reason: `Web search limit for this request reached (${MAX_SEARCHES} searches). Do not search again: answer with what you found, and say what you could not verify.`,
				};
			}
			// pi's bash waits forever by default; a server started in the foreground or a prompt for input would hang the run.
			if (event.toolName === "bash") {
				const input = event.input as Record<string, unknown>;
				if (input.timeout === undefined) input.timeout = BASH_TIMEOUT_SECONDS;
			}
			return undefined;
		});

		// The budget used to be checked only when a prompt starts, so one long request could spend far past it.
		pi.on("turn_end", (_event, ctx) => {
			if (overBudget) return;
			const error = hooks.budgetError();
			if (!error) return;
			overBudget = true;
			hooks.stopped(error);
			ctx.abort();
		});
	};
}
