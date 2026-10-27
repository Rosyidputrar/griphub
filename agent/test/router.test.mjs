// GripHub Router billing: parsers and the pricing rule, checked against real
// (anonymised) responses in test/fixtures. The rule must reproduce the
// router's own creditsCharged for every request.
import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, existsSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { build } from "esbuild";

const here = dirname(fileURLToPath(import.meta.url));
mkdirSync(join(here, "..", "build"), { recursive: true });
const out = mkdtempSync(join(here, "..", "build", "router-test-"));
const fixture = (n) => JSON.parse(readFileSync(join(here, "fixtures", n), "utf8"));

async function bundle(name) {
	const outfile = join(out, `${name}.mjs`);
	await build({ entryPoints: [join(here, "..", "src", `${name}.ts`)], outfile, bundle: true, platform: "node", format: "esm", packages: "external", logLevel: "error" });
	return import(pathToFileURL(outfile).href);
}

const R = await bundle("router");

test("pricing rule reproduces creditsCharged on every real request", () => {
	const rates = R.parseRates(fixture("user-usage.json"));
	const reqs = R.parseRequests(fixture("requests.json"));
	assert.ok(reqs.length > 50);
	let checked = 0;
	for (const r of reqs) {
		const rate = R.lookup(rates, r.model);
		if (!rate || rate.perImage) continue;
		// The router counts cache inside inputTokens; requestCredits takes them apart like pi does.
		const u = { input: r.inputTokens - r.cacheReadTokens - r.cacheWriteTokens, output: r.outputTokens, cacheRead: r.cacheReadTokens, cacheWrite: r.cacheWriteTokens };
		const got = R.requestCredits(rate, r.floor ?? undefined, u, { ok: r.ok });
		const want = r.ok ? r.credits : 0;
		assert.ok(Math.abs(got - want) < 2e-6, `${r.model} #${r.id}: got ${got}, router charged ${want}`);
		checked++;
	}
	assert.ok(checked > 50, `checked ${checked}`);
});

test("failed requests cost nothing; image models charge per image", () => {
	const rates = R.parseRates(fixture("user-usage.json"));
	assert.equal(R.requestCredits(rates["claude-opus-5.5"], 0.1, { input: 10, output: 10 }, { ok: false }), 0);
	assert.equal(rates["gpt-image"].perImage, true);
	assert.equal(R.requestCredits(rates["gpt-image"], undefined, { input: 0, output: 0 }), 4);
	assert.equal(R.requestCredits(undefined, 0.1, { input: 1, output: 1 }), null);
});

test("rates carry promos and normal prices", () => {
	const rates = R.parseRates(fixture("user-usage.json"));
	assert.deepEqual(
		{ c: rates["gpt-6-astra"].credits, l: rates["gpt-6-astra"].list, p: rates["gpt-6-astra"].promo },
		{ c: 5, l: 8, p: "GPT YES" },
	);
	assert.ok(rates["gpt-6-astra"].promoEndsAt.startsWith("2026-11"));
	assert.equal(rates["claude-opus-5.5"].list, undefined);
});

test("user-usage keeps billing data only, drops personal fields", () => {
	const p = R.parseUserUsage(fixture("user-usage.json"), 1000);
	const text = JSON.stringify(p);
	for (const leak of ["user@example.com", "Test User", "example.com/a.png", "TX-SECRET", "Test key", "qris"]) {
		assert.ok(!text.includes(leak), `leaked ${leak}`);
	}
	assert.equal(p.account.source, "user-usage");
	assert.ok(p.account.balance > 0);
	assert.ok(p.account.batches.every((b) => !b.status || b.status === "active"));
	assert.equal(p.modelStatus["gflow/veo-3.1"], false);
	assert.equal(Math.round(p.totals.credits * 1000), Math.round(fixture("user-usage.json").account.creditsUsed * 1000));
});

test("v1/credits parses as a fallback account; bad shapes throw", () => {
	const a = R.parseCredits(fixture("v1-credits.json"), 1);
	assert.equal(a.source, "credits");
	assert.ok(a.byModel.length > 10);
	assert.throws(() => R.parseUserUsage({ error: "x" }), /Unexpected/);
	assert.throws(() => R.parseCredits({}), /Unexpected/);
});

