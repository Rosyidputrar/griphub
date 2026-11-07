// Agent memory (memory.ts): what may be kept, the Markdown files, saving and replacing, and what a chat starts with.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync, existsSync } from "node:fs";
import { bundle, tempDir } from "./helpers.mjs";

const m = await bundle("memory");

test("secrets and non-facts are refused, with the reason", () => {
	const secrets = [
		"API key saya sk-proj-abcdefghijklmnop1234567890",
		"token github ghp_abcdefghijklmnopqrstuvwxyz0123",
		"github_pat_11ABCDEFG0123456789_abcdefghijklmnop",
		"AWS AKIAIOSFODNN7EXAMPLE",
		"kunci google AIzaSyA-1234567890abcdefghijklmnopqrstu",
		"-----BEGIN OPENSSH PRIVATE KEY----- abc",
		"password saya adalah hunter2!!",
		"kata sandi: rahasia123",
		"login https://user:pa55word@example.com",
		"Bearer abcdefghijklmnopqrstuvwxyz123456",
		"kodenya Xy7Qp2Lm9Rt4Vb8Nc1Zd6Fg3Hj5Kk0Ww",
	];
	for (const s of secrets) assert.match(m.refusal(s) ?? "", /password|key|token/i, s);
	assert.match(m.refusal("x".repeat(500)), /short facts/);
	assert.match(m.refusal("```js\nconst a = 1\n```"), /not code/);
	assert.match(m.refusal("a\nb\nc\nd\ne\nf"), /not code, files or a copy of the chat/);
	for (const ok of ["Pengguna lebih suka TypeScript daripada JavaScript", "Proyek ini memakai Riverpod untuk state", "Nama panggilannya Rosdi"]) {
		assert.equal(m.refusal(ok), null, ok);
	}
});

test("'ingat ini' / 'remember this' at the start is the user's own consent", () => {
	assert.equal(m.rememberThis("Ingat ini: saya alergi kacang"), "saya alergi kacang");
	assert.equal(m.rememberThis("tolong ingat bahwa deploy selalu ke staging dulu"), "deploy selalu ke staging dulu");
	assert.equal(m.rememberThis("Remember this - I use tabs"), "I use tabs");
	assert.equal(m.rememberThis("apakah kamu ingat ini?"), null, "only at the start");
	assert.equal(m.rememberThis("ingat ini"), null, "nothing to keep");
});

test("the files are Markdown a person can read, and read back the same", (t) => {
	const dir = tempDir(t);
	const store = new m.MemoryStore(dir);
	const a = store.add("global", "Pengguna lebih suka TypeScript", { source: "Chat A", sessionId: "s1", now: Date.parse("2026-11-01") });
	store.add("project", "State pakai Riverpod", { project: "/w/app", source: "Chat B", now: Date.parse("2026-11-02") });
	const text = readFileSync(m.memoryFile(dir, "global"), "utf8");
	assert.match(text, /# Ingatan global/);
	assert.match(text, new RegExp(`## ${a.id}\\nPengguna lebih suka TypeScript`));
	assert.match(text, /- sumber: Chat A \(s1\)/);
	assert.match(text, /- dikonfirmasi: 2026-11-01/);
	assert.deepEqual(m.parse(text), store.list("global"));
	assert.equal(store.list("project", "/w/app")[0].text, "State pakai Riverpod");
	assert.deepEqual(store.list("project", "/w/other"), [], "each project its own");
	assert.match(readFileSync(m.memoryFile(dir, "project", "/w/app"), "utf8"), /# Ingatan proyek: \/w\/app/);
});

test("saving, confirming again, replacing with a trace, editing, deleting for real", (t) => {
	const dir = tempDir(t);
	const store = new m.MemoryStore(dir);
	const old = store.add("global", "Editor favorit: Vim", { source: "A", now: Date.parse("2026-11-01") });
	// The same fact again only confirms it.
	const again = store.add("global", "editor favorit: vim", { source: "B", now: Date.parse("2026-11-05") });
	assert.equal(again.id, old.id);
	assert.equal(store.list("global")[0].confirmedAt, "2026-11-05");
	// A contradicting fact replaces the old one: not two facts that disagree, and one line of history.
	const neu = store.add("global", "Editor favorit: Helix", { source: "C", replaces: old.id, now: Date.parse("2026-11-06") });
	const list = store.list("global");
	assert.deepEqual(list.map((e) => e.text), ["Editor favorit: Helix"]);
	assert.equal(neu.replaced.length, 1);
	assert.match(neu.replaced[0], new RegExp(`${old.id} \\(2026-11-06\\): "Editor favorit: Vim"`));
	// Edits are refused like new entries when they hold a secret.
	assert.throws(() => store.update("global", neu.id, "token ghp_abcdefghijklmnopqrstuvwxyz0123"), /token/);
	store.update("global", neu.id, "Editor favorit: Zed");
	assert.equal(store.list("global")[0].text, "Editor favorit: Zed");
	assert.throws(() => store.add("global", "sk-live-abcdefghijklmnopqrstu", { source: "x" }), /API key/);
	// Deleting is real: gone from the file, and the last one takes the file with it.
	assert.equal(store.remove("global", neu.id), true);
	assert.equal(existsSync(m.memoryFile(dir, "global")), false);
	store.add("global", "a", { source: "x" });
	store.add("global", "b", { source: "x" });
	store.clear("global");
	assert.deepEqual(store.list("global"), []);
});

test("a chat starts with the newest confirmed facts that fit the budget, the project's first", () => {
	const e = (id, text, confirmedAt) => ({ id, text, source: "s", createdAt: confirmedAt, confirmedAt, replaced: [] });
	const global = [e("m-0001", "lama", "2026-01-01"), e("m-0002", "baru", "2026-11-01"), e("m-0003", "x".repeat(400), "2026-10-01")];
	const project = [e("m-0004", "keputusan proyek", "2026-09-01")];
	const s = m.snapshot(global, project, "/w/app", 40);
	assert.deepEqual(s.project.map((x) => x.id), ["m-0004"]);
	assert.deepEqual(s.global.map((x) => x.id), ["m-0002", "m-0001"], "newest first; the long one does not fit");
	assert.equal(s.left, 1);
	const prompt = m.snapshotPrompt(s);
	assert.match(prompt, /\[m-0002\] baru/);
	assert.match(prompt, /About this project \(\/w\/app\)/);
	assert.match(prompt, /remember tool/);
	assert.equal(m.snapshotPrompt(m.snapshot([], [], null)), "", "nothing remembered, nothing said");
});
