/**
 * web_search, web_fetch and web_screenshot tools, so the agent can look up install steps,
 * docs and error messages instead of guessing.
 *
 * Search works without a key (DuckDuckGo, DuckDuckGo Lite, then Brave, scraped
 * from their HTML pages). Search1API, TinyFish, Brave Search or Tavily keys, when configured, are used first;
 * each service can have several keys, used in turn (keyring.ts). Search1API can also read pages
 * (crawl) and take screenshots.
 */

import { existsSync, mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { Type } from "typebox";
import { KeyError, withKeys } from "./keyring.js";

const UA =
	"Mozilla/5.0 (Linux; Android 15; Mobile) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0 Mobile Safari/537.36";

export interface SearchResult {
	title: string;
	url: string;
	snippet: string;
}

export interface SearchKeys {
	brave: string[];
	tavily: string[];
	s1: string[];
	tinyfish: string[];
	/** Which Search1API features to use when it has keys. */
	s1Search: boolean;
	s1Crawl: boolean;
	s1Screenshot: boolean;
	/** Whether the agent uses TinyFish Search when it has keys. */
	tinyfishSearch: boolean;
	/** GripHub Router search: OpenAI Responses + Anthropic Messages, both with a server-side web_search tool. */
	openaiSearch: boolean;
	anthropicSearch: boolean;
	/** Dedicated search models for the router backends (defaults filled in by the host). */
	openaiSearchModel?: string;
	anthropicSearchModel?: string;
	/** Per-project web_search toggle, keyed by project path; absent means on. */
	projectSearch?: Record<string, boolean>;
	/** Per-backend switches for the keyed search tools (Search1API already had one). */
	braveSearch: boolean;
	tavilySearch: boolean;
	/** The conversation's active model slug + the saved GripHub key and base URL, merged in by the host (never settings of their own). */
	activeModel?: string;
	griphubKey?: string;
	griphubBaseUrl?: string;
}

// ---------------------------------------------------------------------------
// Search1API (https://s1.dev/docs)

const S1 = "https://api.search1api.com";
/** Statuses that mean the key can't serve this request; a screenshot's 403 is about the target, not the key. */
const s1KeyProblem = (status: number) => status === 401 || status === 402 || status === 429;

async function s1Request(path: string, key: string, body: unknown, signal?: AbortSignal) {
	// A stalled mobile connection must not hang the agent: a minute is plenty, even for a full-page screenshot.
	const timeout = AbortSignal.timeout(60_000);
	const res = await fetch(`${S1}${path}`, {
		method: "POST",
		headers: { Authorization: `Bearer ${key}`, "Content-Type": "application/json" },
		body: JSON.stringify(body),
		signal: signal ? AbortSignal.any([signal, timeout]) : timeout,
	});
	if (!res.ok) {
		const raw = await res.text().catch(() => "");
		let message = "";
		try {
			const json = JSON.parse(raw);
			message = json.message ?? json.error ?? json.detail ?? "";
		} catch {
			message = raw.slice(0, 200);
		}
		throw new KeyError(`Search1API ${res.status}${message ? `: ${message}` : ""}`, res.status);
	}
	return res;
}

/** Sources Search1API can search besides the default (Google). */
export const S1_SOURCES = [
	"google", "bing", "duckduckgo", "yahoo", "yandex", "x", "reddit", "github", "youtube", "arxiv",
	"wikipedia", "grokipedia", "imdb", "wechat", "bilibili", "baidu", "quark", "360", "bingcn",
];

async function s1Search(q: string, n: number, key: string, source: string | undefined, signal?: AbortSignal) {
	const res = await s1Request("/search", key, { query: q, max_results: n, ...(source ? { search_service: source } : {}) }, signal);
	const body = (await res.json()) as any;
	return (body.results ?? []).map((r: any) => ({
		title: r.title ?? "",
		url: r.link ?? "",
		snippet: [r.published_date, r.snippet].filter(Boolean).join(" · "),
	})) as SearchResult[];
}

/** Reads a page through Search1API's crawler (handles pages a plain fetch can't). */
export async function s1Crawl(url: string, keys: string[], signal?: AbortSignal) {
	return withKeys(
		"Search1API",
		keys,
		async (key) => {
			const body = (await (await s1Request("/crawl", key, { url }, signal)).json()) as any;
			const r = body.results ?? {};
			return { url: r.link ?? url, title: r.title ?? "", text: r.content ?? "" };
		},
		s1KeyProblem,
	);
}

export interface ScreenshotOptions {
	full_page?: boolean;
	selector?: string;
	color_scheme?: "light" | "dark";
	viewport?: { width: number; height: number };
}

/** A PNG of a public page, rendered by Search1API. */
export async function s1Screenshot(url: string, opts: ScreenshotOptions, keys: string[], signal?: AbortSignal) {
	return withKeys(
		"Search1API",
		keys,
		async (key) => {
			const res = await s1Request("/screenshot", key, { url, format: "png", ...opts }, signal);
			const type = res.headers.get("content-type") ?? "image/png";
			// An error page answered with 200 must not be saved and shown as an image.
			if (!type.startsWith("image/")) {
				const text = (await res.text().catch(() => "")).slice(0, 200);
				throw new Error(`Search1API returned no image${text ? `: ${text}` : ""}`);
			}
			return { bytes: Buffer.from(await res.arrayBuffer()), mimeType: type.split(";")[0] };
		},
		s1KeyProblem,
	);
}

/** Credits left on each key, for the settings screen. */
export async function s1Usage(keys: string[]) {
	return Promise.all(
		keys.map(async (key) => {
			try {
				const res = await fetch(`${S1}/usage`, {
					headers: { Authorization: `Bearer ${key}` },
					signal: AbortSignal.timeout(20_000),
				});
				// Known causes as codes the app words in the user's language.
				if (!res.ok) {
					const error = { 401: "invalid_key", 402: "no_credits", 429: "rate_limited" }[res.status] ?? `HTTP ${res.status}`;
					return { usage: null, error };
				}
				return { usage: Number(((await res.json()) as any).usage ?? 0), error: null };
			} catch (e) {
				return { usage: null, error: (e as Error).message };
			}
		}),
	);
}

// ---------------------------------------------------------------------------
// TinyFish Search (https://api.search.tinyfish.ai — GET, X-API-Key header)
//
// Returns { query, results: [{ position, site_name, title, snippet, url }],
// total_results }. No documented count parameter, so the caller slices to n
// client-side. Defensive like the other keyed engines: a missing or
// non-array results field is an empty list, not an error.

const TINYFISH_SEARCH = "https://api.search.tinyfish.ai";

async function tinyfishSearch(q: string, n: number, key: string, signal?: AbortSignal): Promise<SearchResult[]> {
	// A stalled mobile connection must not hang the agent: a minute is plenty.
	const timeout = AbortSignal.timeout(60_000);
	const res = await fetch(`${TINYFISH_SEARCH}?query=${encodeURIComponent(q)}`, {
		headers: { "X-API-Key": key },
		signal: signal ? AbortSignal.any([signal, timeout]) : timeout,
	});
	if (!res.ok) {
		const raw = await res.text().catch(() => "");
		let message = "";
		try {
			const json = JSON.parse(raw);
			message = json.message ?? json.error ?? json.detail ?? "";
		} catch {
			message = raw.slice(0, 200);
		}
		throw new KeyError(`TinyFish ${res.status}${message ? `: ${message}` : ""}`, res.status);
	}
	const body = (await res.json()) as any;
	const results = Array.isArray(body?.results) ? body.results : [];
	return results.slice(0, n).map((r: any) => ({
		title: r.title ?? "",
		url: r.url ?? "",
		snippet: r.snippet ?? "",
	})) as SearchResult[];
}

// ---------------------------------------------------------------------------
// Search backends

async function braveSearch(q: string, n: number, key: string, signal?: AbortSignal): Promise<SearchResult[]> {
	const res = await fetch(`https://api.search.brave.com/res/v1/web/search?q=${encodeURIComponent(q)}&count=${n}`, {
		headers: { Accept: "application/json", "X-Subscription-Token": key },
		signal,
	});
	if (!res.ok) throw new KeyError(`Brave ${res.status}`, res.status);
	const body = (await res.json()) as any;
	return (body.web?.results ?? []).map((r: any) => ({
		title: r.title,
		url: r.url,
		snippet: stripTags(r.description ?? ""),
	}));
}

async function tavilySearch(q: string, n: number, key: string, signal?: AbortSignal): Promise<SearchResult[]> {
	const res = await fetch("https://api.tavily.com/search", {
		method: "POST",
		headers: { "Content-Type": "application/json", Authorization: `Bearer ${key}` },
		body: JSON.stringify({ query: q, max_results: n }),
		signal,
	});
	if (!res.ok) throw new KeyError(`Tavily ${res.status}`, res.status);
	const body = (await res.json()) as any;
	return (body.results ?? []).map((r: any) => ({ title: r.title, url: r.url, snippet: r.content ?? "" }));
}

/**
 * DuckDuckGo answers a rate-limited client with HTTP 202 and a bot-check page.
 * That used to read as "no results", which a model takes as a cue to rephrase
 * and search again; saying "blocked" lets it stop instead.
 */
function duckBlocked(res: Response, html: string) {
	return res.status === 202 || html.includes("anomaly-modal");
}

async function duckSearch(q: string, n: number, signal?: AbortSignal): Promise<SearchResult[]> {
	const res = await fetch("https://html.duckduckgo.com/html/", {
		method: "POST",
		headers: { "User-Agent": UA, "Content-Type": "application/x-www-form-urlencoded" },
		body: `q=${encodeURIComponent(q)}&kl=wt-wt`,
		signal,
	});
	if (!res.ok) throw new Error(`DuckDuckGo ${res.status}`);
	const html = await res.text();
	if (duckBlocked(res, html)) throw new Error("DuckDuckGo blocked the request (bot check)");
	const out: SearchResult[] = [];
	const block = /<div class="result results_links[\s\S]*?(?=<div class="result results_links|<\/div>\s*<\/div>\s*<div id="links_wrapper"|$)/g;
	for (const m of html.matchAll(block)) {
		const a = m[0].match(/class="result__a"[^>]*href="([^"]+)"[^>]*>([\s\S]*?)<\/a>/);
		if (!a) continue;
		let url = decodeEntities(a[1]);
		const uddg = url.match(/[?&]uddg=([^&]+)/);
		if (uddg) url = decodeURIComponent(uddg[1]);
		if (url.startsWith("//")) url = `https:${url}`;
		if (/duckduckgo\.com\/y\.js/.test(url)) continue; // ads
		const s = m[0].match(/class="result__snippet"[^>]*>([\s\S]*?)<\/a>/);
		out.push({ title: stripTags(a[2]), url, snippet: stripTags(s?.[1] ?? "") });
		if (out.length >= n) break;
	}
	if (out.length === 0) throw new Error("DuckDuckGo returned no results");
	return out;
}

