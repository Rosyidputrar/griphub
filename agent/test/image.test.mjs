// generate_image (image.ts): which model, how many, the limits (per call, without asking, per day, the daily budget),
// parallel pictures reported as they land, files in .images/, partial failures and what may have been billed.
import { test } from "node:test";
import assert from "node:assert/strict";
import { randomBytes } from "node:crypto";
import { existsSync, readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { bundle, tempDir } from "./helpers.mjs";

// Each bundle has its own copy of secure.ts, which reads the store key once at import (and removes it from env).
const KEY = randomBytes(32).toString("hex");
process.env.GRIPHUB_STORE_KEY = KEY;
const { Images, imageSize, cheapestModel, imageExt, slug } = await bundle("image");
process.env.GRIPHUB_STORE_KEY = KEY;
const { IMAGE_DEFAULTS, Integrations } = await bundle("integrations");
process.env.GRIPHUB_STORE_KEY = KEY;
const { ImageError } = await bundle("providers");

// A 1x1 PNG.
const PNG = Buffer.from(
	"iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=",
	"base64",
).toString("base64");

const RATES = { "gpt-image": 4, "gemini-3.1-flash-image": 2.5 };

/** An Images with stand-ins for the router; [over] overrides hooks, [settings] the picture settings. */
function make(t, { settings = {}, over = {}, rates = RATES } = {}) {
	const dir = tempDir(t);
	const calls = [];
	const s = { ...IMAGE_DEFAULTS, ...settings };
	const images = new Images(join(dir, "images.json"), {
		settings: () => s,
		key: () => "sk-test",
		baseUrl: "https://router.test/v1",
		listModels: async () => Object.keys(rates).map((id) => ({ id, name: id })),
		rate: (m) => rates[m] ?? null,
		knownImageModels: () => Object.keys(rates),
		generate: async (_b, _k, model, prompt, size) => {
			calls.push({ model, prompt, size });
			return PNG;
		},
		budgetError: () => null,
		...over,
	});
	return { images, dir, calls, s };
}

async function run(images, dir, params, { ask, key = {} } = {}) {
	const tool = images.tool(key, () => dir, ask);
	images.startRun(key);
	const updates = [];
	try {
		const r = await tool.execute("call-1", params, undefined, (u) => updates.push(u));
		return { r, updates };
	} catch (e) {
		return { error: e.message, updates };
	}
}

test("helpers: sizes, cheapest, file types, names", () => {
	assert.equal(imageSize("16:9"), "1536x1024");
	assert.equal(imageSize("Portrait"), "1024x1536");
	assert.equal(imageSize("1024X1536"), "1024x1536");
	assert.equal(imageSize("1024×1024"), "1024x1024");
	assert.equal(imageSize("huge"), "1024x1024");
	assert.equal(imageSize(undefined), "1024x1024");
	assert.equal(cheapestModel([{ id: "a", credits: 4 }, { id: "b", credits: null }, { id: "c", credits: 2.5 }]).id, "c");
	assert.equal(cheapestModel([{ id: "a", credits: null }]), null);
	assert.equal(imageExt(Buffer.from(PNG, "base64")), "png");
	assert.equal(imageExt(Buffer.from([0xff, 0xd8, 0xff, 0])), "jpg");
	assert.equal(imageExt(Buffer.from("<html>")), "");
	assert.equal(slug("Logo kedai kopi, minimalis! cangkir dengan uap daun"), "logo-kedai-kopi-minimalis-cangkir-dengan");
	assert.equal(slug("!!!"), "image");
});

test("by default the cheapest model makes the pictures, in parallel, saved in .images/ out of git", async (t) => {
	const { images, dir, calls } = make(t);
	const { r, updates } = await run(images, dir, { prompt: "A coffee logo", count: 2, size: "square" });
	assert.equal(calls.length, 2);
	assert.ok(calls.every((c) => c.model === "gemini-3.1-flash-image" && c.size === "1024x1024"));
	assert.equal(r.isError, false);
	assert.equal(r.details.cheapest, true);
	assert.equal(r.details.credits, 5);
	assert.deepEqual(r.details.slots.map((s) => s.status), ["done", "done"]);
	const files = readdirSync(join(dir, ".images")).sort();
	assert.equal(readFileSync(join(dir, ".images", ".gitignore"), "utf8"), "*\n");
	assert.equal(files.filter((f) => f.endsWith(".png")).length, 2);
	assert.match(files.find((f) => f.endsWith("-1.png")), /^\d{8}-\d{6}-a-coffee-logo-1\.png$/);
	for (const s of r.details.slots) assert.ok(existsSync(s.file));
	// The agent gets paths as text, never the pictures.
	assert.ok(r.content.every((c) => c.type === "text"));
	assert.match(r.content[0].text, /Made 2 of 2 pictures with gemini-3\.1-flash-image/);
	// Reported as they land: first all running, last all done.
	assert.deepEqual(updates[0].details.slots.map((s) => s.status), ["running", "running"]);
	assert.deepEqual(updates.at(-1).details.slots.map((s) => s.status), ["done", "done"]);
	assert.equal(images.today().count, 2);
	assert.equal(images.today().credits, 5);
});

test("the user's default model is used; one the agent names must exist; a retired default falls back", async (t) => {
	const a = make(t, { settings: { imageModel: "gpt-image" } });
	const r1 = await run(a.images, a.dir, { prompt: "x" });
	assert.equal(a.calls[0].model, "gpt-image");
	assert.equal(r1.r.details.cheapest, false);

	const b = make(t);
	const r2 = await run(b.images, b.dir, { prompt: "x", model: "dall-e-9" });
	assert.match(r2.error, /Unknown image model "dall-e-9"\. Available: gpt-image, gemini-3\.1-flash-image/);
	assert.equal(b.calls.length, 0);

	const c = make(t, { settings: { imageModel: "old-image-model" } });
	await run(c.images, c.dir, { prompt: "x" });
	assert.equal(c.calls[0].model, "gemini-3.1-flash-image");
});

test("pictures per call are capped, and the agent is told how many were left out", async (t) => {
	const { images, dir, calls } = make(t, { settings: { imageMaxPerCall: 2, imageAutoCredits: 100 } });
	const { r } = await run(images, dir, { prompt: "x", count: 20 });
	assert.equal(calls.length, 2);
	assert.equal(r.details.asked, 20);
	assert.match(r.content[0].text, /Only 2 of the 20 asked for were made/);
	// Nonsense counts make one.
	const again = make(t);
	await run(again.images, again.dir, { prompt: "x", count: "lots" });
	assert.equal(again.calls.length, 1);
});

test("over the without-asking limit: the user is asked with the cost; a no makes nothing", async (t) => {
	const { images, dir, calls } = make(t, { settings: { imageAutoCredits: 10, imageModel: "gpt-image" } });
	const asked = [];
	const no = await run(images, dir, { prompt: "x", count: 3 }, { ask: async (summary, reason) => (asked.push({ summary, reason }), false) });
	assert.equal(asked.length, 1);
	assert.match(asked[0].summary, /^3 × gpt-image \(1024x1024\) ≈ 12 credits\nx$/);
	assert.match(no.error, /The user declined: about 12 credits, over the 10 credits/);
	assert.equal(calls.length, 0);

	const yes = await run(images, dir, { prompt: "x", count: 3 }, { ask: async () => true });
	assert.equal(calls.length, 3);
	assert.equal(yes.r.details.credits, 12);
});

test("the without-asking limit counts the whole request: many small calls cannot get around it", async (t) => {
	const { images, dir, calls } = make(t, { settings: { imageAutoCredits: 10, imageModel: "gpt-image" } });
	const key = {};
	images.startRun(key);
	const tool = images.tool(key, () => dir, async () => false);
	await tool.execute("1", { prompt: "a" }); // 4
	await tool.execute("2", { prompt: "b" }); // 8
	await assert.rejects(tool.execute("3", { prompt: "c" }), /over the 10 credits a request may spend on pictures without asking \(8 already spent/);
	assert.equal(calls.length, 2);
	// A new request starts from zero.
	images.startRun(key);
	await tool.execute("4", { prompt: "d" });
	assert.equal(calls.length, 3);
});

test("over the limit with 'cheapest': the cheapest model is used when it fits, without asking", async (t) => {
	const { images, dir, calls } = make(t, { settings: { imageAutoCredits: 6, imageModel: "gpt-image", imageOverLimit: "cheapest" } });
	let asked = 0;
	const { r } = await run(images, dir, { prompt: "x", count: 2 }, { ask: async () => (asked++, true) });
	assert.equal(asked, 0);
	assert.ok(calls.every((c) => c.model === "gemini-3.1-flash-image"));
	assert.equal(r.details.cheapest, true);
});

test("over the limit with 'refuse', or with nobody to ask: refused with the reason", async (t) => {
	const a = make(t, { settings: { imageAutoCredits: 1, imageOverLimit: "refuse" } });
	const r1 = await run(a.images, a.dir, { prompt: "x" }, { ask: async () => true });
	assert.match(r1.error, /The user set pictures over the limit to be refused/);
	const b = make(t, { settings: { imageAutoCredits: 1 } });
	const r2 = await run(b.images, b.dir, { prompt: "x" });
	assert.match(r2.error, /Nobody is watching this run/);
	// 0 = always ask.
	const c = make(t, { settings: { imageAutoCredits: 0 } });
	let asked = 0;
	await run(c.images, c.dir, { prompt: "x" }, { ask: async () => (asked++, true) });
	assert.equal(asked, 1);
	// An unknown price is always asked about.
	const d = make(t, { rates: { "mystery-image": null } });
	let askedD = "";
	await run(d.images, d.dir, { prompt: "x" }, { ask: async (_s, _r) => ((askedD = "yes"), false) });
	assert.equal(askedD, "yes");
});

test("the daily picture limit and the daily budget are hard: never asked, refused before anything is bought", async (t) => {
	const { images, dir, calls } = make(t, { settings: { imageDailyCredits: 6, imageAutoCredits: 100 } });
	await run(images, dir, { prompt: "x", count: 2 }); // 5 of 6
	let asked = 0;
	const over = await run(images, dir, { prompt: "y" }, { ask: async () => (asked++, true) });
	assert.match(over.error, /Daily picture limit of 6 credits reached \(5 spent on pictures today, this needs 2\.5 more\)/);
	assert.equal(asked, 0);
	assert.equal(calls.length, 2);

	const budget = make(t, { over: { budgetError: (extra) => (extra > 3 ? `Not enough daily budget left (needs ${extra})` : null) } });
	const r = await run(budget.images, budget.dir, { prompt: "x", count: 2 });
	assert.match(r.error, /Not enough daily budget left \(needs 5\)/);
	assert.equal(budget.calls.length, 0);
	// With "cheapest", a dearer default that would not fit the day falls back to the cheapest that does.
	const fit = make(t, { settings: { imageModel: "gpt-image", imageDailyCredits: 3, imageOverLimit: "cheapest", imageAutoCredits: 100 } });
	await run(fit.images, fit.dir, { prompt: "x" });
	assert.equal(fit.calls[0].model, "gemini-3.1-flash-image");
});

test("one picture failing keeps the other; billed-or-not is said; maybe-billed counts toward the day", async (t) => {
	let n = 0;
	const { images, dir } = make(t, {
		settings: { imageAutoCredits: 100 },
		over: {
			generate: async () => {
				n++;
				if (n === 2) throw new ImageError("400 Bad Request: content policy", 400);
				if (n === 3) throw new ImageError("No answer after 3 minutes", 0, true);
				return PNG;
			},
		},
	});
	const { r } = await run(images, dir, { prompt: "x", count: 3 });
	assert.equal(r.isError, false, "one made is a result, not an error");
	assert.deepEqual(r.details.slots.map((s) => s.status).sort(), ["done", "failed", "failed"]);
	assert.equal(r.details.credits, 2.5, "only what was made");
	const text = r.content[0].text;
	assert.match(text, /content policy \(not billed\)/);
	assert.match(text, /No answer after 3 minutes \(it may still have been billed; do not retry it on your own\)/);
	// The made one and the maybe-billed one count toward the day; the refused one does not.
	assert.equal(images.today().credits, 5);
	assert.equal(images.creditsSince(0), 5);
});

test("all failing is an error result; something that is not a picture is not saved", async (t) => {
	const { images, dir } = make(t, { over: { generate: async () => Buffer.from("<html>oops</html>").toString("base64") } });
	const { r } = await run(images, dir, { prompt: "x" });
	assert.equal(r.isError, true);
	assert.match(r.content[0].text, /not a picture/);
	assert.ok(!existsSync(join(dir, ".images")) || readdirSync(join(dir, ".images")).every((f) => !f.endsWith(".png")));
});

test("Stop aborts the pictures in flight; they are marked stopped and the reservation is released", async (t) => {
	const ctrl = new AbortController();
	const { images, dir } = make(t, {
		over: {
			generate: (_b, _k, _m, _p, _s, signal) =>
				new Promise((_, reject) => signal.addEventListener("abort", () => reject(new ImageError("Stopped", 0, true)))),
		},
	});
	const key = {};
	images.startRun(key);
	const p = images.tool(key, () => dir).execute("1", { prompt: "x", count: 2 }, ctrl.signal);
	await new Promise((r) => setTimeout(r, 20));
	ctrl.abort();
	const r = await p;
	assert.deepEqual(r.details.slots.map((s) => s.status), ["stopped", "stopped"]);
	assert.match(r.content[0].text, /stopped by the user/);
	assert.equal(images.creditsSince(0), 5, "a stopped request may have been billed: counted");
});

test("parallel calls cannot both fit under the day: what is in flight counts", async (t) => {
	let release;
	const gate = new Promise((r) => (release = r));
	const { images, dir } = make(t, {
		settings: { imageDailyCredits: 6, imageAutoCredits: 100 },
		over: { generate: async () => (await gate, PNG) },
	});
	const first = images.tool({}, () => dir).execute("1", { prompt: "a", count: 2 }); // reserves 5
	await new Promise((r) => setTimeout(r, 20));
	await assert.rejects(images.tool({}, () => dir).execute("2", { prompt: "b" }), /Daily picture limit/);
	release();
	await first;
});

test("no key, empty prompt, no models: clear refusals; offline uses the rate table", async (t) => {
	const a = make(t, { over: { key: () => "" } });
	assert.match((await run(a.images, a.dir, { prompt: "x" })).error, /No GripHub key is saved/);
	const b = make(t);
	assert.match((await run(b.images, b.dir, { prompt: "   " })).error, /prompt is empty/);
	const c = make(t, { over: { listModels: async () => { throw new Error("offline"); } } });
	await run(c.images, c.dir, { prompt: "x" });
	assert.equal(c.calls[0].model, "gemini-3.1-flash-image");
	const d = make(t, { rates: {}, over: { listModels: async () => [] } });
	assert.match((await run(d.images, d.dir, { prompt: "x" })).error, /offers no image models/);
});

test("the tool refuses itself once turned off", async (t) => {
	const { images, dir } = make(t, { settings: { imageAgentTool: false } });
	assert.match((await run(images, dir, { prompt: "x" })).error, /turned off in Settings → Pictures/);
});

test("the picture log survives a restart and only today counts", async (t) => {
	let now = Date.parse("2026-11-03T05:00:00Z");
	const dir = tempDir(t);
	const hooks = {
		settings: () => IMAGE_DEFAULTS,
		key: () => "k",
		baseUrl: "x",
		listModels: async () => [{ id: "gpt-image", name: "gpt-image" }],
		rate: () => 4,
		knownImageModels: () => [],
		generate: async () => PNG,
		budgetError: () => null,
		now: () => now,
	};
	const a = new Images(join(dir, "images.json"), hooks);
	a.record("gpt-image");
	now += 86400_000; // tomorrow (WIB)
	a.record("gpt-image");
	const b = new Images(join(dir, "images.json"), hooks);
	assert.deepEqual([b.today().count, b.today().credits], [1, 4]);
	assert.equal(b.creditsSince(0), 8);
});

test("settings: defaults are published, bad values are refused", (t) => {
	const dir = tempDir(t);
	const it = new Integrations(dir, dir, {});
	const pub = it.publicSettings();
	assert.equal(pub.imageModel, "auto");
	assert.equal(pub.imageAutoCredits, 10);
	assert.equal(pub.imageMaxPerCall, 4);
	assert.equal(pub.imageDailyCredits, 50);
	assert.equal(pub.imageOverLimit, "ask");
	assert.equal(pub.imageAgentTool, true);
	assert.equal(pub.imageUnattended, false);
	assert.throws(() => it.updateSettings({ imageMaxPerCall: 0 }), /from 1 to 8/);
	assert.throws(() => it.updateSettings({ imageMaxPerCall: 9 }), /from 1 to 8/);
	assert.throws(() => it.updateSettings({ imageMaxPerCall: 2.5 }), /from 1 to 8/);
	assert.throws(() => it.updateSettings({ imageAutoCredits: -1 }), /approval limit/);
	assert.throws(() => it.updateSettings({ imageDailyCredits: Number.NaN }), /daily picture limit/);
	assert.throws(() => it.updateSettings({ imageOverLimit: "yolo" }), /Unknown choice/);
	assert.throws(() => it.updateSettings({ imageAgentTool: "yes" }), /on or off/);
	const ok = it.updateSettings({ imageMaxPerCall: 8, imageAutoCredits: 0, imageDailyCredits: 0, imageOverLimit: "refuse", imageModel: "gpt-image" });
	assert.deepEqual([ok.imageMaxPerCall, ok.imageAutoCredits, ok.imageDailyCredits, ok.imageOverLimit, ok.imageModel], [8, 0, 0, "refuse", "gpt-image"]);
	// "" resets to the default, like other settings.
	assert.equal(it.updateSettings({ imageModel: "" }).imageModel, "auto");
});
