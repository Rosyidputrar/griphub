// Vision translator in the real host, on the mock router (Fitur 6 kriteria a-e): a picture sent to a non-vision chat
// is read by a vision model, the reading goes to the chat's model (which never gets the picture), its cost is in the
// chat's file; a follow-up about the picture gets one targeted reading; "off" refuses; a vision model needs no reading;
// a failed reading sends nothing and makes nothing up; "ask first" asks once per chat.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { host, PNG } from "./router-host.mjs";

const RECEIPT = "Struk INDOMARET Cab. Sudirman\nTeks terbaca:\nAQUA 600ML 2 x 3.500 = 7.000\nROTI TAWAR 1 x 15.800 = 15.800\nTOTAL 22.800\nTUNAI 50.000 KEMBALI 27.200";
const photo = [{ type: "image", data: PNG, mimeType: "image/png" }];

/** Every griphub-usage entry in the chat files (the translator's readings). */
function usageEntries(agentDir) {
	const out = [];
	const walk = (dir) => {
		for (const name of readdirSync(dir, { withFileTypes: true })) {
			const p = join(dir, name.name);
			if (name.isDirectory()) walk(p);
			else if (name.name.endsWith(".jsonl")) {
				for (const line of readFileSync(p, "utf8").split("\n").filter(Boolean)) {
					const e = JSON.parse(line);
					if (e.type === "custom" && e.customType === "griphub-usage") out.push(e.data);
				}
			}
		}
	};
	walk(join(agentDir, "sessions"));
	return out;
}

test("a receipt photo to a non-vision model: read by a vision model, the chat's model answers from the reading, the cost is recorded", async (t) => {
	const h = await host(t, { MOCK_VISION_TEXT: RECEIPT });
	await h.call("new_session", { chatMode: "chat" });
	assert.equal((await h.call("state")).model.id, "kimi-k3", "a non-vision model, picked by hand");
	const sent = await h.turn("Berapa total belanja di struk ini?", { images: photo });
	assert.deepEqual(h.log().filter((x) => x === "vision"), ["vision"], "one reading");
	// The chat's model got the reading and no picture.
	assert.equal(sent.length, 1);
	assert.equal(sent[0].model, "kimi-k3");
	assert.equal(sent[0].images, 0, "the picture never reached the non-vision model");
	const body = h.bodies().at(-1);
	assert.match(body, /Isi gambar menurut model vision/);
	assert.match(body, /TOTAL 22\.800/);
	assert.match(body, /model utama tidak melihat gambar asli/);
	// Which model read it, and what it cost, went to the app and into the chat's file.
	const ev = h.records.find((r) => r.type === "vision");
	assert.equal(ev.reading.ok, true);
	assert.equal(ev.reading.kind, "full");
	assert.ok(ev.reading.credits > 0);
	const translator = ev.reading.model;
	assert.ok(["gemini-3.8-flash", "gemini-3.1-pro"].includes(translator), translator);
	const used = usageEntries(h.agentDir);
	assert.equal(used.length, 1);
	assert.equal(used[0].model, translator);
	assert.equal(used[0].purpose, "vision");
	// Usage (per day and model) counts the reading like any other request.
	const usage = await h.call("usage", { days: 1 });
	assert.ok(usage.some((r) => r.model === translator && r.requests === 1), JSON.stringify(usage));
	// The picture itself stays with the message in the chat.
	const messages = await h.call("messages");
	const user = messages.find((m) => m.role === "user");
	assert.ok(user.content.some((c) => c.type === "image"), "the original picture is kept");
});

test("a follow-up about a detail of the picture gets one targeted reading, not a second full one", async (t) => {
	const h = await host(t, { MOCK_VISION_TEXT: RECEIPT });
	await h.call("new_session", { chatMode: "chat" });
	await h.turn("Ini struk belanjaku", { images: photo });
	await h.turn("Terima kasih!");
	assert.equal(h.log().filter((x) => x === "vision").length, 1, "an unrelated message reads nothing");
	await h.turn("Berapa kembalian yang tertulis di struk itu?");
	assert.equal(h.log().filter((x) => x === "vision").length, 2);
	const body = h.bodies().at(-1);
	assert.match(body, /Detail gambar menurut model vision/);
	assert.doesNotMatch(body, /Isi gambar menurut/);
	const kinds = h.records.filter((r) => r.type === "vision").map((r) => r.reading.kind);
	assert.deepEqual(kinds, ["full", "targeted"]);
});