const DESKTOP_UA =
	"Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0 Safari/537.36";

async function duckLiteSearch(q: string, n: number, signal?: AbortSignal): Promise<SearchResult[]> {
	const res = await fetch("https://lite.duckduckgo.com/lite/", {
		method: "POST",
		headers: { "User-Agent": DESKTOP_UA, "Content-Type": "application/x-www-form-urlencoded" },
		body: `q=${encodeURIComponent(q)}`,
		signal,
	});
	if (!res.ok) throw new Error(`DuckDuckGo Lite ${res.status}`);
	const html = await res.text();
	if (duckBlocked(res, html)) throw new Error("DuckDuckGo Lite blocked the request (bot check)");
	const links = [...html.matchAll(/<a[^>]*href="([^"]+)"[^>]*class=['"]result-link['"][^>]*>([\s\S]*?)<\/a>/g)];
	const snippets = [...html.matchAll(/class=['"]result-snippet['"][^>]*>([\s\S]*?)<\/td>/g)];
	const out: SearchResult[] = [];
	links.forEach((m, i) => {
		let url = decodeEntities(m[1]);
		const uddg = url.match(/[?&]uddg=([^&]+)/);
		if (uddg) url = decodeURIComponent(uddg[1]);
		if (url.startsWith("//")) url = `https:${url}`;
		if (/duckduckgo\.com\/y\.js/.test(url) || out.length >= n) return;
		out.push({ title: stripTags(m[2]), url, snippet: stripTags(snippets[i]?.[1] ?? "") });
	});
	if (out.length === 0) throw new Error("DuckDuckGo Lite returned no results");
	return out;
}

async function braveHtmlSearch(q: string, n: number, signal?: AbortSignal): Promise<SearchResult[]> {
	const res = await fetch(`https://search.brave.com/search?q=${encodeURIComponent(q)}&source=web`, {
		headers: { "User-Agent": DESKTOP_UA, "Accept-Language": "en-US,en;q=0.8" },
		signal,
	});
	if (!res.ok) throw new Error(`Brave ${res.status}`);
	const html = await res.text();
	const out: SearchResult[] = [];
	for (const block of html.split('data-type="web"').slice(1)) {
		const url = block.match(/<a[^>]*href="(https?:\/\/[^"]+)"/)?.[1];
		const title = block.match(/class="title search-snippet-title[^"]*"[^>]*>([\s\S]*?)<\/div>/)?.[1];
		if (!url || !title) continue;
		const snippet = block.match(/class="content [^"]*"[^>]*>([\s\S]*?)<\/div>/)?.[1] ?? "";
		out.push({ title: stripTags(title), url: decodeEntities(url), snippet: stripTags(snippet).replace(/<!---->/g, "") });
		if (out.length >= n) break;
	}
	if (out.length === 0) throw new Error("Brave returned no results");
	return out;
}

// ---------------------------------------------------------------------------
// GripHub Router search (OpenAI Responses + Anthropic Messages)
//
// Both are model-driven: the request carries a server-side web_search tool and
// the model decides when to search. What comes back is citations (OpenAI) or
// tool-result blocks (Anthropic) — titles + URLs for sure, snippets only where
// the provider includes them. An empty snippet is fine: the agent follows up
// with web_fetch, exactly as it does for the other backends.
//
// A model call can take a while on a phone connection, but each backend is
// only one step of the fallback chain: two slow router calls used to hold one
// search for four minutes. Any failure (unsupported tool, unknown model, bad
// key, timeout) just falls through to the next backend in webSearch().

/** Reassemble a plain-JSON-shaped body from an SSE stream (Responses or Messages shape). Returns null when the stream carries nothing usable. */
function parseSseBody(raw: string, kind: "responses" | "messages"): any | null {
	const events: any[] = [];
	for (const line of raw.split("\n")) {
		const trimmed = line.trim();
		if (!trimmed.startsWith("data:")) continue;
		const payload = trimmed.slice(5).trim();
		if (!payload || payload === "[DONE]") continue;
		try {
			events.push(JSON.parse(payload));
		} catch { /* a partial line at the cut-off is not fatal */ }
	}
	if (events.length === 0) return null;
	if (kind === "responses") {
		// The terminal event carries the complete response object.
		const done = [...events].reverse().find((e) => e.type === "response.completed" && e.response);
		if (done) return done.response;
		return null;
	}
	// Messages: rebuild the content array from block start/delta events.
	const blocks: any[] = [];
	const byIndex = new Map<number, any>();
	for (const e of events) {
		if (e.type === "content_block_start" && typeof e.index === "number") {
			const b: any = { ...(e.content_block ?? {}) };
			if (b.type === "text") {
				b.text = b.text ?? "";
				b.citations = b.citations ?? [];
			}
			if (b.type === "web_search_tool_result") b.content = b.content ?? [];
			blocks[e.index] = b;
			byIndex.set(e.index, b);
			continue;
		}
		if (e.type === "content_block_delta" && typeof e.index === "number") {
			const b = byIndex.get(e.index);
			if (!b) continue;
			const d = e.delta ?? {};
			if (d.type === "text_delta" && typeof d.text === "string") b.text = (b.text ?? "") + d.text;
			// Search citations stream as citation deltas on the text block.
			if (d.type === "citation" && d.citation) (b.citations ??= []).push(d.citation);
			if (d.type === "web_search_result_location") (b.citations ??= []).push(d);
			// Tool-result content may arrive as delta content items.
			if (Array.isArray(d.content)) (b.content ??= []).push(...d.content);
			continue;
		}
	}
	const content = blocks.filter(Boolean);
	return content.length > 0 ? { content } : null;
}

async function routerRequest(path: string, key: string, body: unknown, signal?: AbortSignal, extraHeaders?: Record<string, string>, sseKind?: "responses" | "messages") {
	const timeout = AbortSignal.timeout(45_000);
	const res = await fetch(path, {
		method: "POST",
		headers: { Authorization: `Bearer ${key}`, "Content-Type": "application/json", ...(extraHeaders ?? {}) },
		body: JSON.stringify(body),
		signal: signal ? AbortSignal.any([signal, timeout]) : timeout,
	});
	const raw = await res.text().catch(() => "");
	if (!res.ok) {
		let message = raw.slice(0, 200);
		try {
			const json = JSON.parse(raw);
			message = json.error?.message ?? json.error ?? json.message ?? message;
		} catch { /* keep the raw slice */ }
		throw new Error(`${res.status}${message ? `: ${message}` : ""}`);
	}
	try {
		return JSON.parse(raw) as any;
	} catch {
		// Some gateways answer the Claude path with an SSE stream even when
		// plain JSON was asked for (proven 2026-10-25: /v1/messages returned
		// event:/data: lines). Reassemble the same body shape the parsers
		// below expect instead of failing with "non-JSON".
		if (sseKind) {
			const reassembled = parseSseBody(raw, sseKind);
			if (reassembled) return reassembled;
		}
		throw new Error("Router returned a response that is neither JSON nor SSE");
	}
}

async function openaiResponsesSearch(q: string, n: number, model: string, keys: SearchKeys, signal?: AbortSignal): Promise<SearchResult[]> {
	const base = (keys.griphubBaseUrl ?? "").replace(/\/+$/, "");
	const body = await routerRequest(
		`${base}/responses`,
		keys.griphubKey ?? "",
		{ model, input: `Search the web for: ${q}`, tools: [{ type: "web_search" }], stream: false },
		signal,
		undefined,
		"responses",
	);
	// The message item carries the answer text + url_citation annotations. A
	// web_search_call item proves the model actually searched (vs. answering
	// directly), so it is tracked: "did not search" and "searched but nothing
	// parsable" are different failures with different fixes.
	let text = "";
	let sawSearchCall = false;
	const citations: { title: string; url: string; start: number; end: number }[] = [];
	for (const item of body.output ?? []) {
		if (item.type === "web_search_call") {
			sawSearchCall = true;
			continue;
		}
		if (item.type !== "message") continue;
		for (const part of item.content ?? []) {
			// Gateways sometimes translate output_text to plain text parts.
			if (part.type !== "output_text" && part.type !== "text") continue;
			text += part.text ?? "";
			for (const a of part.annotations ?? []) {
				if (a.url && (a.type === "url_citation" || !a.type)) citations.push({ title: a.title ?? "", url: a.url, start: a.start_index ?? 0, end: a.end_index ?? 0 });
			}
		}
	}
	const out: SearchResult[] = [];
	const seen = new Set<string>();
	for (const c of citations) {
		if (seen.has(c.url) || out.length >= n) continue;
		seen.add(c.url);
		const snippet = text
			.slice(Math.max(0, c.start - 150), Math.min(text.length, c.end + 150))
			.replace(/\s+/g, " ")
			.trim();
		out.push({ title: c.title, url: c.url, snippet });
	}
	if (out.length === 0) {
		throw new Error(sawSearchCall ? "OpenAI search ran but returned no citations" : "OpenAI model did not search for this query");
	}
	return out;
}

async function anthropicMessagesSearch(q: string, n: number, model: string, keys: SearchKeys, signal?: AbortSignal): Promise<SearchResult[]> {
	const base = (keys.griphubBaseUrl ?? "").replace(/\/+$/, "");
	const body = await routerRequest(
		`${base}/messages`,
		keys.griphubKey ?? "",
		{
			model,
			max_tokens: 1024,
			messages: [{ role: "user", content: `Search the web for: ${q}` }],
			tools: [{ type: "web_search_20250305", name: "web_search", max_uses: n }],
			stream: false,
		},
		signal,
		{ "anthropic-version": "2023-06-01" },
		"messages",
	);
	const out: SearchResult[] = [];
	const seen = new Set<string>();
	let sawSearch = false;
	const push = (title: string, url: string, snippet: string) => {
		if (!url || seen.has(url) || out.length >= n) return;
		seen.add(url);
		out.push({ title, url, snippet });
	};
	for (const block of body.content ?? []) {
		if (block.type === "server_tool_use" && block.name === "web_search") {
			sawSearch = true;
			continue;
		}
		if (block.type === "web_search_tool_result") {
			for (const r of block.content ?? []) {
				if (r.type === "web_search_result") push(r.title ?? "", r.url, "");
			}
			continue;
		}
		// Some gateways return search citations on the text blocks instead of tool-result blocks.
		if (block.type === "text" && Array.isArray(block.citations)) {
			for (const c of block.citations) {
				if (c.type === "web_search_result_location") push(c.title ?? "", c.url, c.cited_text ?? "");
			}
		}
	}
	if (out.length === 0) {
		throw new Error(sawSearch ? "Anthropic search ran but returned no results" : "Anthropic model did not search for this query");
	}
	return out;
}

export async function webSearch(q: string, n: number, keys: SearchKeys, signal?: AbortSignal, source?: string) {
	const attempts: [string, () => Promise<SearchResult[]>][] = [];
	// Router search uses dedicated search models, not the conversation's model:
	// a DeepSeek/GLM chat still searches through a GPT/Claude model on the
	// same saved GripHub key. Priority is fixed: OpenAI first, then Anthropic,
	// then the keyed engines below, then DuckDuckGo. An empty search model
	// skips that backend (the toggle alone does not decide it).
	const openaiModel = (keys.openaiSearchModel ?? "").trim();
	const anthropicModel = (keys.anthropicSearchModel ?? "").trim();
	if (keys.openaiSearch && keys.griphubKey && openaiModel) {
		attempts.push(["openai-responses", () => openaiResponsesSearch(q, n, openaiModel, keys, signal)]);
	}
	if (keys.anthropicSearch && keys.griphubKey && anthropicModel) {
		attempts.push(["anthropic-messages", () => anthropicMessagesSearch(q, n, anthropicModel, keys, signal)]);
	}
	if (keys.s1Search && keys.s1.length) {
		const name = source ? `search1api/${source}` : "search1api";
		attempts.push([name, () => withKeys("Search1API", keys.s1, (k) => s1Search(q, n, k, source, signal), s1KeyProblem)]);
	}
	if (keys.tinyfishSearch && keys.tinyfish.length) attempts.push(["tinyfish", () => withKeys("TinyFish", keys.tinyfish, (k) => tinyfishSearch(q, n, k, signal))]);
	if (keys.braveSearch && keys.brave.length) attempts.push(["brave", () => withKeys("Brave", keys.brave, (k) => braveSearch(q, n, k, signal))]);
	if (keys.tavilySearch && keys.tavily.length) attempts.push(["tavily", () => withKeys("Tavily", keys.tavily, (k) => tavilySearch(q, n, k, signal))]);
	attempts.push(
		["duckduckgo", () => duckSearch(q, n, signal)],
		["duckduckgo-lite", () => duckLiteSearch(q, n, signal)],
		["brave", () => braveHtmlSearch(q, n, signal)],
	);
	const errors: string[] = [];
	for (const [name, attempt] of attempts) {
		try {
			return { engine: name, results: await attempt() };
		} catch (e) {
			if (signal?.aborted) throw e;
			errors.push(`${name}: ${(e as Error).message}`);
		}
	}
	// Every backend failing is not about the query: say so, or the model keeps trying new wordings.
	throw new Error(
		`Search failed (${errors.join("; ")}). Web search is unavailable right now; do not retry with other queries. Continue without it and tell the user.`,
	);
}

// ---------------------------------------------------------------------------
// Fetch

/** Reads at most `budget` bytes of a response body, so a huge page cannot OOM the host. */
async function readCapped(res: Response, budget: number): Promise<string> {
	if (!res.body) return "";
	const reader = res.body.getReader();
	const chunks: Uint8Array[] = [];
	let total = 0;
	try {
		for (;;) {
			const { done, value } = await reader.read();
			if (done) break;
			if (!value) continue;
			const take = Math.min(value.length, budget - total);
			if (take > 0) {
				chunks.push(value.subarray(0, take));
				total += take;
			}
			if (total >= budget) {
				await reader.cancel().catch(() => {});
				break;
			}
		}
	} finally {
		reader.releaseLock();
	}
	const out = new Uint8Array(total);
	let off = 0;
	for (const c of chunks) {
		out.set(c, off);
		off += c.length;
	}
	return new TextDecoder().decode(out);
}

export async function webFetch(url: string, signal?: AbortSignal) {
	if (!/^https?:\/\//i.test(url)) url = `https://${url}`;
	// The caller may never abort, so cap the wait at 60s (combined with the
	// caller's signal) and the body at 5 MB: the tool pages the text
	// afterwards anyway (max 60k chars per call), so nothing is lost.
	const ctrl = new AbortController();
	const timer = setTimeout(() => ctrl.abort(new Error("web_fetch timed out after 60 seconds")), 60_000);
	const onCallerAbort = () => ctrl.abort(signal?.reason);
	if (signal) {
		if (signal.aborted) ctrl.abort(signal.reason);
		else signal.addEventListener("abort", onCallerAbort, { once: true });
	}
	let res: Response;
	let raw: string;
	try {
		res = await fetch(url, {
			headers: { "User-Agent": UA, Accept: "text/html,application/xhtml+xml,text/plain,application/json;q=0.9,*/*;q=0.5" },
			redirect: "follow",
			signal: ctrl.signal,
		});
		const type = res.headers.get("content-type") ?? "";
		raw = await readCapped(res, 5_000_000);
		return finishFetch(res, type, raw);
	} finally {
		clearTimeout(timer);
		signal?.removeEventListener("abort", onCallerAbort);
	}
}

function finishFetch(res: Response, type: string, raw: string) {
	let text: string;
	let title = "";
	if (/html|xml/.test(type) || /^\s*<(!doctype|html)/i.test(raw)) {
		title = stripTags(findBlocks(raw, TITLE, 1)[0]?.inner ?? "");
		text = htmlToText(raw, res.url);
	} else {
		text = raw;
	}
	return { url: res.url, status: res.status, contentType: type, title, text };
}

// The page is the web's to write, and every step below used to be a regular expression that could be made to run for
// minutes on a few hundred kilobytes (`<` repeated 200 000 times took 62 s, and nothing restarted a host stuck there). The
// cause is always the same: an opening that has no end makes the engine look for the end from every opening again, so the
// work grows with the square of the page. The steps are the same and give the same text; each is now a scan that looks at
// every part of the page a bounded number of times. The tests compare the output with the old expressions, and time the
// shapes that broke them.

/** One kind of element: [open] and [close] are sources for case-insensitive RegExps; [tag] says the opening runs to the next `>`. */
interface Block {
	open: string;
	close: string;
	tag?: boolean;
}

interface Found {
	block: number;
	start: number;
	end: number;
	inner: string;
}

/** Where the last match of [source] starts in [s], or -1. */
function lastStart(s: string, source: string): number {
	const re = new RegExp(source, "gi");
	let at = -1;
	for (let m = re.exec(s); m; m = re.exec(s)) at = m.index;
	return at;
}

/**
 * The elements of [s] in order, as the expression `<open>[\s\S]*?<close>` of any of [blocks] would find them one after
 * another (the one that starts first wins, and the search goes on after its end), at most [limit] of them. An opening that
 * no closing follows ends the search for its kind, because no later opening has one either.
 */
function findBlocks(s: string, blocks: Block[], limit = Infinity): Found[] {
	const slots = blocks.map((b) => ({
		open: new RegExp(b.open, "gi"),
		close: new RegExp(b.close, "gi"),
		tag: !!b.tag,
		lastClose: lastStart(s, b.close),
		at: -1,
		innerStart: 0,
	}));
	const found: Found[] = [];
	let pos = 0;
	while (found.length < limit) {
		let best = -1;
		for (let i = 0; i < slots.length; i++) {
			const sl = slots[i];
			if (sl.at < pos) {
				sl.at = Infinity;
				sl.open.lastIndex = pos;
				const m = sl.open.exec(s);
				if (m) {
					// An opening that goes on to a `>` ends at the first one after its name (`[^>]*>`). Looked for here, not by the
					// expression: with no `>` left, the engine would look for it again from every opening.
					const end = m.index + m[0].length;
					const gt = sl.tag ? s.indexOf(">", end) : end - 1;
					if (gt >= 0 && gt + 1 <= sl.lastClose) {
						sl.at = m.index;
						sl.innerStart = gt + 1;
					}
				}
			}
			if (sl.at < Infinity && (best < 0 || sl.at < slots[best].at)) best = i;
		}
		if (best < 0) break;
		const sl = slots[best];
		sl.close.lastIndex = sl.innerStart;
		const end = sl.close.exec(s) as RegExpExecArray; // there is one: the opening was only taken when a closing starts after it
		found.push({ block: best, start: sl.at, end: end.index + end[0].length, inner: s.slice(sl.innerStart, end.index) });
		pos = end.index + end[0].length;
	}
	return found;
}

/** [s] with each element of [blocks] replaced by what [to] says (see findBlocks). */
function replaceBlocks(s: string, blocks: Block[], to: (block: number, inner: string) => string): string {
	let out = "";
	let pos = 0;
	for (const f of findBlocks(s, blocks)) {
		out += s.slice(pos, f.start) + to(f.block, f.inner);
		pos = f.end;
	}
	return out + s.slice(pos);
}

/** `s.replace(re, to)` for an expression whose every match ends with `>`: nothing after the last `>` can match. */
function replaceTags(s: string, re: RegExp, to: string): string {
	const cut = s.lastIndexOf(">") + 1;
	return cut === 0 ? s : s.slice(0, cut).replace(re, to) + s.slice(cut);
}

/** Tags removed with what is between them and their closing tag. */
const NOISE_TAGS = ["script", "style", "noscript", "svg", "head", "template", "iframe", "nav", "footer", "form"];

/**
 * Links with an address: `[label](address)` for one that goes somewhere on the web, the label alone for the rest. This
 * is `<a\b[^>]*href="([^"#][^"]*)"[^>]*>([\s\S]*?)<\/a>` taken apart: the address is the one after the last `href="` in
 * the tag that is followed by a quote (the value may hold a `>`), the label runs to the next `</a>`.
 */
function linkify(s: string, base: string): string {
	const open = /<a\b/gi;
	const close = /<\/a>/gi;
	const lastClose = lastStart(s, "<\\/a>");
	let out = "";
	let pos = 0;
	for (;;) {
		open.lastIndex = pos;
		const found = open.exec(s);
		if (!found) break;
		const i = found.index;
		const gt = s.indexOf(">", i + 2); // the first `>`: the tag's attributes before the address end here at the latest
		if (gt < 0) break; // no `>` for this one, or any later one
		const region = s.slice(i + 2, gt);
		const starts: number[] = [];
		const re = /href="/gi;
		for (let m = re.exec(region); m; m = re.exec(region)) starts.push(i + 2 + m.index);
		let hit: { href: string; from: number } | null = null;
		for (let k = starts.length - 1; k >= 0 && !hit; k--) {
			const p = starts[k];
			const first = s[p + 6];
			if (first === undefined || first === '"' || first === "#") continue;
			const q = s.indexOf('"', p + 7);
			if (q < 0) continue;
			// Only the first of these can end past `gt`: the quote of the `href="` after it comes first for the others.
			const after = q < gt ? gt : s.indexOf(">", q + 1);
			if (after < 0 || lastClose < after + 1) continue;
			hit = { href: s.slice(p + 6, q), from: after + 1 };
		}
		if (!hit) {
			// Any `<a` before this tag's `>` has the same ones to choose from, and none of them works either.
			out += s.slice(pos, gt + 1);
			pos = gt + 1;
			continue;
		}
		close.lastIndex = hit.from;
		const end = close.exec(s) as RegExpExecArray;
		const label = stripTags(s.slice(hit.from, end.index)).trim();
		let replacement = "";
		if (label) {
			let abs = decodeEntities(hit.href);
			try {
				abs = new URL(abs, base).href;
			} catch {}
			replacement = /^https?:/.test(abs) ? `[${label}](${abs})` : label;
		}
		out += s.slice(pos, i) + replacement;
		pos = end.index + end[0].length;
	}
	return out + s.slice(pos);
}

const MAIN_BLOCKS: Block[] = [
	{ open: "<main\\b", close: "<\\/main>" },
	{ open: "<article\\b", close: "<\\/article>" },
];
const NOISE_BLOCKS: Block[] = NOISE_TAGS.map((t) => ({ open: `<${t}\\b`, close: `<\\/${t}>` }));
const COMMENT: Block[] = [{ open: "<!--", close: "-->" }];
const PRE: Block[] = [{ open: "<pre\\b", close: "<\\/pre>", tag: true }];
const CODE: Block[] = [{ open: "<code\\b", close: "<\\/code>", tag: true }];
const HEADINGS: Block[] = [1, 2, 3, 4, 5, 6].map((n) => ({ open: `<h${n}\\b`, close: `<\\/h${n}>`, tag: true }));
const TITLE: Block[] = [{ open: "<title", close: "<\\/title>", tag: true }];

/** Readable text with light markdown: headings, lists, links and code kept. */
export function htmlToText(html: string, base = ""): string {
	let s = html;
	// Prefer the main content when the page marks it (the first of `main` and `article` to open and close).
	const main = findBlocks(s, MAIN_BLOCKS, 1)[0];
	if (main && main.end - main.start > 500) s = s.slice(main.start, main.end);
	s = replaceBlocks(s, NOISE_BLOCKS, () => "");
	s = replaceBlocks(s, COMMENT, () => "");
	s = replaceBlocks(s, PRE, (_, code) => `\n\n\`\`\`\n${decodeEntities(stripTags(code))}\n\`\`\`\n\n`);
	s = replaceBlocks(s, CODE, (_, code) => `\`${decodeEntities(stripTags(code))}\``);
	s = replaceBlocks(s, HEADINGS, (n, t) => `\n\n${"#".repeat(n + 1)} ${stripTags(t).trim()}\n\n`);
	s = linkify(s, base);
	s = replaceTags(s, /<li\b[^>]*>/gi, "\n- ");
	s = replaceTags(s, /<(br|hr)\b[^>]*>/gi, "\n");
	s = replaceTags(s, /<\/(p|div|section|tr|table|ul|ol|blockquote|dd|dt|h\d)>/gi, "\n\n");
	s = replaceTags(s, /<(td|th)\b[^>]*>/gi, " | ");
	s = decodeEntities(stripTags(s));
	return s
		.split("\n")
		.map((l) => l.replace(/[ \t ]+/g, " ").trimEnd())
		.join("\n")
		.replace(/\n{3,}/g, "\n\n")
		.trim();
}

/** [s] without its tags (`<` up to the next `>`; a `<` with no `>` after it is text), in one pass. */
function removeTags(s: string): string {
	let out = "";
	let from = 0;
	for (let lt = s.indexOf("<"); lt >= 0; ) {
		const gt = s.indexOf(">", lt + 1);
		if (gt < 0) break; // no `>` after this `<`, so none after any later one
		if (gt === lt + 1) {
			lt = s.indexOf("<", lt + 1); // `<>` is not a tag; whatever follows may be
			continue;
		}
		out += s.slice(from, lt);
		from = gt + 1;
		lt = s.indexOf("<", from);
	}
	return out + s.slice(from);
}

/** Whitespace that ends in a line break becomes the line break: all of `\s+\n`, without looking for the break from every space. */
function tidyLineEnds(s: string): string {
	return s.replace(/\s{2,}/g, (run) => {
		const lf = run.lastIndexOf("\n");
		return lf >= 1 ? `\n${run.slice(lf + 1)}` : run;
	});
}

export function stripTags(s: string) {
	return tidyLineEnds(decodeEntities(removeTags(s))).trim();
}

/** A character reference as the character, or U+FFFD for a number that is no character (String.fromCodePoint throws on it). */
function codePoint(n: number): string {
	return Number.isInteger(n) && n >= 0 && n <= 0x10ffff ? String.fromCodePoint(n) : "�";
}

function decodeEntities(s: string) {
	return s
		.replace(/&#(\d+);/g, (_, d) => codePoint(Number(d)))
		.replace(/&#x([0-9a-f]+);/gi, (_, h) => codePoint(parseInt(h, 16)))
		.replace(/&nbsp;/g, " ")
		.replace(/&lt;/g, "<")
		.replace(/&gt;/g, ">")
		.replace(/&quot;/g, '"')
		.replace(/&#39;|&apos;/g, "'")
		.replace(/&amp;/g, "&");
}

// ---------------------------------------------------------------------------
// Tool definitions for the pi SDK

const text = (t: string) => ({ content: [{ type: "text" as const, text: t }], details: undefined });

export function webTools(keys: () => SearchKeys, cwd: () => string) {
	return [
		{
			name: "web_search",
			label: "Web search",
			description:
				"Search the web. Use it to find install instructions, documentation, package names, API usage, and fixes for errors instead of guessing. Returns titles, URLs and snippets; follow up with web_fetch to read a page.",
			promptSnippet: "web_search: search the web for docs, install steps, and error fixes",
			promptGuidelines: [
				"When unsure how to install or use something, or an error is unfamiliar, use web_search and then web_fetch the most relevant result before acting.",
			],
			parameters: Type.Object({
				query: Type.String({ description: "Search query" }),
				count: Type.Optional(Type.Number({ description: "Target number of results (default 8, max 20). List engines return this many; OpenAI/Anthropic router backends return however many sources the model cites." })),
				source: Type.Optional(
					Type.String({
						description:
							"Where to search, when a Search1API key is set: github (code, issues), reddit (experience reports), arxiv (papers), youtube, x, wikipedia, or another engine such as bing. Default: general web.",
					}),
				),
			}),
			async execute(_id: string, params: { query: string; count?: number; source?: string }, signal?: AbortSignal) {
				// Per-project switch off: answer plainly instead of failing, so the agent can say so and move on. Absent means on.
				if (keys().projectSearch?.[cwd()] === false) return text("Web search is disabled for this project.");
				// Models trained on other search tools often send numResults/limit instead.
				const alt = params as any;
				const requested = Number(params.count ?? alt.numResults ?? alt.num_results ?? alt.limit ?? 8) || 8;
				const n = Math.min(Math.max(requested, 1), 20);
				const source = params.source && S1_SOURCES.includes(params.source.toLowerCase()) ? params.source.toLowerCase() : undefined;
				const { engine, results } = await webSearch(params.query, n, keys(), signal, source);
				const body = results
					.map((r, i) => `${i + 1}. ${r.title}\n   ${r.url}${r.snippet ? `\n   ${r.snippet}` : ""}`)
					.join("\n\n");
				return text(`Results for "${params.query}" (${engine}):\n\n${body}`);
			},
		},
		{
			name: "web_fetch",
			label: "Fetch page",
			description:
				"Fetch a web page or raw file by URL and return its readable text (HTML is converted to markdown-like text). Long pages are paged: pass `offset` from the previous result to continue.",
			promptSnippet: "web_fetch: read a web page or raw file as text",
			parameters: Type.Object({
				url: Type.String({ description: "The URL to fetch" }),
				offset: Type.Optional(Type.Number({ description: "Character offset to continue from (default 0)" })),
				maxChars: Type.Optional(Type.Number({ description: "Characters to return (default 20000)" })),
			}),
			async execute(_id: string, params: { url: string; offset?: number; maxChars?: number }, signal?: AbortSignal) {
				const k = keys();
				let page: { url: string; status?: number; title: string; text: string } | null = null;
				let note = "";
				if (k.s1Crawl && k.s1.length) {
					try {
						const url = /^https?:\/\//i.test(params.url) ? params.url : `https://${params.url}`;
						page = { ...(await s1Crawl(url, k.s1, signal)), status: 200 };
					} catch (e) {
						if (signal?.aborted) throw e;
						note = `\n(Search1API crawl failed: ${(e as Error).message}; fetched directly instead)`;
					}
				}
				page ??= await webFetch(params.url, signal);
				const offset = Math.max(params.offset ?? 0, 0);
				const max = Math.min(Math.max(params.maxChars ?? 20000, 1000), 60000);
				const chunk = page.text.slice(offset, offset + max);
				const more = offset + max < page.text.length;
				const head = [
					`URL: ${page.url}${page.status ? ` (HTTP ${page.status})` : ""}${note}`,
					page.title ? `Title: ${page.title}` : null,
					`Showing ${offset}-${offset + chunk.length} of ${page.text.length} characters${more ? `; continue with offset ${offset + chunk.length}` : ""}`,
				]
					.filter(Boolean)
					.join("\n");
				return text(`${head}\n\n${chunk}`);
			},
		},
		{
			name: "web_screenshot",
			label: "Screenshot page",
			description:
				"Take a screenshot of a public web page (rendered in a real browser by Search1API) and look at it. Use it to check how a deployed site or a design looks. Needs a Search1API key with screenshots turned on in Settings > Web & DNS. The PNG is also saved under .screenshots in the project.",
			promptSnippet: "web_screenshot: see how a public web page looks",
			parameters: Type.Object({
				url: Type.String({ description: "Public http(s) URL" }),
				fullPage: Type.Optional(Type.Boolean({ description: "The whole page instead of the first screen (default false)" })),
				selector: Type.Optional(Type.String({ description: "CSS selector of one element to capture instead" })),
				dark: Type.Optional(Type.Boolean({ description: "Prefer the page's dark color scheme" })),
				mobile: Type.Optional(Type.Boolean({ description: "Phone-sized viewport (390x844) instead of desktop (1440x900)" })),
			}),
			async execute(
				_id: string,
				params: { url: string; fullPage?: boolean; selector?: string; dark?: boolean; mobile?: boolean },
				signal?: AbortSignal,
			) {
				const k = keys();
				if (!k.s1.length) throw new Error("No Search1API key. Add one in Settings > Web & DNS.");
				if (!k.s1Screenshot) throw new Error("Screenshots are turned off in Settings > Web & DNS.");
				const url = /^https?:\/\//i.test(params.url) ? params.url : `https://${params.url}`;
				const shot = await s1Screenshot(
					url,
					{
						// Search1API takes one or the other.
						...(params.selector ? { selector: params.selector } : { full_page: !!params.fullPage }),
						color_scheme: params.dark ? "dark" : "light",
						...(params.mobile ? { viewport: { width: 390, height: 844 } } : {}),
					},
					k.s1,
					signal,
				);
				const dir = join(cwd(), ".screenshots");
				mkdirSync(dir, { recursive: true });
				// Keep screenshots out of git (the folder ignores itself); deploys already skip dot-folders.
				if (!existsSync(join(dir, ".gitignore"))) writeFileSync(join(dir, ".gitignore"), "*\n");
				const host = (() => {
					try {
						return new URL(url).hostname.replace(/[^\w.-]/g, "_");
					} catch {
						return "page";
					}
				})();
				const file = join(dir, `${host}-${new Date().toISOString().replace(/[:.]/g, "-")}.png`);
				writeFileSync(file, shot.bytes);
				return {
					content: [
						{ type: "text" as const, text: `Screenshot of ${url} (${Math.round(shot.bytes.length / 1024)} KB), saved to ${file}` },
						{ type: "image" as const, data: shot.bytes.toString("base64"), mimeType: shot.mimeType },
					],
					details: undefined,
				};
			},
		},
	];
}
