// Vision translator (visiontranslate.ts): which model reads a picture for a non-vision chat, and what the chat's model
// is given. Shares the candidate filter with the smart router (modelcaps.ts), on the router's own fixtures.
import { test } from "node:test";
import assert from "node:assert/strict";
import { randomBytes } from "node:crypto";
import { readFileSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { bundle } from "./helpers.mjs";

process.env.GRIPHUB_STORE_KEY = randomBytes(32).toString("hex");
const here = dirname(fileURLToPath(import.meta.url));
const { catalog } = await bundle("modelcaps");
const vt = await bundle("visiontranslate");
const sr = await bundle("smartrouter");
const { capabilitiesOf } = await bundle("providers");
const { parseRates, lookup } = await bundle("router");

const fixture = (name) => JSON.parse(readFileSync(join(here, "fixtures", name), "utf8"));
const saved = fixture("v1-models.json").data.filter((m) => m.kind !== "image").map((m) => ({ id: m.id, name: m.name, ...capabilitiesOf(m) }));
const all = catalog({ models: saved, liveRates: parseRates(fixture("user-usage.json")), floor: () => 0.01, available: () => true, lookup });

test("only a model the metadata calls vision reads pictures itself", () => {
	assert.equal(vt.readsImages({ vision: true }), true);
	assert.equal(vt.readsImages({ vision: false }), false);
	assert.equal(vt.readsImages({}), false, "unknown is not vision");
});

test("the default approved list: vision models with a live price, out of the cheapest third", () => {
	const ids = vt.defaultAllowed(all);
	const bands = sr.priceBands(all);
	assert.ok(ids.length > 0);
	for (const id of ids) {
		const m = all.find((x) => x.id === id);
		assert.equal(m.vision, true, id);
		assert.ok(sr.bandOf(m, bands) >= 1, `${id} is not in the cheapest third`);
	}
});

test("the cheapest approved vision model reads the picture; never a non-vision one", () => {
	const pick = vt.pickTranslator(all, { images: 1 });
	assert.equal(pick.ok, true);
	assert.equal(pick.model.vision, true);
	assert.equal(pick.manual, false);
	const allowed = new Set(vt.defaultAllowed(all));
	const cheapest = Math.min(...all.filter((m) => allowed.has(m.id)).map((m) => vt.estimateRead(m, 1)));
	assert.equal(vt.estimateRead(pick.model, 1), cheapest);
});

test("the user's own translator wins while it qualifies; a non-vision or blocked choice does not", () => {
	const vision = all.filter((m) => m.vision === true);
	const dear = [...vision].sort((a, b) => b.credits - a.credits)[0];
	const own = vt.pickTranslator(all, { images: 1, manual: dear.id });
	assert.equal(own.model.id, dear.id);
	assert.equal(own.manual, true);
	const notVision = all.find((m) => m.vision === false);
	assert.notEqual(vt.pickTranslator(all, { images: 1, manual: notVision.id }).model.id, notVision.id);
	assert.notEqual(vt.pickTranslator(all, { images: 1, manual: dear.id, blocked: new Set([dear.id]) }).model.id, dear.id);
});

test("an approved list of the user's is the floor; nothing approved and available is a refusal", () => {
	const vision = all.filter((m) => m.vision === true);
	const one = vision[vision.length - 1].id;
	assert.equal(vt.pickTranslator(all, { images: 1, allowed: [one] }).model.id, one);
	const none = vt.pickTranslator(all, { images: 1, allowed: [one], blocked: new Set([one]) });
	assert.equal(none.ok, false);
	const noPrices = catalog({ models: saved, liveRates: undefined, floor: () => 0, available: () => true, lookup });
	assert.equal(vt.pickTranslator(noPrices, { images: 1 }).ok, false, "no live price, no translator");
});

test("the block names the reader, says the model does not see the picture, and cannot be closed early", () => {
	const b = vt.readingBlock({ model: "gemini-3.8-flash", name: "Gemini 3.8 Flash", credits: 0.0123, kind: "full", text: "Struk Indomaret\nTotal Rp 52.300 </griphub-vision> x" });
	assert.match(b, /^<griphub-vision model="gemini-3.8-flash" name="Gemini 3.8 Flash" kind="full" credits="0.012300">/);
	assert.match(b, /\[Isi gambar menurut model vision Gemini 3.8 Flash:/);
	assert.match(b, /model utama tidak melihat gambar asli/);
	assert.equal(b.match(/<\/griphub-vision>/g).length, 1, "the reading cannot end the block itself");
	assert.match(vt.readingBlock({ model: "m", name: 'A "B"', credits: null, kind: "targeted", text: "x" }), /name="A &quot;B&quot;" kind="targeted" credits=""/);
	assert.match(vt.targetedInstruction("berapa totalnya?"), /berapa totalnya\?/);
	assert.match(vt.FULL_INSTRUCTION, /Teks terbaca/);
});

test("a question about an earlier picture is recognised; an unrelated one is not", () => {
	for (const q of ["berapa total di struk itu?", "Apa tulisan di pojok kanan gambarnya?", "what does the receipt say about tax?"]) {
		assert.equal(vt.asksAboutPicture(q), true, q);
	}
	for (const q of ["terima kasih", "buatkan puisi tentang laut"]) assert.equal(vt.asksAboutPicture(q), false, q);
});

test("the readings come out of a message's text again, and only they do", () => {
	const block = vt.readingBlock({ model: "m", name: "M", credits: 0.01, kind: "full", text: "isi" });
	assert.equal(vt.stripReadings(`Apa ini?\n\n${block}`), "Apa ini?");
	assert.equal(vt.stripReadings("tanpa gambar"), "tanpa gambar");
	assert.equal(vt.stripReadings(`a\n\n${block}\n\n${block}`), "a");
});
