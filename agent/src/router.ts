/**
 * GripHub Router account data: balance, real credits charged, live rates,
 * per-request floors, and the model catalog.
 *
 * Sources (all with the user's own GripHub key):
 *   GET /api/user-usage[?since=ISO]        account, usage per model, rates (with promos), model status
 *   GET /api/user-usage/requests?limit&afterId  one row per request: creditsCharged, floor, tokens
 *   GET /v1/credits                         fallback for balance and credits per model
 *   GET /v1/models                          model ids and capabilities (fetchModels in providers.ts)
 *
 * The /api/user-usage endpoints belong to the router's portal, not its
 * documented /v1 API, so every field is read defensively and a failure falls
 * back to /v1/credits and then to the last cached value; the app never shows
 * 0 as if it were real.
 *
 * Privacy: only billing fields are kept. Email, name, picture, payment
 * notifications, transaction ids and key names are dropped on read and never
 * cached, logged, or handed to the agent's context.
 *
 * Billing rule, verified against creditsCharged on real requests:
 *   charged = max(floor, rate × (input + output) / 1M) for successful requests;
 *   failed requests are not charged. The router's inputTokens already include
 *   cache reads and writes (all at the full rate); pi reports those apart, so
 *   local estimates add them back. Image models are priced per image.
 */

import { existsSync, readFileSync, writeFileSync } from "node:fs";

export const ROUTER_ORIGIN = "https://griphubrouter.web.id";

/** One model's price. `perImage` models charge `credits` per image instead of per token. */
export interface Rate {
	credits: number;
	/** Normal price while a promo runs. */
	list?: number;
	promo?: string;
	promoEndsAt?: string;
	perImage?: boolean;
	type?: string;
	name?: string;
}

export interface CreditBatch {
	credits: number;
	expiresAt: string | null;
	status?: string;
}

export interface ModelUsage {
	model: string;
	requests: number;
	inputTokens: number;
	outputTokens: number;
	cacheReadTokens: number;
	cacheWriteTokens: number;
	images: number;
	credits: number;
}

export interface Account {
	balance: number;
	granted: number;
	used: number;
	suspended: boolean;
	suspendedUntil: string | null;
	/** Active batches, soonest expiry first. */
	batches: CreditBatch[];
	byModel: ModelUsage[];
	discountRate: number;
	/** "user-usage" when the full data came through, "credits" when only /v1/credits did. */
	source: "user-usage" | "credits";
	fetchedAt: number;
}

export interface RouterRequest {
	id: number;
	model: string;
	endpoint: string;
	type: string;
	ok: boolean;
	error: string | null;
	at: number;
	inputTokens: number;
	cacheReadTokens: number;
	cacheWriteTokens: number;
	outputTokens: number;
	reasoningTokens: number;
	credits: number | null;
	/** The minimum this request was raised to, when the floor applied. */
	floor: number | null;
	tokenCredits: number | null;
	thinkingEffort: string | null;
	latencyMs: number | null;
	rateMultiplier: number | null;
}

/** What the host keeps between runs (router-cache.json): no personal data. */
export interface RouterCache {
	version: 1;
	account?: Account;
	rates?: Record<string, Rate>;
	ratesAt?: number;
	modelStatus?: Record<string, boolean>;
	/** Learned per-request minimums, by model (from requests that hit the floor). */
	floors: Record<string, number>;
	/** Newest request id seen, for afterId paging. */
	lastRequestId?: number;
	/** Recent requests, newest first, capped. */
	requests: RouterRequest[];
	/** Credits charged per WIB day, from requests seen (YYYY-MM-DD -> credits). */
	daily: Record<string, number>;
	today?: { day: string; credits: number; requests: number; fetchedAt: number };
}

