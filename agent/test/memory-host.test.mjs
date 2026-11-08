// Agent memory in the real host, on the mock router (Fitur 3 kriteria a-d): a fact the user saves in chat A is in what
// chat B starts with, without being said again; a deleted fact is gone from the next chat's start (and from the
// snapshot the user can see); the agent's proposals are only proposals until the user decides; a key-like text is
// refused with the reason; "ingat ini" keeps a fact at once; a replacing fact leaves no contradiction behind.
import { test } from "node:test";
import assert from "node:assert/strict";
import { host } from "./router-host.mjs";

const remember = (args) => JSON.stringify({ name: "remember", arguments: args });

test("a fact saved in chat A is what chat B starts with; deleted, it is gone from the next start", async (t) => {
	const h = await host(t, { MOCK_TOOL: remember({ text: "Pengguna lebih suka jawaban singkat dalam bahasa Indonesia", layer: "global" }) });
	await h.call("new_session", { chatMode: "chat" });
	await h.turn("Jawab singkat saja ya, aku lebih suka begitu");
	// The proposal is a proposal: nothing is kept yet.
	const proposed = h.records.find((r) => r.type === "memory_proposal");
	assert.equal(proposed.proposal.status, "pending");
	assert.deepEqual((await h.call("memory_list", { layer: "global" })).entries, []);
	// The user saves it from the card.
	const saved = await h.call("memory_decide", { proposalId: proposed.proposal.id, action: "save" });
	assert.equal(saved.status, "saved");
	const [entry] = (await h.call("memory_list", { layer: "global" })).entries;
	assert.equal(entry.text, "Pengguna lebih suka jawaban singkat dalam bahasa Indonesia");

	// Chat B: the fact is in its system prompt from the first request, and in what the user can see it started with.
	await h.call("new_session", { chatMode: "chat" });
	await h.turn("Apa itu fotosintesis?");
	assert.match(h.requests().at(-1).system, /Pengguna lebih suka jawaban singkat/);
	const snapB = await h.call("memory_snapshot");
	assert.deepEqual(snapB.global.map((e) => e.text), ["Pengguna lebih suka jawaban singkat dalam bahasa Indonesia"]);

	// Deleted: chat C starts without it.
	assert.equal((await h.call("memory_remove", { layer: "global", entryId: entry.id })).removed, true);
	await h.call("new_session", { chatMode: "chat" });
	await h.turn("Halo lagi");
	assert.doesNotMatch(h.requests().at(-1).system, /jawaban singkat/);
	assert.deepEqual((await h.call("memory_snapshot")).global, []);
});

test("a refused proposal is not kept; an edited one keeps the user's words", async (t) => {
	const h = await host(t, { MOCK_TOOL: remember({ text: "Deploy ke staging dulu", layer: "project" }) });
	await h.call("new_session", { cwd: `${h.ws}` });
	await h.turn("Biasakan deploy ke staging dulu");
	const p1 = h.records.filter((r) => r.type === "memory_proposal")[0].proposal;
	assert.equal(p1.layer, "global", "the workspace itself is no project: a project fact needs a project folder");
	await h.call("memory_decide", { proposalId: p1.id, action: "reject" });
	assert.deepEqual((await h.call("memory_list", { layer: "global" })).entries, []);
	await h.turn("Sekali lagi");
	const p2 = h.records.filter((r) => r.type === "memory_proposal" && r.proposal.status === "pending").at(-1).proposal;
	await h.call("memory_decide", { proposalId: p2.id, action: "save", text: "Deploy selalu ke staging sebelum production" });
	assert.equal((await h.call("memory_list", { layer: "global" })).entries[0].text, "Deploy selalu ke staging sebelum production");
	// A decided card stays decided.
	assert.equal((await h.call("memory_proposals", { ids: [p1.id, p2.id] }))[p1.id].status, "rejected");
});

