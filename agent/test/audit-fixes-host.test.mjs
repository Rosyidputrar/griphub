// Regression tests for the audit's high-priority host findings, in the real host on the mock router:
// - screen companion steps do not climb the smart router's class ("Sudah" again is not "the same request again");
// - Try again after a turn with a picture still sees the picture (vision routing, or a reading for a non-vision model);
// - a memory fact the user deletes is gone from chats that started with it, and chat files keep no memory text.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { host, PNG } from "./router-host.mjs";

const photo = [{ type: "image", data: PNG, mimeType: "image/png" }];
const frame = { data: PNG, mimeType: "image/png", width: 1080, height: 2400 };

function chatFiles(agentDir) {
	const out = [];
	const walk = (dir) => {
		for (const e of readdirSync(dir, { withFileTypes: true })) {
			const p = join(dir, e.name);
			if (e.isDirectory()) walk(p);
			else if (e.name.endsWith(".jsonl")) out.push(readFileSync(p, "utf8"));
		}
	};
	walk(join(agentDir, "sessions"));
	return out.join("\n");
}

async function step(h, text) {
	const done = h.records.length;
	await h.call("companion_turn", { text, frame });
	await h.until((r) => r.type === "agent_done" && h.records.indexOf(r) >= done && !r.retrying, 30_000, "the step");
}

test("companion steps in an automatic chat never climb the class, however often 'Sudah' is said", async (t) => {
	const h = await host(t);
	await h.call("new_session", { chatMode: "chat" });
	await h.call("smart_router_set", { on: true });
	await h.turn("halo");
	await h.call("companion_start");
	for (let i = 0; i < 4; i++) await step(h, "Sudah. Langkah berikutnya?");
	const log = (await h.call("routing_log")).log;
	assert.equal(log.filter((d) => d.kind === "escalate").length, 0, JSON.stringify(log.map((d) => d.kind)));
	assert.equal((await h.call("state")).smartRouter.floor, 0);
	// Each step still went to a model that sees pictures.
	const steps = log.filter((d) => d.kind === "route").slice(1);
	assert.equal(steps.length, 4);
	for (const d of steps) assert.ok(d.why.includes("vision"), JSON.stringify(d));
	// The user's own request is still the one a later resend is measured against.
	await h.call("companion_stop");
	await h.turn("halo");
	assert.equal((await h.call("routing_log")).log.filter((d) => d.kind === "escalate").length, 1, "'halo' again is the same request");
});

test("Try again after a failed turn with a picture goes to a model that sees it", async (t) => {
	const h = await host(t, { MOCK_FAIL_CHAT: "1" });
	await h.call("new_session", { chatMode: "chat" });
	await h.call("smart_router_set", { on: true });
	await h.turn("Apa isi gambar ini?", { images: photo });
	const before = h.requests().length;
	const done = h.records.length;
	await h.call("retry");
	await h.until((r) => r.type === "agent_done" && h.records.indexOf(r) >= done && !r.retrying, 30_000, "the retry");
	const retried = h.requests().slice(before);
	assert.equal(retried.length, 1);
	assert.match(retried[0].model, /^gemini/, "a vision model, not the cheapest text one");
	assert.equal(retried[0].images, 1, "the picture went with it");
	const route = (await h.call("routing_log")).log.filter((d) => d.kind === "route").at(-1);
	assert.ok(route.why.includes("vision"));
});

test("Try again on a non-vision model: the picture is read into text, not silently dropped", async (t) => {
	const h = await host(t, { MOCK_FAIL_CHAT: "1", MOCK_VISION_TEXT: "Sebuah struk, TOTAL 22.800" });
	await h.call("new_session", { chatMode: "chat" });
	// The failed turn went to a vision model (no reading in it); then the user switches to one that cannot see.
	await h.call("set_model", { provider: "griphub", model: "gemini-3.8-flash" });
	await h.turn("Apa isi gambar ini?", { images: photo });
	await h.call("set_model", { provider: "griphub", model: "kimi-k3" });
	const done = h.records.length;
	await h.call("retry");
	await h.until((r) => r.type === "agent_done" && h.records.indexOf(r) >= done && !r.retrying, 30_000, "the retry");
	assert.equal(h.log().filter((x) => x === "vision").length, 1, "one reading");
	const body = h.bodies().at(-1);
	assert.match(body, /Continue where you left off/);
	assert.match(body, /TOTAL 22\.800/);
	assert.equal(h.requests().at(-1).images, 0, "the non-vision model never gets the picture");
});

test("a deleted fact is gone from a chat that started with it; the chat file keeps no memory text", async (t) => {
	const h = await host(t);
	const fact = await h.call("memory_add", { layer: "global", text: "Pengguna alergi kacang tanah" });
	await h.call("memory_add", { layer: "global", text: "Pengguna suka jawaban singkat" });
	await h.call("new_session", { chatMode: "chat" });
	await h.turn("Halo");
	assert.match(h.requests().at(-1).system, /alergi kacang tanah/);
	assert.ok(!chatFiles(h.agentDir).includes("alergi kacang tanah"), "ids only in the chat's file");
	await h.call("memory_remove", { layer: "global", entryId: fact.id });
	await h.turn("Lanjut");
	assert.doesNotMatch(h.requests().at(-1).system, /alergi kacang tanah/, "gone from the very next request");
	assert.match(h.requests().at(-1).system, /jawaban singkat/, "the rest stays");
	const snap = await h.call("memory_snapshot");
	assert.deepEqual(snap.global.map((e) => e.text), ["Pengguna suka jawaban singkat"]);
	// An edit is used as edited.
	const [left] = (await h.call("memory_list", { layer: "global" })).entries;
	await h.call("memory_update", { layer: "global", entryId: left.id, text: "Pengguna suka jawaban sangat singkat" });
	await h.turn("Lagi");
	assert.match(h.requests().at(-1).system, /jawaban sangat singkat/);
});
