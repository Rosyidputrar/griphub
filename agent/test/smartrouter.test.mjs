// Smart router (smartrouter.ts + modelcaps.ts): from GripHub Router's own metadata (the /v1/models and live-rate
// fixtures), each turn gets the cheapest model that verifiably can do it; images never go to a model the metadata does
// not call vision; nothing without a live price is picked; failures climb a class; "nothing fits" is said, not guessed.
import { test } from "node:test";
import assert from "node:assert/strict";
import { randomBytes } from "node:crypto";
import { readFileSync, writeFileSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { bundle, tempDir } from "./helpers.mjs";

process.env.GRIPHUB_STORE_KEY = randomBytes(32).toString("hex");
const here = dirname(fileURLToPath(import.meta.url));
const { catalog, candidates, rejection } = await bundle("modelcaps");
const sr = await bundle("smartrouter");
const { capabilitiesOf } = await bundle("providers");
const { parseRates, lookup } = await bundle("router");

const fixture = (name) => JSON.parse(readFileSync(join(here, "fixtures", name), "utf8"));
const rawModels = fixture("v1-models.json").data;
const liveRates = parseRates(fixture("user-usage.json"));

/** The saved models as providers.ts keeps them (id, name and what capabilitiesOf reads). */
const saved = rawModels.filter((m) => m.kind !== "image").map((m) => ({ id: m.id, name: m.name, ...capabilitiesOf(m) }));
const metas = (over = {}) =>
	catalog({ models: saved, liveRates, floor: () => 0.01, available: () => true, lookup, ...over });

const chatNeed = (minContext = 8_000) => ({ vision: false, tools: false, minContext });
const opts = (coding = false) => ({ inputTokens: 2_000, coding });

test("the catalog keeps only what the metadata states: vision and tools as said, prices from the live rates", () => {
	const all = metas();
	assert.ok(all.length >= 50, `${all.length} chat models`);
	const fable = all.find((m) => m.id === "claude-fable-5");
	assert.equal(fable.vision, true);
	assert.equal(fable.tools, true);
	assert.equal(fable.credits, 8, "live rate, not the built-in table");
	// A model the metadata calls non-vision is recorded as such (not merely unknown).
	const noVision = rawModels.find((m) => m.capabilities?.vision === false);
	assert.ok(noVision, "the fixture has a non-vision model");
	assert.equal(all.find((m) => m.id === noVision.id).vision, false);
});

test("no live rates at all: nothing can be picked, and the reason says why", () => {
	const all = metas({ liveRates: undefined });
	assert.ok(all.every((m) => m.credits === undefined));
	const r = sr.select(all, chatNeed(), 0, opts());
	assert.equal(r.ok, false);
	assert.match(r.reason, /live price/);
	assert.deepEqual(r.missing, ["price"]);
	assert.equal(r.rejected["no-price"], all.length);
});

test("a light chat question goes to the cheapest model of the cheapest band, and says why", () => {
	const all = metas();
	const c = sr.classify({ text: "Ibu kota Jepang apa?", images: 0, coding: false, contextTokens: 0 });
	assert.equal(c.difficulty, 0);
	const r = sr.select(all, chatNeed(), c.difficulty, opts());
	assert.equal(r.ok, true);
	const cheapest = Math.min(...candidates(all, chatNeed()).map((m) => m.credits));
	assert.equal(r.choice.model.credits, cheapest, `${r.choice.model.id} at ${r.choice.model.credits}`);
	assert.equal(r.choice.band, 0);
	assert.ok(r.choice.estimate > 0);
});

test("an attached image only ever goes to a model the metadata calls vision", () => {
	const all = metas();
	const need = { vision: true, tools: false, minContext: 8_000 };
	for (const wanted of [0, 1, 2]) {
		const r = sr.select(all, need, wanted, opts());
		assert.equal(r.ok, true);
		assert.equal(r.choice.model.vision, true, `${r.choice.model.id} for band ${wanted}`);
	}
	// Vision unknown (not stated) is not vision.
	const unknown = all.map((m) => ({ ...m, vision: undefined }));
	const r = sr.select(unknown, need, 0, opts());
	assert.equal(r.ok, false);
	assert.match(r.reason, /reads images/);
	assert.deepEqual(r.missing, ["vision"]);
	// Every vision model blocked by the user: nothing fits, nothing is guessed.
	const blocked = new Set(all.filter((m) => m.vision).map((m) => m.id));
	const none = sr.select(all, need, 0, { ...opts(), blocked });
	assert.equal(none.ok, false);
	assert.equal(none.rejected.blocked, blocked.size);
});

test("a coding turn needs tools stated by the metadata", () => {
	const all = metas().map((m, i) => (i % 2 ? { ...m, tools: undefined } : m));
	const need = { vision: false, tools: true, minContext: 20_000 };
	const r = sr.select(all, need, 1, opts(true));
	assert.equal(r.ok, true);
	assert.equal(r.choice.model.tools, true);
	for (const m of all.filter((x) => x.tools !== true)) assert.equal(rejection(m, need, new Set()), "no-tools");
});

test("the conversation must fit: a model whose window is too small is not a candidate", () => {
	const all = metas();
	const huge = 900_000;
	const r = sr.select(all, chatNeed(huge), 0, opts());
	assert.equal(r.ok, true);
	assert.ok(r.choice.model.contextWindow >= huge);
	const none = sr.select(all, chatNeed(50_000_000), 0, opts());
	assert.equal(none.ok, false);
	assert.match(none.reason, /holds 50000k tokens/);
});

test("a model the router reports down, or the user blocked, is never picked", () => {
	const all = metas();
	const first = sr.select(all, chatNeed(), 0, opts()).choice.model.id;
	const blocked = sr.select(all, chatNeed(), 0, { ...opts(), blocked: new Set([first]) });
	assert.notEqual(blocked.choice.model.id, first);
	const down = sr.select(metas({ available: (id) => id !== first }), chatNeed(), 0, opts());
	assert.notEqual(down.choice.model.id, first);
});

test("harder turns ask for higher bands; a heavy one prefers a model that reasons", () => {
	const all = metas();
	const bands = sr.priceBands(all);
	const light = sr.select(all, chatNeed(), 0, opts()).choice;
	const medium = sr.select(all, chatNeed(), 1, opts()).choice;
	const heavy = sr.select(all, chatNeed(), 2, opts()).choice;
	assert.ok(light.model.credits <= medium.model.credits && medium.model.credits <= heavy.model.credits);
	assert.equal(sr.bandOf(heavy.model, bands), 2);
	assert.equal(heavy.model.reasoning, true);
});

test("when nothing reaches the wanted band, the strongest that fits is used and the choice says so", () => {
	const all = metas();
	const bands = sr.priceBands(all);
	const cheapOnly = all.filter((m) => sr.bandOf(m, bands) === 0 || m.credits === undefined);
	// Bands come from the whole catalog, so the cheap models stay band 0 even alone.
	const r = sr.select([...cheapOnly, ...all.filter((m) => sr.bandOf(m, bands) > 0).map((m) => ({ ...m, available: false }))], chatNeed(), 2, opts());
	assert.equal(r.ok, true);
	assert.equal(r.choice.belowWanted, true);
	assert.equal(r.choice.model.credits, Math.max(...cheapOnly.filter((m) => m.credits !== undefined).map((m) => m.credits)));
});

test("classification is local and explained", () => {
	assert.equal(sr.classify({ text: "halo", images: 0, coding: false, contextTokens: 0 }).difficulty, 0);
	assert.equal(sr.classify({ text: "tolong terjemahkan paragraf ini", images: 0, coding: false, contextTokens: 0 }).difficulty, 1);
	assert.equal(sr.classify({ text: "Refactor the auth module", images: 0, coding: true, contextTokens: 0 }).difficulty, 2);
	assert.equal(sr.classify({ text: "x".repeat(7000), images: 0, coding: false, contextTokens: 0 }).difficulty, 2);
	const coding = sr.classify({ text: "ls", images: 0, coding: true, contextTokens: 0 });
	assert.equal(coding.difficulty, 1);
	assert.ok(coding.reasons.includes("coding-chat"));
	assert.equal(sr.classify({ text: "lanjut", images: 0, coding: false, contextTokens: 90_000 }).difficulty, 1);
});

test("what counts as a failed turn, and how far the class climbs", () => {
	assert.equal(sr.failureOf({ stopReason: "error" }, "a", "b"), "error");
	assert.equal(sr.failureOf({ stopReason: "length" }, "a", "b"), "cut-off");
	assert.equal(sr.failureOf({ stopReason: "stop" }, "Buat fungsi sort", "  buat fungsi   SORT "), "resent");
	assert.equal(sr.failureOf({ stopReason: "stop" }, "x", "Salah, bukan itu"), "rejected");
	assert.equal(sr.failureOf({ stopReason: "stop" }, "x", "still broken after that"), "rejected");
	assert.equal(sr.failureOf({ stopReason: "stop" }, "x", "Terima kasih, lanjut ke langkah 2"), null);
	assert.equal(sr.nextFloor(0, 0), 1);
	assert.equal(sr.nextFloor(0, 1), 2);
	assert.equal(sr.nextFloor(1, 2), 2, "never past the top");
	assert.equal(sr.nextFloor(2, 0), 2, "never lowers the floor");
});

test("the routing store keeps a chat's state and log, and a broken file is a chat without routing", (t) => {
	const dir = tempDir(t);
	const store = new sr.RoutingStore(dir);
	assert.deepEqual(store.get("s1"), { version: 1, auto: false, floor: 0, log: [] });
	store.update("s1", (r) => {
		r.auto = true;
		r.log.push({ at: 1, turn: 0, kind: "on", reason: "chosen" });
	});
	assert.equal(store.get("s1").auto, true);
	assert.equal(store.get("s1").log.length, 1);
	writeFileSync(join(dir, "s2.json"), "{not json");
	assert.deepEqual(store.get("s2"), { version: 1, auto: false, floor: 0, log: [] });
	// An id with path characters stays inside the folder.
	store.update("../evil", (r) => (r.auto = true));
	assert.equal(store.get("../evil").auto, true);
	assert.ok(readFileSync(join(dir, ".._evil.json"), "utf8").includes('"auto":true'));
});