test("with the translator off, a picture to a non-vision model is refused with the reason, and nothing is sent", async (t) => {
	const h = await host(t);
	await h.call("new_session", { chatMode: "chat" });
	await h.call("settings_set", { settings: { visionTranslator: "off" } });
	const r = await h.raw("prompt", { text: "Apa ini?", images: photo });
	assert.equal(r.ok, false);
	assert.match(r.error, /can't read pictures, and the vision translator is off/);
	assert.equal(h.requests().length, 0);
	assert.equal(h.log().length, 0);
});

test("a vision model reads the picture itself: no reading at all", async (t) => {
	const h = await host(t);
	await h.call("new_session", { chatMode: "chat" });
	await h.call("set_model", { provider: "griphub", model: "gemini-3.8-flash" });
	const sent = await h.turn("Apa ini?", { images: photo });
	assert.equal(h.log().filter((x) => x === "vision").length, 0);
	assert.equal(sent[0].images, 1, "the picture went to the vision model");
	assert.equal(h.records.filter((r) => r.type === "vision").length, 0);
	assert.equal(usageEntries(h.agentDir).length, 0);
});

for (const [what, mock] of [
	["fails", { MOCK_VISION_FAIL: "1" }],
	["reads nothing", { MOCK_VISION_EMPTY: "1" }],
]) {
	test(`when the reading ${what}, the user is told, and no turn is sent on a made-up picture`, async (t) => {
		const h = await host(t, mock);
		await h.call("new_session", { chatMode: "chat" });
		const r = await h.raw("prompt", { text: "Apa isi struk ini?", images: photo });
		assert.equal(r.ok, false);
		assert.match(r.error, /could not read the picture, so nothing was sent/);
		assert.equal(h.requests().filter((x) => !x.vision).length, 0, "the chat's model was never asked");
		assert.equal(h.records.find((x) => x.type === "vision").reading.ok, false);
	});
}

test('"ask first" asks before the first paid reading of a chat, then not again', async (t) => {
	const h = await host(t, { MOCK_VISION_TEXT: RECEIPT });
	await h.call("new_session", { chatMode: "chat" });
	await h.call("settings_set", { settings: { visionTranslator: "ask" } });
	const asked = await h.call("prompt", { text: "Apa ini?", images: photo });
	assert.ok(asked.visionConsent, JSON.stringify(asked));
	assert.ok(asked.visionConsent.modelName);
	assert.ok(asked.visionConsent.estimate > 0);
	assert.equal(h.log().length, 0, "nothing paid before the answer");
	await h.turn("Apa ini?", { images: photo, visionConsent: true });
	assert.equal(h.log().filter((x) => x === "vision").length, 1);
	// Agreed for this chat: the next picture is read without asking.
	await h.turn("Dan ini?", { images: photo });
	assert.equal(h.log().filter((x) => x === "vision").length, 2);
});

test("the translator the user chose reads the picture", async (t) => {
	const h = await host(t, { MOCK_VISION_TEXT: RECEIPT });
	await h.call("new_session", { chatMode: "chat" });
	await h.call("settings_set", { settings: { visionTranslatorModel: "gemini-3.1-pro" } });
	const info = await h.call("vision_translator_info");
	assert.deepEqual(info.current, { id: "gemini-3.1-pro", name: "Gemini 3.1 Pro", manual: true });
	await h.turn("Apa ini?", { images: photo });
	assert.equal(h.records.find((r) => r.type === "vision").reading.model, "gemini-3.1-pro");
	assert.match(h.bodies().at(-1), /model vision Gemini 3\.1 Pro/);
});

test("scanning a document: a vision model reads it through the router, the cost is in the chat, the text comes back", async (t) => {
	const h = await host(t, { MOCK_VISION_TEXT: RECEIPT });
	await h.call("new_session", { chatMode: "chat" });
	await h.turn("Halo");
	const r = await h.call("scan_document", { image: photo[0] });
	assert.match(r.text, /TOTAL 22\.800/);
	assert.ok(["gemini-3.8-flash", "gemini-3.1-pro"].includes(r.model));
	assert.ok(r.credits > 0);
	assert.equal(h.log().filter((x) => x === "vision").length, 1);
	assert.equal(usageEntries(h.agentDir).length, 1, "recorded like any other request");
	const bad = await h.raw("scan_document", { image: { type: "text" } });
	assert.equal(bad.ok, false);
});