/** Floors measured on 2026-10-27 (one "halo" per model); learned values override them. */
export const SEED_FLOORS: Record<string, number> = {
	"claude-fable-5": 0.1,
	"claude-fable-5.1": 0.1,
	"claude-opus-4.5": 0.1,
	"claude-opus-4.6": 0.1,
	"claude-opus-4.7": 0.1,
	"claude-opus-4.8": 0.1,
	"claude-opus-5": 0.1,
	"claude-opus-5.5": 0.1,
	"claude-sonnet-4.6": 0.1,
	"claude-sonnet-5": 0.1,
	"claude-sonnet-5.5": 0.1,
	"gpt-6.1-sol-ultrafast": 0.1,
	"gpt-5.6-sol": 0.05,
	"gpt-5.6-terra": 0.05,
	"gpt-6-sol": 0.05,
	"gpt-6.1-sol": 0.05,
	"gpt-6.1-terra": 0.05,
	"muse-wonder-1.0": 0.05,
	"claude-haiku-4.5": 0.01,
	"claude-haiku-5.5": 0.01,
	"deepseek-v4-flash": 0.01,
	"deepseek-v4-pro": 0.01,
	"deepseek-v4.1-flash": 0.01,
	"deepseek-v4.1-flash-sg": 0.01,
	"gemini-3.1-pro": 0.01,
	"gemini-3.8-flash": 0.01,
	"gemini-4-argon": 0.01,
	"glm-5.2": 0.01,
	"glm-5.3": 0.01,
	"glm-5.3-flash": 0.01,
	"glm-5.3-flashx": 0.01,
	"gpt-5.6-luna": 0.01,
	"gpt-6-luna": 0.01,
	"grok-4.6": 0.01,
	"grok-4.7": 0.01,
	hy3: 0.01,
	hy4: 0.01,
	"kimi-k2.6": 0.01,
	"kimi-k2.7": 0.01,
	"kimi-k3": 0.01,
	"kimi-k3.1-pro": 0.01,
	"mimo-v2.6-flash": 0.01,
	"minimax-m2.7": 0.01,
	"minimax-m3": 0.01,
};

const REQUESTS_KEPT = 300;
const DAYS_KEPT = 60;

// ---------------------------------------------------------------------------
// Parsing (pure; tested against fixtures in agent/test)

const num = (v: unknown, fallback = 0) => (typeof v === "number" && Number.isFinite(v) ? v : fallback);
const numOrNull = (v: unknown) => (typeof v === "number" && Number.isFinite(v) ? v : null);
const str = (v: unknown) => (typeof v === "string" && v ? v : undefined);
const list = (v: unknown): any[] => (Array.isArray(v) ? v : []);

/** Calendar day (YYYY-MM-DD) in Asia/Jakarta. */
export function wibDayOf(ts: number): string {
	return new Date(ts + 7 * 3600_000).toISOString().slice(0, 10);
}

/** The instant a WIB day starts, as an ISO string (for ?since=). */
export function wibDayStart(ts: number): string {
	return new Date(Date.parse(`${wibDayOf(ts)}T00:00:00Z`) - 7 * 3600_000).toISOString();
}

export function parseRates(body: any): Record<string, Rate> {
	const out: Record<string, Rate> = {};
	for (const r of list(body?.pricing?.rates)) {
		const id = str(r?.target);
		const credits = numOrNull(r?.creditsPerMillion);
		if (!id || credits === null) continue;
		const rate: Rate = { credits };
		const listPrice = numOrNull(r.listCreditsPerMillion);
		if (listPrice !== null && listPrice !== credits) rate.list = listPrice;
		if (str(r.promoName)) rate.promo = r.promoName;
		if (str(r.promoEndsAt)) rate.promoEndsAt = r.promoEndsAt;
		if (r.unit === "image" || r.targetType === "image") rate.perImage = true;
		if (str(r.targetType)) rate.type = r.targetType;
		if (str(r.displayName)) rate.name = r.displayName;
		out[id] = rate;
	}
	return out;
}

function parseByModel(items: unknown): ModelUsage[] {
	return list(items)
		.filter((m) => str(m?.model))
		.map((m) => ({
			model: m.model,
			requests: num(m.requests),
			inputTokens: num(m.inputTokens),
			outputTokens: num(m.outputTokens),
			cacheReadTokens: num(m.cacheReadTokens),
			cacheWriteTokens: num(m.cacheCreationTokens),
			images: num(m.images),
			credits: num(m.creditsUsed),
		}))
		.sort((a, b) => b.credits - a.credits);
}