test("WIB days", () => {
	assert.equal(R.wibDayOf(Date.parse("2026-10-26T17:00:00Z")), "2026-10-27");
	assert.equal(R.wibDayOf(Date.parse("2026-10-26T16:59:59Z")), "2026-10-26");
	assert.equal(R.wibDayStart(Date.parse("2026-10-27T08:00:00Z")), "2026-10-26T17:00:00.000Z");
});

test("client: falls back to /v1/credits, learns floors, pages with afterId, caches to disk", async () => {
	const dir = mkdtempSync(join(out, "cache-"));
	const cacheFile = join(dir, "router-cache.json");
	const calls = [];
	let portalDown = true;
	const reqs = fixture("requests.json");
	const fakeFetch = async (url) => {
		const path = url.replace(R.ROUTER_ORIGIN, "");
		calls.push(path);
		const ok = (body) => ({ ok: true, status: 200, statusText: "OK", text: async () => JSON.stringify(body) });
		if (path.startsWith("/api/user-usage/requests")) {
			const after = Number(new URL(url).searchParams.get("afterId") ?? 0);
			return ok({ items: after ? [{ ...reqs.items[0], id: reqs.items[0].id + 1, model: "gpt-6-sol", floor: { minimum: 0.07, tokenCredits: 0.001 } }] : reqs.items });
		}
		if (path.startsWith("/api/user-usage")) return portalDown ? { ok: false, status: 502, statusText: "Bad Gateway", text: async () => "<html>" } : ok(fixture("user-usage.json"));
		if (path.startsWith("/v1/credits")) return ok(fixture("v1-credits.json"));
		throw new Error(`unexpected ${path}`);
	};
	const router = new R.Router({ key: () => "sk-test", cacheFile, fetch: fakeFetch, fallbackRates: { "claude-opus-5.5": { credits: 4 } } });
	const a = await router.refreshAccount();
	assert.equal(a.source, "credits");
	assert.ok(router.snapshot().ratesLive === false);
	portalDown = false;
	const b = await router.refreshAccount();
	assert.equal(b.source, "user-usage");
	assert.ok(router.snapshot().ratesLive);
	assert.equal((await router.refreshAccount(60_000)).fetchedAt, b.fetchedAt, "fresh cache reused");

	await router.refreshRequests();
	assert.equal(router.floor("claude-opus-5.5"), 0.1);
	await router.refreshRequests();
	assert.ok(calls.some((c) => c.includes("afterId=")), "second page uses afterId");
	assert.equal(router.floor("gpt-6-sol"), 0.07, "learned floor overrides the seed");
	assert.ok(existsSync(cacheFile));
	const cached = readFileSync(cacheFile, "utf8");
	for (const leak of ["user@example.com", "Test User", "TX-SECRET", "Test key"]) assert.ok(!cached.includes(leak), `cache leaked ${leak}`);
	// A new instance reads the same state back.
	const again = new R.Router({ key: () => "sk-test", cacheFile, fetch: fakeFetch, fallbackRates: {} });
	assert.equal(again.floor("gpt-6-sol"), 0.07);
	assert.ok(again.account());

	// Estimates use live rate + floor: a tiny opus call costs the floor, a big one its tokens.
	assert.equal(router.estimate("claude-opus-5.5", { input: 10, output: 10 }), 0.1);
	assert.ok(Math.abs(router.estimate("claude-opus-5.5", { input: 800, output: 2788, cacheRead: 82472, cacheWrite: 41 }) - 0.344404) < 1e-6);
});

test("401 is not hidden behind the fallback", async () => {
	const dir = mkdtempSync(join(out, "cache-"));
	const router = new R.Router({
		key: () => "bad",
		cacheFile: join(dir, "c.json"),
		fetch: async () => ({ ok: false, status: 401, statusText: "Unauthorized", text: async () => '{"error":{"message":"Invalid API key"}}' }),
		fallbackRates: {},
	});
	await assert.rejects(router.refreshAccount(), /Invalid API key/);
});

test("cleanup", () => rmSync(out, { recursive: true, force: true }));
