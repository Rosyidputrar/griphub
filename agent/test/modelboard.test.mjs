// Model board: the parsers against real (cut down) responses in test/fixtures, and the client's cache, staleness and
// refusals against a fake fetch. The router quietly serves 24h/today for a window or period it does not know; the
// client must not let that pass under another label.
import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { build } from "esbuild";

const here = dirname(fileURLToPath(import.meta.url));
mkdirSync(join(here, "..", "build"), { recursive: true });
const out = mkdtempSync(join(here, "..", "build", "modelboard-test-"));
const fixture = (n) => JSON.parse(readFileSync(join(here, "fixtures", n), "utf8"));

const outfile = join(out, "modelboard.mjs");
await build({ entryPoints: [join(here, "..", "src", "modelboard.ts")], outfile, bundle: true, platform: "node", format: "esm", packages: "external", logLevel: "error" });
const M = await import(pathToFileURL(outfile).href);
process.on("exit", () => rmSync(out, { recursive: true, force: true }));

const status = () => fixture("model-status.json");
const rank = () => fixture("model-rank.json");

test("rank: rows keep the router's order, names come from displayNames, unnamed models stay null", () => {
	const b = M.parseRank(rank(), "7d");
	assert.equal(b.period, "7d");
	assert.equal(b.rows[0].model, "deepseek-v4.1-flash");
	assert.equal(b.rows[0].name, "Deepseek V4.1 Flash");
	assert.ok(b.rows.every((r, i) => i === 0 || b.rows[i - 1].tokens >= r.tokens), "most tokens first, as sent");
	const img = b.rows.find((r) => r.model === "gemini-3.1-flash-image");
	assert.equal(img.name, null);
	assert.ok(img.images > 0);
	// A model the router counted but never named.
	assert.equal(b.rows.find((r) => r.model === "glm-5.1").name, null);
	assert.ok(b.rows.every((r) => Number.isInteger(r.requests) && r.requests >= 0));
});

test("rank: refuses a period the router did not serve, and a body that is not a board", () => {
	assert.throws(() => M.parseRank({ ...rank(), period: "today" }, "7d"), /answered today instead of 7d/);
	assert.throws(() => M.parseRank({ rows: "x", period: "7d" }, "7d"), /Unexpected/);
	assert.throws(() => M.parseRank(null, "7d"), /Unexpected/);
	assert.throws(() => M.parseRank([], "7d"), /Unexpected/);
	// A row with no model id is dropped, not shown as a blank.
	const b = M.parseRank({ period: "24h", rows: [{ requests: 3 }, { model: "a", requests: 2, totalTokens: 9 }], displayNames: {} }, "24h");
	assert.deepEqual(b.rows.map((r) => r.model), ["a"]);
});

test("status: totals, summary, states and the numbers a card needs", () => {
	const b = M.parseStatus(status(), "24h");
	assert.equal(b.window, "24h");
	assert.equal(b.barMs, 1_800_000);
	assert.equal(b.models.length, 15);
	assert.deepEqual(b.summary, { models: 49, active: 34, up: 34, degraded: 2, down: 1 });
	assert.equal(b.totals.requests, b.totals.ok + b.totals.fail);
	const by = Object.fromEntries(b.models.map((m) => [m.model, m]));
	assert.equal(by["grok-4.7"].state, "down");
	assert.equal(by["grok-4.7"].active, false);
	assert.equal(by["gpt-5.6-luna"].state, "degraded");
	assert.equal(by["grok-4.6"].state, "quiet");
	assert.equal(by["claude-opus-5.5"].state, "up");
	assert.equal(by["claude-opus-5.5"].name, "Claude Opus 5.5");
	assert.ok(by["gpt-5.6-luna"].errors.some((e) => e.category === "empty_response" && e.count > 0));
});

test("status: missing numbers are null, not zero", () => {
	const m = M.parseStatus(status(), "24h").models.find((x) => x.model === "grok-4.6");
	// The router sent null for these on a quiet model; showing 0 tokens/s or 0% would be false.
	assert.equal(m.recentSuccessRate, null);
	assert.equal(m.ttftP50Ms, null);
	assert.equal(m.tokensPerSecond, null);
	assert.equal(m.latencyP50Ms, 1250);
	const odd = M.parseStatus({ ...status(), models: [{ model: "x", state: "weird", successRate: "99", latencyP50Ms: NaN }] }, "24h").models[0];
	assert.equal(odd.state, "unknown");
	assert.equal(odd.successRate, null);
	assert.equal(odd.latencyP50Ms, null);
	assert.equal(odd.name, "x", "falls back to the id");
});