/** /api/user-usage -> billing data only. Throws when it is not the expected shape. */
export function parseUserUsage(body: any, now = Date.now()) {
	const account = body?.account;
	if (!account || typeof account !== "object" || numOrNull(account.creditsBalance) === null) {
		throw new Error("Unexpected /api/user-usage response");
	}
	const quota = body.quota ?? {};
	const batches: CreditBatch[] = list(account.creditBatches)
		.filter((b) => b?.status === undefined || b.status === "active")
		.map((b) => ({ credits: num(b.credits), expiresAt: str(b.expiresAt) ?? null, status: str(b.status) }))
		.sort((a, b) => (a.expiresAt ?? "9").localeCompare(b.expiresAt ?? "9"));
	const suspension = account.policySuspension;
	const parsed: Account = {
		balance: num(quota.remaining, num(account.creditsBalance)),
		granted: num(quota.limit, num(account.creditsGranted)),
		used: num(quota.used, num(account.creditsUsed)),
		suspended: !!suspension,
		suspendedUntil: str(suspension?.until) ?? str(suspension?.suspendedUntil) ?? null,
		batches,
		byModel: parseByModel(body.usageByModel),
		discountRate: num(body.loyalty?.discountRate ?? body.loyalty?.tier?.discountRate),
		source: "user-usage",
		fetchedAt: now,
	};
	const status: Record<string, boolean> = {};
	if (body.modelStatus && typeof body.modelStatus === "object") {
		for (const [k, v] of Object.entries(body.modelStatus)) if (typeof v === "boolean") status[k] = v;
	}
	return {
		account: parsed,
		rates: parseRates(body),
		modelStatus: status,
		totals: { requests: num(body.usage?.requests), credits: parsed.byModel.reduce((s, m) => s + m.credits, 0) },
	};
}

/** /v1/credits -> the subset of Account it carries. */
export function parseCredits(body: any, now = Date.now()): Account {
	const b = body?.balance;
	if (!b || numOrNull(b.remaining) === null) throw new Error("Unexpected /v1/credits response");
	const account = body.account ?? {};
	return {
		balance: num(b.remaining),
		granted: num(b.limit, num(account.creditsGranted)),
		used: num(b.used, num(account.creditsUsed)),
		suspended: account.suspended === true,
		suspendedUntil: str(account.suspendedUntil) ?? null,
		batches: list(account.batches)
			.map((x) => ({ credits: num(x.credits), expiresAt: str(x.expiresAt) ?? null }))
			.sort((a, b) => (a.expiresAt ?? "9").localeCompare(b.expiresAt ?? "9")),
		byModel: parseByModel(body.byModel),
		discountRate: 0,
		source: "credits",
		fetchedAt: now,
	};
}

export function parseRequests(body: any): RouterRequest[] {
	return list(body?.items)
		.filter((x) => typeof x?.id === "number" && str(x.model))
		.map((x) => {
			const at = Date.parse(x.timestamp);
			const floor = x.floor && typeof x.floor === "object" ? x.floor : null;
			return {
				id: x.id,
				model: x.model,
				endpoint: str(x.endpoint) ?? "",
				type: str(x.type) ?? "",
				ok: x.status === "success",
				error: str(x.errorMessage) ?? null,
				at: Number.isFinite(at) ? at : 0,
				inputTokens: num(x.inputTokens),
				cacheReadTokens: num(x.cacheTokens),
				cacheWriteTokens: num(x.cacheCreationTokens),
				outputTokens: num(x.outputTokens),
				reasoningTokens: num(x.reasoningTokens),
				credits: numOrNull(x.creditsCharged),
				floor: floor ? numOrNull(floor.minimum) : null,
				tokenCredits: floor ? numOrNull(floor.tokenCredits) : null,
				thinkingEffort: str(x.thinkingEffort) ?? null,
				latencyMs: numOrNull(x.latency),
				rateMultiplier: numOrNull(x.rateMultiplier),
			};
		});
}

// ---------------------------------------------------------------------------
// Pricing (pure)

export interface Usage {
	input: number;
	output: number;
	cacheRead?: number;
	cacheWrite?: number;
}

/**
 * Credits one request costs, the router's way: max(floor, rate × tokens),
 * where tokens include cache reads and writes. Null when the rate is unknown.
 * [ok] false (a failed request) costs nothing.
 */
export function requestCredits(
	rate: Rate | undefined,
	floor: number | undefined,
	u: Usage,
	opts: { ok?: boolean; multiplier?: number; discount?: number } = {},
): number | null {
	if (opts.ok === false) return 0;
	if (!rate) return null;
	if (rate.perImage) return rate.credits;
	const tokens = u.input + u.output + (u.cacheRead ?? 0) + (u.cacheWrite ?? 0);
	const tokenCredits = (rate.credits * (opts.multiplier ?? 1) * tokens) / 1_000_000;
	const charged = Math.max(floor ?? 0, tokenCredits);
	return charged * (1 - (opts.discount ?? 0));
}

