/**
 * GripHub Router model board: which models people use, and which are working now.
 *
 *   GET /api/public/model-rank?period=today|24h|7d|14d|30d|all   no key; usage per model
 *   GET /api/portal/model-status?window=6h|24h|7d                 the user's own GripHub key; health per model
 *
 * Both are the router's portal endpoints, not its documented /v1 API, so every field is read defensively and a
 * failure falls back to the last good copy (marked stale) rather than to zeros.
 *
 * Checked against the live router: it answers 200 for a window or period it does not know and quietly serves 24h
 * (status) or today (rank) instead, echoing what it really served. Only the values below are ever asked for, and an
 * answer that echoes another one is refused: a "7d" label on 24h numbers would be a lie.
 *
 * Nothing personal is in either response, and nothing of the user is sent. Status is cut down for the phone:
 * a model's bars become [ok, fail, level] triples (about a third of the bytes of the router's objects).
 */

import { existsSync, readFileSync } from "node:fs";
import { atomicWrite } from "./state.js";
import { ROUTER_ORIGIN } from "./router.js";

export const RANK_PERIODS = ["today", "24h", "7d", "14d", "30d", "all"] as const;
export const STATUS_WINDOWS = ["6h", "24h", "7d"] as const;
export type RankPeriod = (typeof RANK_PERIODS)[number];
export type StatusWindow = (typeof STATUS_WINDOWS)[number];

/** Bar levels, as the router names them, in the order the phone reads them (0 = nothing happened). */
const LEVELS = ["none", "ok", "partial", "down"] as const;
const STATES = ["up", "degraded", "down", "quiet"] as const;

export interface RankRow {
	model: string;
	/** The router's display name; null for models it does not name (image models). */
	name: string | null;
	requests: number;
	tokens: number;
	inputTokens: number;
	outputTokens: number;
	cacheReadTokens: number;
	images: number;
	imageRequests: number;
	lastUsedAt: string | null;
}

export interface RankBoard {
	period: RankPeriod;
	/** In the router's order (most tokens first). */
	rows: RankRow[];
}

export interface StatusError {
	category: string;
	count: number;
	lastAt: string | null;
}

export interface StatusModel {
	model: string;
	name: string;
	/** up, degraded, down, or quiet (too little traffic to judge); "unknown" for a state this app does not know. */
	state: (typeof STATES)[number] | "unknown";
	active: boolean;
	lastSeenAt: string | null;
	requests: number;
	successRate: number | null;
	/** Success over the latest bars only; null when there was none. */
	recentSuccessRate: number | null;
	latencyP50Ms: number | null;
	latencyP95Ms: number | null;
	ttftP50Ms: number | null;
	ttftP95Ms: number | null;
	tokensPerSecond: number | null;
	emptyResponses: number;
	errors: StatusError[];
	/** Start of the first bar (ISO); each bar is [ok, fail, level] and lasts `barMs`. Level: 0 none, 1 ok, 2 partial, 3 down. */
	barsFrom: string | null;
	bars: [number, number, number][];
}

export interface StatusBoard {
	window: StatusWindow;
	barMs: number;
	generatedAt: string | null;
	trackingSince: string | null;
	totals: { requests: number; ok: number; fail: number; successRate: number | null };
	summary: { models: number; active: number; up: number; degraded: number; down: number };
	errorCategories: { category: string; count: number }[];
	models: StatusModel[];
}

const num = (v: unknown): number | null => (typeof v === "number" && Number.isFinite(v) ? v : null);
const int = (v: unknown): number => Math.max(0, Math.round(num(v) ?? 0));
const str = (v: unknown): string | null => (typeof v === "string" && v ? v : null);
const arr = (v: unknown): any[] => (Array.isArray(v) ? v : []);
const isObj = (v: unknown): v is Record<string, any> => !!v && typeof v === "object" && !Array.isArray(v);