test("status: bars become [ok, fail, level] and keep their time", () => {
	const b = M.parseStatus(status(), "24h");
	const luna = b.models.find((m) => m.model === "gpt-5.6-luna");
	assert.equal(luna.bars.length, 48);
	assert.ok(luna.bars.every((x) => x.length === 3 && x.every(Number.isInteger)));
	// 48 half-hour bars end at the current half hour: the first one is 23.5 h before the last.
	const first = Date.parse(luna.barsFrom);
	assert.ok(Number.isFinite(first));
	assert.equal(first % b.barMs, 0, "bars start on the bar grid");
	assert.ok(Date.parse(b.generatedAt) - first <= 48 * b.barMs && Date.parse(b.generatedAt) - first >= 47 * b.barMs);
	// level: 0 none, 1 ok, 2 partial, 3 down; ok with no traffic is none, a failing half-hour with successes is partial or down.
	for (const [ok, fail, level] of luna.bars) {
		if (level === 0) assert.deepEqual([ok, fail], [0, 0]);
		if (level === 1) assert.ok(ok > 0);
		if (level === 3) assert.ok(fail > 0);
	}
	assert.ok(luna.bars.some((x) => x[2] === 3), "the failing bar at the end is kept");
	const none = M.parseStatus({ ...status(), models: [{ model: "x", bars: [{ ok: 1, fail: 0, level: "future" }, null] }] }, "24h").models[0];
	assert.deepEqual(none.bars, [[1, 0, 0], [0, 0, 0]], "an unknown level reads as none");
});

test("status: refuses another window than the one asked for, or no bar length", () => {
	assert.throws(() => M.parseStatus(status(), "7d"), /answered 24h instead of 7d/);
	assert.throws(() => M.parseStatus({ ...status(), barMs: 0 }, "24h"), /no bar length/);
	assert.throws(() => M.parseStatus({ window: "24h" }, "24h"), /Unexpected/);
});

test("status: a board with no personal field in it", () => {
	const text = JSON.stringify(M.parseStatus(status(), "24h"));
	assert.ok(!/@|email|cookie|session|token_/i.test(text), text.slice(0, 200));
	assert.ok(text.length < readFileSync(join(here, "fixtures", "model-status.json")).length, "smaller than what the router sent");
});

// ---------------------------------------------------------------------------

function harness(answers, { key = "gh-test-key", start = 1_000_000 } = {}) {
	const dir = mkdtempSync(join(out, "c-"));
	const calls = [];
	let t = start;
	const fetch = async (url, init) => {
		calls.push({ url: String(url), auth: init.headers.Authorization ?? null });
		const a = typeof answers === "function" ? answers(String(url), calls.length) : answers;
		if (a instanceof Error) throw a;
		return { ok: a.status === undefined || a.status < 400, status: a.status ?? 200, statusText: "x", text: async () => (typeof a.body === "string" ? a.body : JSON.stringify(a.body)) };
	};
	const mk = () => new M.ModelBoard({ key: () => key, cacheFile: join(dir, "c.json"), fetch, now: () => t });
	return { mk, calls, dir, tick: (ms) => (t += ms) };
}

test("rank needs no key and sends none; status sends the saved key as a bearer", async () => {
	const h = harness((url) => ({ body: url.includes("model-rank") ? rank() : status() }));
	const b = h.mk();
	await b.rank("7d");
	await b.status("24h");
	assert.equal(h.calls[0].url, "https://griphubrouter.web.id/api/public/model-rank?period=7d");
	assert.equal(h.calls[0].auth, null);
	assert.equal(h.calls[1].url, "https://griphubrouter.web.id/api/portal/model-status?window=24h");
	assert.equal(h.calls[1].auth, "Bearer gh-test-key");
});

test("only known periods and windows are asked for", async () => {
	const h = harness({ body: rank() });
	const b = h.mk();
	assert.throws(() => b.rank("3d"), /Unknown period/);
	assert.throws(() => b.status("12h"), /Unknown window/);
	assert.throws(() => b.rank("7d&x=1"), /Unknown period/);
	assert.equal(h.calls.length, 0);
});

test("the router answering another period is refused, not shown under the label asked", async () => {
	const h = harness({ body: { ...rank(), period: "today" } });
	await assert.rejects(h.mk().rank("7d"), /answered today instead of 7d/);
});

