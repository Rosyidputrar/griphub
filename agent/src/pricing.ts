/**
 * GripHub Router pricing for estimates, by the router's own billing rule
 * (see router.ts): charged = max(floor, rate × all tokens) per successful
 * request, where "all tokens" includes cache reads and writes, and image
 * models charge per image.
 *
 * Live rates and learned floors come from the router (router.ts, cached on
 * disk); this table is only the fallback for a phone that never reached it.
 * Snapshot of /api/user-usage pricing on 27 Oct 2026, at the price charged
 * then (promos included; `list` is the normal price).
 *
 * Real credits charged (balance, per model, per day) always come from the
 * router itself; these estimates are for work still in progress, such as a
 * running subagent or turn.
 */

import { type Rate, type Router, type Usage, lookup, requestCredits, SEED_FLOORS } from "./router.js";

/** Fallback rates: credits per 1M tokens (or per image). */
export const FALLBACK_RATES: Record<string, Rate> = {
	"claude-fable-5": { credits: 8 },
	"claude-fable-5.1": { credits: 8 },
	"claude-haiku-4.5": { credits: 1 },
	"claude-haiku-5.5": { credits: 1 },
	"claude-opus-4.5": { credits: 4 },
	"claude-opus-4.6": { credits: 4 },
	"claude-opus-4.7": { credits: 4 },
	"claude-opus-4.8": { credits: 4 },
	"claude-opus-5": { credits: 4 },
	"claude-opus-5.5": { credits: 4 },
	"claude-sonnet-4.6": { credits: 2.5 },
	"claude-sonnet-5": { credits: 2.5 },
	"claude-sonnet-5.5": { credits: 2.5 },
	"deepseek-v4-flash": { credits: 0.3 },
	"deepseek-v4-pro": { credits: 1 },
	"deepseek-v4.1-flash": { credits: 0.3 },
	"deepseek-v4.1-flash-sg": { credits: 0.4 },
	"gemini-3.1-flash-image": { credits: 2.5, perImage: true },
	"gemini-3.1-pro": { credits: 2 },
	"gemini-3.8-flash": { credits: 1.5 },
	"gemini-4-argon": { credits: 4 },
	"glm-5.1": { credits: 1 },
	"glm-5.2": { credits: 1.5 },
	"glm-5.3": { credits: 1.5 },
	"glm-5.3-flash": { credits: 0.5 },
	"glm-5.3-flashx": { credits: 1 },
	"gpt-5.3-codex": { credits: 1.6 },
	"gpt-5.6-luna": { credits: 0.3 },
	"gpt-5.6-sol": { credits: 3.5 },
	"gpt-5.6-terra": { credits: 2 },
	"gpt-6-astra": { credits: 5, list: 8 },
	"gpt-6-astra-ultrafast": { credits: 16 },
	"gpt-6-luna": { credits: 0.3 },
	"gpt-6-sol": { credits: 3.5 },
	"gpt-6.1-sol": { credits: 2, list: 3.5 },
	"gpt-6.1-sol-ultrafast": { credits: 7 },
	"gpt-6.1-terra": { credits: 1.5 },
	"gpt-image": { credits: 4, perImage: true, list: 8 },
	"grok-4.6": { credits: 1 },
	"grok-4.7": { credits: 1 },
	"hy3": { credits: 0.5 },
	"hy4": { credits: 0.5 },
	"kimi-k2.6": { credits: 1 },
	"kimi-k2.7": { credits: 1 },
	"kimi-k3": { credits: 1.5 },
	"kimi-k3.1-pro": { credits: 2 },
	"mimo-v2.6-flash": { credits: 0.5 },
	"mimo-v2.6-pro": { credits: 1.5 },
	"minimax-m2.7": { credits: 0.5 },
	"minimax-m3": { credits: 0.5 },
	"muse-spark-1.2": { credits: 1 },
	"muse-spark-1.3": { credits: 1 },
	"muse-wonder-1.0": { credits: 3 },
	"qwen-3.8-flash": { credits: 0.5 },
};

let router: Router | undefined;

/** Lets estimates use live rates and learned floors (set once at boot). */
export function usePricingRouter(r: Router) {
	router = r;
}

export function rateForModel(model: string): Rate | null {
	return (router ? router.rate(model) : lookup(FALLBACK_RATES, model)) ?? null;
}

/** Credits one request is estimated to cost, or null when the model's price is unknown. */
export function requestEstimate(model: string, u: Usage, ok = true): number | null {
	if (router) return router.estimate(model, u, ok);
	return requestCredits(lookup(FALLBACK_RATES, model), lookup(SEED_FLOORS, model), u, { ok });
}

/** pi's per-message usage object -> the router's Usage. */
export function usageOf(u: any): Usage {
	return {
		input: Number(u?.input ?? 0) || 0,
		output: Number(u?.output ?? 0) || 0,
		cacheRead: Number(u?.cacheRead ?? 0) || 0,
		cacheWrite: Number(u?.cacheWrite ?? 0) || 0,
	};
}