/** /api/public/model-rank. Throws when it is not the expected shape, or answers a period that was not asked for. */
export function parseRank(body: unknown, asked: RankPeriod): RankBoard {
	if (!isObj(body) || !Array.isArray(body.rows)) throw new Error("Unexpected model-rank response");
	if (body.period !== asked) throw new Error(`model-rank answered ${String(body.period)} instead of ${asked}`);
	const names = isObj(body.displayNames) ? body.displayNames : {};
	const rows: RankRow[] = [];
	for (const r of body.rows) {
		const model = isObj(r) ? str(r.model) : null;
		if (!model) continue;
		rows.push({
			model,
			name: str(names[model]),
			requests: int(r.requests),
			tokens: int(r.totalTokens),
			inputTokens: int(r.inputTokens),
			outputTokens: int(r.outputTokens),
			cacheReadTokens: int(r.cacheReadTokens),
			images: int(r.images),
			imageRequests: int(r.imageRequests),
			lastUsedAt: str(r.lastUsedAt),
		});
	}
	return { period: asked, rows };
}

/** /api/portal/model-status. Throws when it is not the expected shape, or answers a window that was not asked for. */
export function parseStatus(body: unknown, asked: StatusWindow): StatusBoard {
	if (!isObj(body) || !Array.isArray(body.models)) throw new Error("Unexpected model-status response");
	if (body.window !== asked) throw new Error(`model-status answered ${String(body.window)} instead of ${asked}`);
	const barMs = int(body.barMs);
	if (barMs <= 0) throw new Error("model-status has no bar length");
	const models: StatusModel[] = [];
	for (const m of body.models) {
		const id = isObj(m) ? str(m.model) : null;
		if (!id) continue;
		const bars: [number, number, number][] = arr(m.bars).map((b) => [
			int(b?.ok),
			int(b?.fail),
			Math.max(0, LEVELS.indexOf(b?.level)),
		]);
		models.push({
			model: id,
			name: str(m.name) ?? id,
			state: (STATES as readonly string[]).includes(m.state) ? m.state : "unknown",
			active: m.active === true,
			lastSeenAt: str(m.lastSeenAt),
			requests: int(m.requests),
			successRate: num(m.successRate),
			recentSuccessRate: num(m.recentSuccessRate),
			latencyP50Ms: num(m.latencyP50Ms),
			latencyP95Ms: num(m.latencyP95Ms),
			ttftP50Ms: num(m.ttftP50Ms),
			ttftP95Ms: num(m.ttftP95Ms),
			tokensPerSecond: num(m.tokensPerSecond),
			emptyResponses: int(m.emptyResponses),
			errors: arr(m.errors)
				.filter((e) => isObj(e) && str(e.category))
				.map((e) => ({ category: e.category, count: int(e.count), lastAt: str(e.lastAt) })),
			barsFrom: bars.length ? str(m.bars[0]?.at) : null,
			bars,
		});
	}
	const t = isObj(body.totals) ? body.totals : {};
	const s = isObj(body.summary) ? body.summary : {};
	return {
		window: asked,
		barMs,
		generatedAt: str(body.generatedAt),
		trackingSince: str(body.trackingSince),
		totals: { requests: int(t.requests), ok: int(t.ok), fail: int(t.fail), successRate: num(t.successRate) },
		summary: { models: int(s.models), active: int(s.active), up: int(s.up), degraded: int(s.degraded), down: int(s.down) },
		errorCategories: arr(body.errorCategories)
			.filter((e) => isObj(e) && str(e.category))
			.map((e) => ({ category: e.category, count: int(e.count) })),
		models,
	};
}

// ---------------------------------------------------------------------------
// Client with cache

/** What the phone gets: the board, when it was fetched, and whether it is an old copy because the router failed. */
export interface Served<T> {
	board: T;
	fetchedAt: number;
	stale: boolean;
	/** Why the copy is stale. */
	error?: string;
}

interface Cached<T> {
	board: T;
	fetchedAt: number;
}

interface BoardCache {
	version: 1;
	rank: Partial<Record<RankPeriod, Cached<RankBoard>>>;
	status: Partial<Record<StatusWindow, Cached<StatusBoard>>>;
}

export interface ModelBoardOptions {
	/** The saved GripHub key ("" when there is none). Only the status call uses it. */
	key: () => string;
	cacheFile: string;
	fetch?: typeof fetch;
	now?: () => number;
}

/** A refresh is never sooner than this after the last one, even when forced: the screen's pull cannot hammer the router. */
export const MIN_REFETCH_MS = 10_000;
export const RANK_TTL_MS = 5 * 60_000;
export const STATUS_TTL_MS = 60_000;

