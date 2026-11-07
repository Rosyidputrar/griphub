// Screen companion in the real host, on the mock router (Fitur 5): the frame reaches the model for its request only
// and is never in the chat's file (nor is the screen's text); a secure screen sends no picture and is said to be
// unseeable; a model that cannot see pictures is refused; starting and stopping are recorded in the chat; after Stop,
// no companion turn can run.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { host, PNG } from "./router-host.mjs";

/** Every line of every chat file of this host. */
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

const frame = { data: PNG, mimeType: "image/png", width: 1080, height: 2400 };
const tree = [
	{ id: "n1", text: "Transfer", x: 40, y: 1800, w: 300, h: 120 },
	{ id: "n2", text: "Pesan rahasia dari Budi", x: 40, y: 400, w: 900, h: 80 },
];

test("a step: the model sees this screen once; the chat's file keeps neither the picture nor the screen's text", async (t) => {
	const h = await host(t, { MOCK_TEXT: "Ketuk tombol Transfer di bawah.\nSOROT: #n1" });
	await h.call("new_session", { chatMode: "chat" });
	await h.call("set_model", { provider: "griphub", model: "gemini-3.8-flash" });
	await h.call("companion_start");
	const done = h.records.length;
	await h.call("companion_turn", { text: "Bagaimana cara transfer?", frame, tree });
	await h.until((r) => r.type === "agent_done" && h.records.indexOf(r) >= done && !r.retrying, 30_000, "the step");
	const pointed = await h.until((r) => r.type === "companion_pointer", 10_000, "the pointer");
	assert.deepEqual(pointed.pointer, { id: "n1" });
	const req = h.requests().at(-1);
	assert.equal(req.model, "gemini-3.8-flash");
	assert.equal(req.images, 1, "the frame went with the request");
	const body = h.bodies().at(-1);
	assert.match(body, /Pendamping layar/);
	assert.match(body, /Pesan rahasia dari Budi/, "the screen's elements went with it too");
	// The chat's file: the step's words, never the picture or the screen's text.
	const files = chatFiles(h.agentDir);
	assert.ok(!files.includes(PNG), "no frame in the chat's file");
	assert.ok(!files.includes("Pesan rahasia dari Budi"), "no screen text in the chat's file");
	assert.match(files, /Screen companion started by the user/);
	// Stopped: recorded, and no further step can run.
	await h.call("companion_stop");
	assert.match(chatFiles(h.agentDir), /Screen companion stopped by the user/);
	const after = await h.raw("companion_turn", { text: "lanjut", frame });
	assert.equal(after.ok, false);
	assert.match(after.error, /not on in this chat/);
	assert.ok(h.records.some((r) => r.type === "companion" && r.event === "stop"));
});

test("a secure screen: no picture is sent, and the model is told it cannot be seen", async (t) => {
	const h = await host(t);
	await h.call("new_session", { chatMode: "chat" });
	await h.call("set_model", { provider: "griphub", model: "gemini-3.8-flash" });
	await h.call("companion_start");
	const done = h.records.length;
	await h.call("companion_turn", { text: "Kenapa ini tidak bisa?", secure: true });
	await h.until((r) => r.type === "agent_done" && h.records.indexOf(r) >= done && !r.retrying, 30_000, "the step");
	assert.equal(h.requests().at(-1).images, 0);
	assert.match(h.bodies().at(-1), /cannot be seen/);
	assert.match(h.bodies().at(-1), /Do not guess what is on it/);
});

test("a model that cannot see pictures is refused, plainly; nothing is sent", async (t) => {
	const h = await host(t);
	await h.call("new_session", { chatMode: "chat" });
	await h.call("companion_start");
	const before = h.requests().length;
	const r = await h.raw("companion_turn", { text: "Bantu aku", frame });
	assert.equal(r.ok, false);
	assert.match(r.error, /needs a model that can see pictures/);
	assert.equal(h.requests().length, before);
});

test("the frame is for one request: the next ordinary message carries no picture", async (t) => {
	const h = await host(t);
	await h.call("new_session", { chatMode: "chat" });
	await h.call("set_model", { provider: "griphub", model: "gemini-3.8-flash" });
	await h.call("companion_start");
	const done = h.records.length;
	await h.call("companion_turn", { text: "Apa ini?", frame });
	await h.until((r) => r.type === "agent_done" && h.records.indexOf(r) >= done && !r.retrying, 30_000, "the step");
	await h.call("companion_stop");
	const next = await h.turn("Terima kasih");
	assert.equal(next.at(-1).images, 0, "the frame was dropped after its request");
});