/** Rate lookup that tolerates router aliases ("claude-sonnet-5-alt") and separators. */
export function lookup<T>(table: Record<string, T> | undefined, model: string): T | undefined {
	if (!table) return undefined;
	if (table[model] !== undefined) return table[model];
	const norm = (s: string) => s.trim().toLowerCase().replace(/[.\-_]/g, "");
	const want = norm(model);
	const base = norm(model.replace(/-alt$/, ""));
	for (const [k, v] of Object.entries(table)) {
		const n = norm(k);
		if (n === want || n === base) return v;
	}
	return undefined;
}

// ---------------------------------------------------------------------------
// Client with cache

export interface RouterOptions {
	key: () => string;
	cacheFile: string;
	fetch?: typeof fetch;
	now?: () => number;
	/** Fallback rates (the built-in table) for when the live ones never loaded. */
	fallbackRates: Record<string, Rate>;
}

export class Router {
	private cache: RouterCache;
	private inflight = new Map<string, Promise<unknown>>();
	private backoffUntil = 0;
	private readonly opts: RouterOptions;

	constructor(opts: RouterOptions) {
		this.opts = opts;
		this.cache = this.load();
	}

	private now() {
		return this.opts.now?.() ?? Date.now();
	}

	private load(): RouterCache {
		try {
			if (existsSync(this.opts.cacheFile)) {
				const c = JSON.parse(readFileSync(this.opts.cacheFile, "utf8"));
				if (c?.version === 1) return { floors: {}, requests: [], daily: {}, ...c };
			}
		} catch {
			// A broken cache is just an empty one.
		}
		return { version: 1, floors: {}, requests: [], daily: {} };
	}

	private save() {
		try {
			writeFileSync(this.opts.cacheFile, JSON.stringify(this.cache));
		} catch {
			// Cache is an optimisation; the next fetch rebuilds it.
		}
	}

	/** Rates in effect: live when loaded, else the built-in table. */
	rates(): Record<string, Rate> {
		return this.cache.rates && Object.keys(this.cache.rates).length ? this.cache.rates : this.opts.fallbackRates;
	}

	rate(model: string): Rate | undefined {
		return lookup(this.rates(), model);
	}

	floor(model: string): number | undefined {
		return lookup(this.cache.floors, model) ?? lookup(SEED_FLOORS, model);
	}

	discount(): number {
		return this.cache.account?.discountRate ?? 0;
	}

	modelAvailable(model: string): boolean {
		return lookup(this.cache.modelStatus, model) !== false;
	}

	/** Estimated credits of one request by the router's rule. */
	estimate(model: string, u: Usage, ok = true): number | null {
		return requestCredits(this.rate(model), this.floor(model), u, { ok, discount: this.discount() });
	}

	snapshot() {
		const c = this.cache;
		return {
			account: c.account ?? null,
			today: c.today ?? null,
			daily: c.daily,
			requests: c.requests.slice(0, 50),
			rates: this.rates(),
			ratesLive: !!c.rates,
			ratesAt: c.ratesAt ?? null,
			floors: { ...SEED_FLOORS, ...c.floors },
			modelStatus: c.modelStatus ?? {},
		};
	}

	private async get(path: string): Promise<any> {
		const key = this.opts.key();
		if (!key) throw new Error("No GripHub key saved");
		if (this.now() < this.backoffUntil) throw new Error("GripHub Router is rate limiting; try again shortly");
		const f = this.opts.fetch ?? fetch;
		const res = await f(`${ROUTER_ORIGIN}${path}`, {
			headers: { Authorization: `Bearer ${key}`, Accept: "application/json", "User-Agent": "GripHubAgent" },
			signal: AbortSignal.timeout(30_000),
		});
		if (res.status === 429) this.backoffUntil = this.now() + 60_000;
		const text = await res.text();
		let body: any = null;
		try {
			body = JSON.parse(text);
		} catch {
			// Reported below.
		}
		if (!res.ok) {
			const msg = body?.error?.message ?? body?.error ?? res.statusText;
			throw Object.assign(new Error(`GripHub Router: ${msg} (${res.status})`), { status: res.status });
		}
		if (body === null) throw new Error("GripHub Router returned no JSON");
		return body;
	}

