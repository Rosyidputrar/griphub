/**
 * What GripHub Router says each chat model can do and costs, in one place, for every feature that picks a model by
 * itself: the smart router (smartrouter.ts) and, later, the vision translator. Both filter the same way, through
 * [candidates]; neither keeps its own copy of these rules.
 *
 * Sources, and nothing else:
 *   - capabilities, context window, output limit: GET /v1/models (saved by providers.ts as CustomModel);
 *   - price: the router's LIVE rates (/api/user-usage pricing, router.ts). The built-in FALLBACK_RATES table is never
 *     used here: a model whose live price is unknown cannot be picked automatically (owner decision, 2026-11-07);
 *   - per-request minimum: the floor learned from real requests, else the router's seed floor (router.ts).
 *
 * "Verified" means the metadata says so explicitly. A capability the metadata does not mention is unknown, and an
 * unknown capability never counts as present.
 */

import type { CustomModel } from "./providers.js";
import type { Rate } from "./router.js";

export interface ModelMeta {
	id: string;
	name: string;
	/** true / false when /v1/models says so; undefined when it does not. */
	vision?: boolean;
	tools?: boolean;
	reasoning: boolean;
	contextWindow?: number;
	maxOutput?: number;
	/** Live credits per 1M tokens; undefined when the router's live rates do not price this model. */
	credits?: number;
	/** Per-request minimum in credits (0 when none is known). */
	floor: number;
	/** False when the router reports the model down. */
	available: boolean;
}

/** What one turn needs from a model. */
export interface Need {
	vision: boolean;
	tools: boolean;
	/** Tokens the model must hold: the conversation so far, this message, and room to answer. */
	minContext: number;
}

export interface CatalogSources {
	models: CustomModel[];
	/** Live rates only (router cache); undefined while none ever loaded. */
	liveRates: Record<string, Rate> | undefined;
	floor: (id: string) => number | undefined;
	available: (id: string) => boolean;
	/** Rate lookup that tolerates the router's aliases (router.ts lookup). */
	lookup: <T>(table: Record<string, T> | undefined, id: string) => T | undefined;
}

/** The chat models with what the router says about them. Image models (priced per picture) are not chat models. */
export function catalog(src: CatalogSources): ModelMeta[] {
	const out: ModelMeta[] = [];
	for (const m of src.models) {
		const rate = src.lookup(src.liveRates, m.id);
		if (rate?.perImage) continue;
		out.push({
			id: m.id,
			name: m.name ?? m.id,
			...(typeof m.vision === "boolean" ? { vision: m.vision } : m.input?.includes("image") ? { vision: true } : {}),
			...(typeof m.tools === "boolean" && { tools: m.tools }),
			reasoning: m.reasoning === true,
			...(m.contextWindow && { contextWindow: m.contextWindow }),
			...(m.maxTokens && { maxOutput: m.maxTokens }),
			...(rate && Number.isFinite(rate.credits) && rate.credits >= 0 && { credits: rate.credits }),
			floor: src.floor(m.id) ?? 0,
			available: src.available(m.id),
		});
	}
	return out;
}

/** Why a model is not a candidate; null when it is one. */
export function rejection(m: ModelMeta, need: Need, blocked: ReadonlySet<string>): string | null {
	if (blocked.has(m.id)) return "blocked";
	if (!m.available) return "down";
	if (m.credits === undefined) return "no-price";
	if (need.vision && m.vision !== true) return "no-vision";
	if (need.tools && m.tools !== true) return "no-tools";
	if (!m.contextWindow || m.contextWindow < need.minContext) return "context";
	return null;
}

/** The models that meet every need, verified from the metadata, with a known live price. */
export function candidates(models: ModelMeta[], need: Need, blocked: ReadonlySet<string> = new Set()): ModelMeta[] {
	return models.filter((m) => rejection(m, need, blocked) === null);
}

/** Credits of one request of [input] + [output] tokens, by the router's rule: max(floor, rate × tokens). */
export function requestCost(m: ModelMeta, input: number, output: number): number | null {
	if (m.credits === undefined) return null;
	return Math.max(m.floor, (m.credits * (input + output)) / 1_000_000);
}
