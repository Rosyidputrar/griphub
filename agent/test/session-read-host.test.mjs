// Browsing other chats while one works (Fitur 8), in the real host on the mock router: another chat is read from its
// file while chat A's turn runs, A is not disturbed and ends whole, A stays the one chat at work (opening another is
// still refused mid-turn), and nothing outside this host's chat files can be read this way.
import { test } from "node:test";
import assert from "node:assert/strict";
import { existsSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { host } from "./router-host.mjs";

test("chat B is read while chat A works; A goes on to the end and stays the one at work", async (t) => {
	const h = await host(t, { MOCK_TEXT: "Bagian satu." });
	// Chat B, finished earlier.
	const b = await h.call("new_session", { chatMode: "chat" });
	await h.turn("Ini chat B");
	const bFile = (await h.call("state")).sessionFile;
	assert.ok(bFile && b);
	// Chat A: its reply is held open (the mock streams, then waits for the release file).
	const release = join(h.dir, "release");
	rmSync(release);
	await h.call("new_session", { chatMode: "chat" });
	const aState = await h.call("state");
	const done = h.records.length;
	await h.call("prompt", { text: "Tugas panjang di A" });
	await new Promise((r) => setTimeout(r, 300));
	assert.equal((await h.call("state")).isStreaming, true, "A is working");

	// B is read without opening it.
	const read = await h.call("session_read", { path: bFile });
	assert.equal(read.chatMode, "chat");
	assert.deepEqual(read.messages.map((m) => m.role), ["user", "assistant"]);
	assert.match(JSON.stringify(read.messages[0].content), /Ini chat B/);
	assert.ok(read.messages[1].griphubCost, "the reply carries its cost, as in the open chat");
	// The open chat is still A, still working.
	const during = await h.call("state");
	assert.equal(during.sessionId, aState.sessionId);
	assert.equal(during.isStreaming, true);
	// Opening B for real is still refused while A works: never two chats at work.
	const open = await h.raw("open_session", { path: bFile });
	assert.equal(open.ok, false);
	assert.match(open.error, /still working/);

	// A ends, whole.
	writeFileSync(release, "");
	await h.until((r) => r.type === "agent_done" && h.records.indexOf(r) >= done && !r.retrying, 30_000, "A's end");
	const messages = await h.call("messages");
	const reply = messages.findLast((m) => m.role === "assistant");
	assert.match(JSON.stringify(reply.content), /Bagian satu\. Selesai\./, "the whole reply, not cut off");
	// Now B can be opened.
	assert.equal((await h.call("open_session", { path: bFile })).sessionId, read.sessionId);
});

test("only this host's chat files can be read", async (t) => {
	const h = await host(t);
	for (const path of ["/etc/passwd", join(h.agentDir, "settings.json"), join(h.agentDir, "sessions", "..", "auth.json")]) {
		const r = await h.raw("session_read", { path });
		assert.equal(r.ok, false, path);
		assert.match(r.error, /Not a chat of this agent/);
	}
	const gone = await h.raw("session_read", { path: join(h.agentDir, "sessions", "x", "gone.jsonl") });
	assert.equal(gone.ok, false);
	assert.match(gone.error, /no longer exists/);
	assert.equal(existsSync(join(h.agentDir, "sessions", "x", "gone.jsonl")), false, "reading creates nothing");
});