test("a fresh copy is reused; a forced refresh still waits MIN_REFETCH_MS; then it fetches again", async () => {
	const h = harness({ body: rank() });
	const b = h.mk();
	const first = await b.rank("7d");
	assert.equal(first.stale, false);
	h.tick(M.MIN_REFETCH_MS - 1);
	await b.rank("7d", true);
	assert.equal(h.calls.length, 1, "a pull right after a fetch does not call the router");
	h.tick(2);
	await b.rank("7d", true);
	assert.equal(h.calls.length, 2);
	h.tick(M.RANK_TTL_MS - 1000);
	await b.rank("7d");
	assert.equal(h.calls.length, 2, "still fresh");
	h.tick(2000);
	await b.rank("7d");
	assert.equal(h.calls.length, 3, "expired");
});

test("two screens asking at once share one request", async () => {
	const h = harness({ body: status() });
	const b = h.mk();
	const [x, y] = await Promise.all([b.status("24h"), b.status("24h")]);
	assert.equal(h.calls.length, 1);
	assert.equal(x.board, y.board);
});

test("when the router fails the old copy is served, marked stale, with the reason", async () => {
	let fail = false;
	const h = harness(() => (fail ? new Error("fetch failed") : { body: rank() }));
	const b = h.mk();
	await b.rank("7d");
	h.tick(M.RANK_TTL_MS + 1);
	fail = true;
	const s = await b.rank("7d");
	assert.equal(s.stale, true);
	assert.match(s.error, /fetch failed/);
	assert.equal(s.board.rows[0].model, "deepseek-v4.1-flash");
	// With nothing cached there is nothing to fall back to: the error reaches the screen.
	await assert.rejects(h.mk().rank("30d"), /fetch failed/); // nothing cached for 30d
});

test("a rejected key is not hidden behind an old copy; no key is said so", async () => {
	let denied = false;
	const h = harness(() => (denied ? { status: 401, body: { error: "Invalid key" } } : { body: status() }));
	const b = h.mk();
	await b.status("24h");
	h.tick(M.STATUS_TTL_MS + 1);
	denied = true;
	await assert.rejects(b.status("24h"), (e) => e.status === 401 && /Invalid key/.test(e.message));
	const none = harness({ body: status() }, { key: "" });
	await assert.rejects(none.mk().status("24h"), /No GripHub key saved/);
	assert.equal(none.calls.length, 0, "no call without a key");
	// Rank still works without one.
	const r = harness({ body: rank() }, { key: "" });
	assert.equal((await r.mk().rank("7d")).stale, false);
});

test("429 pauses every call for a minute; non-JSON and HTTP errors are reported", async () => {
	const h = harness(() => ({ status: 429, body: { error: "slow down" } }));
	const b = h.mk();
	await assert.rejects(b.rank("24h"), /slow down \(429\)/);
	await assert.rejects(b.status("6h"), /rate limiting/);
	assert.equal(h.calls.length, 1);
	h.tick(60_001);
	await assert.rejects(b.rank("24h"), /429/);
	assert.equal(h.calls.length, 2);
	await assert.rejects(harness({ status: 200, body: "<html>" }).mk().rank("24h"), /no JSON/);
	await assert.rejects(harness({ status: 500, body: { error: { message: "boom" } } }).mk().rank("24h"), /boom \(500\)/);
});

test("the cache survives a restart, and a broken cache file is an empty one", async () => {
	const h = harness({ body: rank() });
	await h.mk().rank("7d");
	const again = h.mk();
	const s = await again.rank("7d");
	assert.equal(s.stale, false);
	assert.equal(h.calls.length, 1, "served from the file");
	writeFileSync(join(h.dir, "c.json"), "{not json");
	await h.mk().rank("7d");
	assert.equal(h.calls.length, 2);
	writeFileSync(join(h.dir, "c.json"), JSON.stringify({ version: 2, rank: { "7d": 1 } }));
	await h.mk().rank("7d");
	assert.equal(h.calls.length, 3, "an unknown version is ignored");
});

test("the cache file holds no key and no personal data", async () => {
	const h = harness((url) => ({ body: url.includes("model-rank") ? rank() : status() }));
	const b = h.mk();
	await b.rank("7d");
	await b.status("24h");
	const text = readFileSync(join(h.dir, "c.json"), "utf8");
	assert.ok(!text.includes("gh-test-key"));
	assert.ok(!/Bearer|@/.test(text));
});