test("a key-like text is refused with the reason, whether the agent proposes it or the user says 'ingat ini'", async (t) => {
	const h = await host(t, { MOCK_TOOL: remember({ text: "API key OpenRouter: sk-or-v1-abcdefghijklmnopqrstuvwx", layer: "global" }) });
	await h.call("new_session", { chatMode: "chat" });
	await h.turn("Simpan key ini");
	assert.equal(h.records.filter((r) => r.type === "memory_proposal").length, 0, "no card for a secret");
	const messages = await h.call("messages");
	const result = messages.find((m) => m.role === "toolResult" && m.toolName === "remember");
	assert.match(JSON.stringify(result.content), /Not proposed: This looks like an API key/);
	await h.call("prompt", { text: "Ingat ini: password wifi kantor adalah Merdeka1945!" });
	const refused = await h.until((r) => r.type === "memory_refused");
	assert.match(refused.reason, /password or key/);
	assert.deepEqual((await h.call("memory_list", { layer: "global" })).entries, []);
});

test("'ingat ini' keeps the fact at once; a proposal naming an unknown entry replaces nothing", async (t) => {
	const h = await host(t, { MOCK_TOOL: remember({ text: "Aku sekarang pakai editor Helix", layer: "global", replaces: "m-00000000" }) });
	await h.call("new_session", { chatMode: "chat" });
	await h.turn("Ingat ini: aku pakai editor Vim");
	const saved = h.records.find((r) => r.type === "memory_saved");
	assert.equal(saved.entry.text, "aku pakai editor Vim");
	const p = h.records.find((r) => r.type === "memory_proposal").proposal;
	assert.equal(p.replaces, null);
	await h.call("memory_decide", { proposalId: p.id, action: "save" });
	const list = (await h.call("memory_list", { layer: "global" })).entries.map((e) => e.text).sort();
	assert.deepEqual(list, ["Aku sekarang pakai editor Helix", "aku pakai editor Vim"]);
});

test("a project's memory: proposed in a project chat, kept for that folder, started with there only", async (t) => {
	const h = await host(t, { MOCK_TOOL: remember({ text: "Proyek ini memakai Riverpod", layer: "project" }) });
	const { mkdirSync } = await import("node:fs");
	const app = `${h.ws}/app`;
	mkdirSync(app, { recursive: true });
	await h.call("new_session", { cwd: app });
	await h.turn("Kita pakai Riverpod ya");
	const p = h.records.find((r) => r.type === "memory_proposal").proposal;
	assert.equal(p.layer, "project");
	assert.equal(p.project, app);
	await h.call("memory_decide", { proposalId: p.id, action: "save" });
	assert.equal((await h.call("memory_list", { layer: "project", project: app })).entries[0].text, "Proyek ini memakai Riverpod");
	assert.deepEqual((await h.call("memory_list", { layer: "global" })).entries, []);
	await h.call("new_session", { cwd: app });
	await h.turn("Lanjut");
	assert.match(h.requests().at(-1).system, /About this project .*\n- \[m-[0-9a-f]+\] Proyek ini memakai Riverpod/);
	await h.call("new_session", { chatMode: "chat" });
	await h.turn("Halo");
	assert.doesNotMatch(h.requests().at(-1).system, /Riverpod/, "a plain chat starts with the global layer only");
});

test("an answer to a proposal that is neither save nor reject saves nothing", async (t) => {
	const h = await host(t, { MOCK_TOOL: remember({ text: "Pengguna suka kopi hitam", layer: "global" }) });
	await h.call("new_session", { chatMode: "chat" });
	await h.turn("Aku suka kopi hitam");
	const p = h.records.find((r) => r.type === "memory_proposal").proposal;
	for (const action of ["maybe", undefined, "SAVE", ""]) {
		const r = await h.raw("memory_decide", { proposalId: p.id, ...(action === undefined ? {} : { action }) });
		assert.equal(r.ok, false, `action ${action}`);
	}
	assert.deepEqual((await h.call("memory_list", { layer: "global" })).entries, []);
	assert.equal((await h.call("memory_proposals", { ids: [p.id] }))[p.id].status, "pending", "still the user's to answer");
});
