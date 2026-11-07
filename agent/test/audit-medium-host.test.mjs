// Regression tests for the audit's medium host findings, in the real host on the mock router:
// - a vision reading in a chat with no message yet (a scan in a new chat) still counts in Usage, once;
// - Scan follows the vision translator's setting (off is off; "ask first" asks);
// - Stop ends a vision reading under way, and nothing is sent;
// - a companion step whose request fails, or a chat that is left, does not leave the companion half on.
import { test } from "node:test";
import assert from "node:assert/strict";
import { host, PNG } from "./router-host.mjs";

const image = { type: "image", data: PNG, mimeType: "image/png" };
const frame = { data: PNG, mimeType: "image/png", width: 1080, height: 2400 };
const visionRequests = async (h) => (await h.call("usage", { days: 1 })).filter((r) => /^gemini/.test(r.model)).reduce((n, r) => n + r.requests, 0);

test("a scan in a chat with no message yet is counted in Usage, and still is once that chat is left", async (t) => {
	const h = await host(t, { MOCK_VISION_TEXT: "Struk, TOTAL 22.800" });
	await h.call("new_session", { chatMode: "chat" });
	await h.call("scan_document", { image });
	assert.equal(await visionRequests(h), 1);
	await h.call("new_session", { chatMode: "chat" });
	assert.equal(await visionRequests(h), 1, "the chat had no file; the cost is not lost with it");
});

test("a scan in a new chat that then gets a message is counted once, not twice", async (t) => {
	const h = await host(t, { MOCK_VISION_TEXT: "Struk, TOTAL 22.800" });
	await h.call("new_session", { chatMode: "chat" });
	await h.call("scan_document", { image });
	await h.turn("Berapa totalnya?");
	assert.equal(await visionRequests(h), 1);
});

test("Scan follows the translator's setting: off refuses, 'ask first' asks once per chat", async (t) => {
	const h = await host(t, { MOCK_VISION_TEXT: "Struk" });
	await h.call("new_session", { chatMode: "chat" });
	await h.call("settings_set", { settings: { visionTranslator: "off" } });
	const off = await h.raw("scan_document", { image });
	assert.equal(off.ok, false);
	assert.match(off.error, /vision translator is off/);
	assert.equal(h.log().filter((x) => x === "vision").length, 0, "nothing was read");

	await h.call("settings_set", { settings: { visionTranslator: "ask" } });
	const ask = await h.call("scan_document", { image });
	assert.ok(ask.visionConsent?.model, "asked first");
	assert.equal(h.log().filter((x) => x === "vision").length, 0);
	const yes = await h.call("scan_document", { image, visionConsent: true });
	assert.equal(yes.text, "Struk");
	const again = await h.call("scan_document", { image });
	assert.equal(again.text, "Struk", "the yes covers the chat");
});

test("Stop ends a vision reading under way: nothing is sent, and the chat says it was stopped", async (t) => {
	const h = await host(t, { MOCK_VISION_DELAY_MS: "20000" });
	await h.call("new_session", { chatMode: "chat" });
	// kimi-k3 cannot see: the picture is read first.
	const before = h.requests().length;
	const sending = h.raw("prompt", { text: "Apa ini?", images: [image] });
	await h.until(() => h.log().includes("vision"), 10_000, "the reading to start");
	const t0 = Date.now();
	await h.call("abort");
	const r = await sending;
	assert.ok(Date.now() - t0 < 5_000, "stopped at once, not after the reading");
	assert.equal(r.ok, false);
	assert.match(r.error, /Stopped before the picture was read/);
	assert.equal(h.requests().length, before, "the message was not sent");
});

test("a companion step whose request fails still ends the step: its frame goes, no stray pointer later (guard)", async (t) => {
	const h = await host(t, { MOCK_FAIL_CHAT: "2" });
	await h.call("new_session", { chatMode: "chat" });
	await h.call("set_model", { provider: "griphub", model: "gemini-3.8-flash" });
	await h.turn("halo");
	await h.call("companion_start");
	const done = h.records.length;
	await h.call("companion_turn", { text: "Tombol mana?", frame });
	await h.until((r) => r.type === "companion_pointer" && h.records.indexOf(r) >= done, 30_000, "the step's end");
	// The next ordinary turn carries no screen and sends no stray pointer.
	const mark = h.records.length;
	const sent = await h.turn("Terima kasih");
	assert.equal(sent.at(-1).images, 0, "no frame left over");
	assert.equal(h.records.slice(mark).filter((r) => r.type === "companion_pointer").length, 0);
});

test("leaving the chat the companion is on ends it there, recorded in that chat", async (t) => {
	const h = await host(t);
	await h.call("new_session", { chatMode: "chat" });
	await h.turn("halo");
	const first = (await h.call("state")).sessionFile;
	await h.call("companion_start");
	await h.call("new_session", { chatMode: "chat" });
	assert.ok(h.records.some((r) => r.type === "companion" && r.event === "stop"), "the app is told");
	const turn = await h.raw("companion_turn", { text: "Lanjut", frame });
	assert.equal(turn.ok, false, "not on in the new chat");
	const old = await h.call("session_read", { path: first });
	assert.ok(JSON.stringify(old).includes("the chat was left"), "the stop is in the chat it was started in");
});
