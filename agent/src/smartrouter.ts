/**
 * Smart router ("Otomatis (Pintar)"): picks, for each user turn of a chat set to automatic, the cheapest model that
 * can do the turn, from GripHub Router's own metadata (modelcaps.ts), and climbs a class when a turn proves harder.
 *
 * Nothing here calls a model: the turn is classified by local heuristics only (documented at [classify]), so routing
 * itself costs nothing. Every decision, including "no model fits", is written to the chat's routing log, which the
 * app shows in the chat's details.
 *
 * Classes are price bands, not a judgement of quality from outside the metadata: the chat models with a live price
 * are sorted by credits per 1M tokens and split into thirds (0 = cheapest third, 2 = dearest). A harder turn asks for
 * a higher band. This is the documented proxy the owner accepted; it never invents a capability (capabilities are only
 * the ones /v1/models states, see modelcaps.ts).
 */

import { existsSync, mkdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { candidates, type ModelMeta, type Need, rejection, requestCost } from "./modelcaps.js";
import { atomicWrite } from "./state.js";

export type Difficulty = 0 | 1 | 2;
export const DIFFICULTY_NAMES = ["light", "medium", "heavy"] as const;

/**
 * Why a turn got its class, as codes the app words in the user's language (lib/ui/smart_router_screen.dart):
 * plain-chat, coding-chat, heavy-words, task-words, very-long, long, code, long-conversation, image.
 */
export type ReasonCode = string;

// ---------------------------------------------------------------------------
// Classification (pure, local)

export interface TurnSignals {
	text: string;
	images: number;
	/** A coding chat (tools, projects); false for a plain conversation. */
	coding: boolean;
	/** Tokens already in the conversation (pi's context usage, or an estimate). */
	contextTokens: number;
}

/** Words that mark work rather than a question: building, fixing, changing code or systems. */
const HEAVY_WORDS =
	/\b(refactor\w*|arsitektur|architecture|migrat\w*|migrasi|optimi[sz]\w*|redesign|rancang\w*|implement\w*|implementasi|debug\w*|security|keamanan|concurren\w*|race condition|deadlock|performance|performa|algorit\w*|proof|buktikan)\b/i;
const MEDIUM_WORDS =
	/\b(buat\w*|bikin|tulis\w*|write|create|build|fix\w*|perbaiki|ubah|change|tambah\w*|add|analy[sz]\w*|analisis|jelaskan kenapa|explain why|compare|bandingkan|review|error|bug|crash|gagal|failed|exception|translate|terjemah\w*|ringkas\w*|summari[sz]\w*)\b/i;
const CODE_HINT = /```|\b(function|class|def|import|const|let|var|SELECT|public static)\b|=>|\{\s*\n|Traceback|at [\w.$]+\(.*:\d+\)/;

/**
 * Light / medium / heavy, from what can be counted on the phone:
 *   - base: a plain chat starts light, a coding chat medium (tools mean several requests and real changes);
 *   - words: a request to build, fix, analyse or translate is at least medium; refactors, architecture, migrations,
 *     debugging, security and performance work are heavy;
 *   - size: more than 1 500 characters, or pasted code / a stack trace, adds a level; more than 6 000 adds another;
 *   - a long conversation (over 60k tokens) is at least medium: the model has to keep much more in mind.
 * Past failures in the chat are not here: they raise the chat's floor ([nextFloor]).
 */
export function classify(t: TurnSignals): { difficulty: Difficulty; reasons: ReasonCode[] } {
	const reasons: ReasonCode[] = [];
	let level = t.coding ? 1 : 0;
	reasons.push(t.coding ? "coding-chat" : "plain-chat");
	const text = t.text ?? "";
	if (HEAVY_WORDS.test(text)) {
		level = Math.max(level, 2);
		reasons.push("heavy-words");
	} else if (MEDIUM_WORDS.test(text)) {
		level = Math.max(level, 1);
		reasons.push("task-words");
	}
	if (text.length > 6000) {
		level += 2;
		reasons.push("very-long");
	} else if (text.length > 1500 || CODE_HINT.test(text)) {
		level += 1;
		reasons.push(text.length > 1500 ? "long" : "code");
	}
	if (t.contextTokens > 60_000 && level < 1) {
		level = 1;
		reasons.push("long-conversation");
	}
	if (t.images > 0) reasons.push("image");
	return { difficulty: Math.min(2, level) as Difficulty, reasons };
}

// ---------------------------------------------------------------------------
// Price bands and selection (pure)

/**
 * The credit thresholds between band 0|1 and 1|2: the thirds of the live prices of all chat models. Models that are
 * down count too, so a class means the same thing while some model is out (a cheap model never becomes "heavy").
 */
export function priceBands(models: ModelMeta[]): [number, number] | null {
	const prices = models.filter((m) => m.credits !== undefined).map((m) => m.credits!).sort((a, b) => a - b);
	if (!prices.length) return null;
	const at = (q: number) => prices[Math.min(prices.length - 1, Math.floor(q * prices.length))];
	return [at(1 / 3), at(2 / 3)];
}

/** A model's band: 0 at or under the first third's top price, 2 above the second's. */
export function bandOf(m: ModelMeta, bands: [number, number]): Difficulty {
	const c = m.credits ?? Infinity;
	return c < bands[0] ? 0 : c < bands[1] ? 1 : 2;
}

/** Rough tokens a reply of each difficulty writes, and requests a turn makes, for the estimate only. */
const OUTPUT_GUESS = [600, 1500, 4000];
const REQUESTS_GUESS = { chat: [1, 1, 1], coding: [3, 6, 10] };

export function estimateTurn(m: ModelMeta, inputTokens: number, difficulty: Difficulty, coding: boolean): number | null {
	const requests = (coding ? REQUESTS_GUESS.coding : REQUESTS_GUESS.chat)[difficulty];
	const one = requestCost(m, inputTokens, OUTPUT_GUESS[difficulty]);
	return one === null ? null : one * requests;
}

export interface Choice {
	model: ModelMeta;
	band: Difficulty;
	/** The band asked for (difficulty, raised by the chat's floor). */
	wanted: Difficulty;
	estimate: number | null;
	/** True when nothing in the wanted band or above fit, and the dearest lower one was taken instead. */
	belowWanted: boolean;
}

export type Selection =
	| { ok: true; choice: Choice; considered: number }
	| { ok: false; reason: string; missing: ReasonCode[]; considered: number; rejected: Record<string, number> };

/**
 * The cheapest candidate in the wanted band or above. Heavy turns prefer a model that reasons, when one fits. When no
 * candidate reaches the band, the dearest one below is used, and the decision says so. With no candidate at all the
 * answer is a refusal with the reasons counted: the caller tells the user and never guesses.
 */
export function select(models: ModelMeta[], need: Need, wanted: Difficulty, opts: { blocked?: ReadonlySet<string>; inputTokens: number; coding: boolean }): Selection {
	const blocked = opts.blocked ?? new Set<string>();
	const fit = candidates(models, need, blocked);
	if (!fit.length) {
		const rejected: Record<string, number> = {};
		for (const m of models) {
			const why = rejection(m, need, blocked);
			if (why) rejected[why] = (rejected[why] ?? 0) + 1;
		}
		return { ok: false, reason: noCandidateReason(need, rejected), missing: missingOf(need, rejected), considered: models.length, rejected };
	}
	const bands = priceBands(models) ?? [Infinity, Infinity];
	const priced = fit.map((m) => ({ m, band: bandOf(m, bands), cost: estimateTurn(m, opts.inputTokens, wanted, opts.coding) ?? Infinity }));
	const byCost = (a: { cost: number; m: ModelMeta }, b: { cost: number; m: ModelMeta }) => a.cost - b.cost || (a.m.credits! - b.m.credits!) || a.m.id.localeCompare(b.m.id);
	let pool = priced.filter((x) => x.band >= wanted);
	if (wanted === 2) {
		const thinkers = pool.filter((x) => x.m.reasoning);
		if (thinkers.length) pool = thinkers;
	}
	let belowWanted = false;
	if (!pool.length) {
		// Nothing reaches the band: the strongest (dearest) of what fits, said as such.
		belowWanted = true;
		const top = Math.max(...priced.map((x) => x.band));
		pool = priced.filter((x) => x.band === top).sort((a, b) => b.m.credits! - a.m.credits!).slice(0, 1);
	}
	const best = [...pool].sort(byCost)[0];
	return {
		ok: true,
		considered: models.length,
		choice: { model: best.m, band: best.band, wanted, estimate: Number.isFinite(best.cost) ? best.cost : null, belowWanted },
	};
}

/** What no model offered, as codes: vision, tools, context, price. */
function missingOf(need: Need, rejected: Record<string, number>): ReasonCode[] {
	return [
		...(need.vision && rejected["no-vision"] ? ["vision"] : []),
		...(need.tools && rejected["no-tools"] ? ["tools"] : []),
		...(rejected.context ? ["context"] : []),
		...(rejected["no-price"] ? ["price"] : []),
	];
}

function noCandidateReason(need: Need, rejected: Record<string, number>): string {
	const parts: string[] = [];
	if (need.vision && rejected["no-vision"]) parts.push("reads images");
	if (need.tools && rejected["no-tools"]) parts.push("can use tools");
	if (rejected.context) parts.push(`holds ${Math.round(need.minContext / 1000)}k tokens`);
	if (rejected["no-price"]) parts.push("has a live price");
	return parts.length ? `No model that ${parts.join(", ")} is available` : "No model is available";
}

// ---------------------------------------------------------------------------
// Escalation (pure)

/** Rebukes of the last answer, in Indonesian and English. */
const REBUKE =
	/^(salah|keliru|bukan( itu| begitu)?|tidak benar|gak bener|ga bener|nggak bener|masih (salah|error|gagal|belum)|tetap (salah|error|gagal)|tidak (jalan|bekerja|berhasil)|gak jalan|ga jalan|wrong|that'?s (wrong|not (it|right|what))|not what i|still (wrong|broken|failing|not working|doesn'?t)|doesn'?t work|didn'?t work|it'?s broken|try again|coba lagi|ulangi)\b/i;

export function normalise(text: string): string {
	return text.toLowerCase().replace(/\s+/g, " ").trim();
}

/**
 * Why the last turn counts as a failure, as a code, or null: "error" (it failed), "cut-off" (the reply hit the output
 * limit), "resent" (the same request again), "rejected" (the user said the answer was wrong).
 */
export function failureOf(last: { stopReason?: string } | null, previousText: string | null, text: string): ReasonCode | null {
	if (last?.stopReason === "error") return "error";
	if (last?.stopReason === "length") return "cut-off";
	if (previousText !== null && normalise(previousText) === normalise(text) && normalise(text).length > 0) return "resent";
	if (REBUKE.test(text.trim())) return "rejected";
	return null;
}

/** The chat's new floor after a failure: one band above what the failed turn used. */
export function nextFloor(floor: Difficulty, failedBand: Difficulty | null): Difficulty {
	return Math.min(2, Math.max(floor, (failedBand ?? floor) + 1)) as Difficulty;
}

// ---------------------------------------------------------------------------
// Per-chat state and decision log (on disk, beside the chat files)

export interface Decision {
	at: number;
	/** User turns before this one: the app matches decisions to turns with it. */
	turn: number;
	kind: "route" | "none" | "escalate" | "manual" | "on" | "off" | "fallback";
	model?: string;
	modelName?: string;
	band?: Difficulty;
	difficulty?: Difficulty;
	/** Short reason in English, for logs. */
	reason: string;
	/**
	 * The same as codes, which the app words in the user's language: the class reasons (see [classify]), and floor,
	 * vision, below, cheapest for a route; error, cut-off, resent, rejected for an escalation; vision, tools, context,
	 * price (what no model offered) for "none".
	 */
	why?: ReasonCode[];
	estimate?: number | null;
}

export interface ChatRouting {
	version: 1;
	auto: boolean;
	floor: Difficulty;
	/** What the last routed turn used and was asked, for escalation. */
	last?: { model: string; band: Difficulty; text: string };
	log: Decision[];
}

const LOG_KEPT = 300;

/** Routing state per chat: `<dir>/<session id>.json`. A broken file is a chat without routing, never an error. */
export class RoutingStore {
	constructor(private readonly dir: string) {}

	private file(sessionId: string) {
		return join(this.dir, `${sessionId.replace(/[^\w.-]/g, "_")}.json`);
	}

	get(sessionId: string): ChatRouting {
		try {
			const f = this.file(sessionId);
			if (existsSync(f)) {
				const v = JSON.parse(readFileSync(f, "utf8"));
				if (v?.version === 1 && Array.isArray(v.log)) return { auto: v.auto === true, floor: clampBand(v.floor), log: v.log, version: 1, ...(v.last && { last: v.last }) };
			}
		} catch {
			// Unreadable: as if routing was never used here.
		}
		return { version: 1, auto: false, floor: 0, log: [] };
	}

	save(sessionId: string, r: ChatRouting) {
		mkdirSync(this.dir, { recursive: true });
		atomicWrite(this.file(sessionId), JSON.stringify({ ...r, log: r.log.slice(-LOG_KEPT) }));
	}

	update(sessionId: string, fn: (r: ChatRouting) => void): ChatRouting {
		const r = this.get(sessionId);
		fn(r);
		this.save(sessionId, r);
		return r;
	}
}

function clampBand(v: unknown): Difficulty {
	return v === 1 || v === 2 ? v : 0;
}