	/** One request at a time per path: parallel callers share it. */
	private once<T>(id: string, run: () => Promise<T>): Promise<T> {
		const running = this.inflight.get(id) as Promise<T> | undefined;
		if (running) return running;
		const p = run().finally(() => this.inflight.delete(id));
		this.inflight.set(id, p);
		return p;
	}

	/**
	 * Account, rates and status. Falls back to /v1/credits for the balance when
	 * the portal endpoint fails; keeps the last rates in that case.
	 * [maxAgeMs] reuses a fresh cached account instead of calling again.
	 */
	refreshAccount(maxAgeMs = 0): Promise<Account> {
		const cached = this.cache.account;
		if (cached && this.now() - cached.fetchedAt < maxAgeMs) return Promise.resolve(cached);
		return this.once("account", async () => {
			try {
				const parsed = parseUserUsage(await this.get("/api/user-usage"), this.now());
				this.cache.account = parsed.account;
				if (Object.keys(parsed.rates).length) {
					this.cache.rates = parsed.rates;
					this.cache.ratesAt = this.now();
				}
				this.cache.modelStatus = parsed.modelStatus;
			} catch (e) {
				if ((e as any)?.status === 401) throw e;
				this.cache.account = parseCredits(await this.get("/v1/credits"), this.now());
			}
			this.save();
			return this.cache.account!;
		});
	}

	/** Credits charged today (WIB), from the router itself. */
	refreshToday(maxAgeMs = 0): Promise<{ day: string; credits: number; requests: number; fetchedAt: number }> {
		const day = wibDayOf(this.now());
		const cached = this.cache.today;
		if (cached && cached.day === day && this.now() - cached.fetchedAt < maxAgeMs) return Promise.resolve(cached);
		return this.once("today", async () => {
			const body = await this.get(`/api/user-usage?since=${encodeURIComponent(wibDayStart(this.now()))}`);
			const parsed = parseUserUsage(body, this.now());
			this.cache.today = { day, credits: parsed.totals.credits, requests: parsed.totals.requests, fetchedAt: this.now() };
			this.cache.daily[day] = parsed.totals.credits;
			this.save();
			return this.cache.today;
		});
	}

	/**
	 * New requests since the last one seen (afterId paging), newest first.
	 * Learns floors from them and adds their credits to the per-day totals.
	 */
	refreshRequests(): Promise<RouterRequest[]> {
		return this.once("requests", async () => {
			const after = this.cache.lastRequestId;
			const q = new URLSearchParams({ limit: after ? "200" : "100" });
			if (after) q.set("afterId", String(after));
			const fresh = parseRequests(await this.get(`/api/user-usage/requests?${q}`)).filter(
				(r) => !after || r.id > after,
			);
			this.absorb(fresh);
			return fresh;
		});
	}

	/** Folds requests into the cache (exported for tests). */
	absorb(fresh: RouterRequest[]) {
		if (!fresh.length) return;
		const known = new Set(this.cache.requests.map((r) => r.id));
		const added = fresh.filter((r) => !known.has(r.id));
		for (const r of added) {
			if (r.floor !== null && r.floor > 0) this.cache.floors[r.model] = r.floor;
			// Days of a first page are partial; the since= total replaces today's below.
			if (r.ok && r.credits !== null && this.cache.lastRequestId !== undefined) {
				const d = wibDayOf(r.at);
				this.cache.daily[d] = (this.cache.daily[d] ?? 0) + r.credits;
			}
		}
		this.cache.requests = [...added, ...this.cache.requests].sort((a, b) => b.id - a.id).slice(0, REQUESTS_KEPT);
		this.cache.lastRequestId = Math.max(this.cache.lastRequestId ?? 0, ...fresh.map((r) => r.id));
		const days = Object.keys(this.cache.daily).sort();
		for (const d of days.slice(0, Math.max(0, days.length - DAYS_KEPT))) delete this.cache.daily[d];
		this.save();
	}

	/** The cached account, without a network call. */
	account(): Account | undefined {
		return this.cache.account;
	}

	today() {
		return this.cache.today && this.cache.today.day === wibDayOf(this.now()) ? this.cache.today : undefined;
	}
}