export class ModelBoard {
	private cache: BoardCache;
	private inflight = new Map<string, Promise<unknown>>();
	private backoffUntil = 0;

	constructor(private readonly opts: ModelBoardOptions) {
		this.cache = this.load();
	}

	private now() {
		return this.opts.now?.() ?? Date.now();
	}

	private load(): BoardCache {
		try {
			if (existsSync(this.opts.cacheFile)) {
				const c = JSON.parse(readFileSync(this.opts.cacheFile, "utf8"));
				if (c?.version === 1) return { rank: {}, status: {}, ...c };
			}
		} catch {
			// A broken cache is just an empty one.
		}
		return { version: 1, rank: {}, status: {} };
	}

	private save() {
		try {
			atomicWrite(this.opts.cacheFile, JSON.stringify(this.cache));
		} catch {
			// An optimisation only.
		}
	}

	private async get(path: string, withKey: boolean): Promise<unknown> {
		if (this.now() < this.backoffUntil) throw new Error("GripHub Router is rate limiting; try again shortly");
		const headers: Record<string, string> = { Accept: "application/json", "User-Agent": "GripHubAgent" };
		if (withKey) {
			const key = this.opts.key();
			if (!key) throw new Error("No GripHub key saved");
			headers.Authorization = `Bearer ${key}`;
		}
		const res = await (this.opts.fetch ?? fetch)(`${ROUTER_ORIGIN}${path}`, { headers, signal: AbortSignal.timeout(30_000) });
		if (res.status === 429) this.backoffUntil = this.now() + 60_000;
		const text = await res.text();
		let body: unknown = null;
		try {
			body = JSON.parse(text);
		} catch {
			// Reported below.
		}
		if (!res.ok) {
			const e = (body as any)?.error;
			throw Object.assign(new Error(`GripHub Router: ${e?.message ?? e ?? res.statusText} (${res.status})`), { status: res.status });
		}
		if (body === null) throw new Error("GripHub Router returned no JSON");
		return body;
	}

	private once<T>(id: string, run: () => Promise<T>): Promise<T> {
		const running = this.inflight.get(id) as Promise<T> | undefined;
		if (running) return running;
		const p = run().finally(() => this.inflight.delete(id));
		this.inflight.set(id, p);
		return p;
	}

	/** One board: the cached copy while it is fresh, else the router's, else the old copy marked stale. */
	private async serve<K extends string, T>(
		kind: "rank" | "status",
		slot: Partial<Record<K, Cached<T>>>,
		k: K,
		ttl: number,
		force: boolean,
		fetchOne: () => Promise<T>,
	): Promise<Served<T>> {
		const have = slot[k];
		const age = have ? this.now() - have.fetchedAt : Infinity;
		if (have && age < (force ? MIN_REFETCH_MS : ttl)) return { board: have.board, fetchedAt: have.fetchedAt, stale: false };
		return this.once(`${kind}:${k}`, async () => {
			try {
				const board = await fetchOne();
				slot[k] = { board, fetchedAt: this.now() };
				this.save();
				return { board, fetchedAt: this.now(), stale: false };
			} catch (e) {
				// A key problem is the user's to fix: an old copy would hide it.
				if ((e as any)?.status === 401 || (e as Error).message === "No GripHub key saved" || !have) throw e;
				return { board: have.board, fetchedAt: have.fetchedAt, stale: true, error: (e as Error).message };
			}
		});
	}

	rank(period: RankPeriod, force = false): Promise<Served<RankBoard>> {
		if (!(RANK_PERIODS as readonly string[]).includes(period)) throw new Error(`Unknown period: ${period}`);
		return this.serve("rank", this.cache.rank, period, RANK_TTL_MS, force, async () =>
			parseRank(await this.get(`/api/public/model-rank?period=${period}`, false), period),
		);
	}

	status(window: StatusWindow, force = false): Promise<Served<StatusBoard>> {
		if (!(STATUS_WINDOWS as readonly string[]).includes(window)) throw new Error(`Unknown window: ${window}`);
		return this.serve("status", this.cache.status, window, STATUS_TTL_MS, force, async () =>
			parseStatus(await this.get(`/api/portal/model-status?window=${window}`, true), window),
		);
	}
}
