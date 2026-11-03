// Automatic server backups (src/autobackup.ts), on real files: what goes in and what stays out, that nothing is
// readable without the phone's key, that a backup is made only when something changed, and what a restore on the
// phone puts where.
import { test } from "node:test";
import assert from "node:assert/strict";
import { createHash, randomBytes } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, readdirSync, rmSync, statSync, utimesSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { bundle, tempDir } from "./helpers.mjs";

// The store key secure.ts reads at import (the server's, from ~/.griphub/env).
process.env.GRIPHUB_STORE_KEY = "11".repeat(32);
const { AutoBackup, backupFiles, decryptBackup, restoreBackup, readManifest } = await bundle("autobackup");
// secure.ts takes the key out of the environment at import; this second copy of it needs it again.
process.env.GRIPHUB_STORE_KEY = "11".repeat(32);
const { writeSecureJson, readSecureJson } = await bundle("secure");

const KEY = "ab".repeat(32);
const SECRET = "ghp_SECRET_TOKEN_123";

function write(root, rel, body = rel) {
	mkdirSync(dirname(join(root, rel)), { recursive: true });
	writeFileSync(join(root, rel), body);
}

/** A server's files: chats, skills, its shell setting, secrets, a project with .git and dependencies, its keys. */
function server(t) {
	const root = tempDir(t, "srv-");
	const home = join(root, "home");
	const agentDir = join(home, ".pi", "agent");
	const workspace = join(home, "workspace");
	write(agentDir, "sessions/--w--/chat.jsonl", `{"type":"session","cwd":"${workspace}/site"}\n{"type":"message","text":"halo ${workspace}/site"}\n`);
	write(agentDir, "skills/web/SKILL.md", "# web");
	write(agentDir, "settings.json", '{"shellPath":"/home/griphub/.griphub/bin/box"}');
	write(agentDir, "griphub/runs.json", JSON.stringify({ schedules: [{ id: "s1", cwd: `${workspace}/site` }] }));
	write(agentDir, "griphub/checkpoints/x/objects/aa", "undo history");
	mkdirSync(join(agentDir, "griphub"), { recursive: true });
	writeSecureJson(join(agentDir, "griphub", "integrations.json"), {
		github: { token: SECRET, login: "rosyid" },
		sshHosts: [],
		settings: { dns: "system", approvalMode: "ask_all", dailyBudget: 25, timeZone: "Etc/GMT-7", projectSearch: { [`${workspace}/site`]: false } },
	});
	writeSecureJson(join(agentDir, "griphub", "custom-providers.json"), [{ id: "griphub", apiKey: "sk-router-key" }]);
	write(workspace, "site/index.html", "<h1>hi</h1>");
	write(workspace, "site/.env", "API=1");
	write(workspace, "site/.git/HEAD", "ref: refs/heads/main\n");
	write(workspace, "site/node_modules/react/index.js", "dependency");
	write(workspace, "site/.venv/bin/python", "dependency");
	write(home, ".ssh/id_ed25519", "PRIVATE KEY");
	write(home, ".ssh/id_ed25519.pub", "ssh-ed25519 AAAA deploy");
	write(home, ".ssh/authorized_keys", "ssh-ed25519 AAAA griphub-app");
	return { root, home, agentDir, workspace };
}

function backups(t, s, extra = {}) {
	return new AutoBackup({
		dir: join(s.home, ".griphub", "backups"),
		configFile: join(s.agentDir, "griphub", "auto-backup.json"),
		agentDir: s.agentDir,
		workspace: s.workspace,
		home: s.home,
		...extra,
	});
}

test("a backup has the data, the secrets, .git and the deploy key; no dependencies, no plaintext", async (t) => {
	const s = server(t);
	const b = backups(t, s);
	assert.equal(await b.tick(), null, "off until the phone gives its key");
	b.configure(KEY);
	const made = await b.tick();
	assert.ok(made);
	assert.equal((statSync(made.path).mode & 0o777).toString(8), "600");
	const raw = readFileSync(made.path);
	assert.equal(raw.subarray(0, 4).toString(), "GHB1");
	for (const plain of [SECRET, "sk-router-key", "PRIVATE KEY", "<h1>hi</h1>", "halo"]) {
		assert.equal(raw.includes(Buffer.from(plain)), false, `${plain} is not readable in the file`);
	}
	const files = backupFiles(made.path, KEY, join(s.root, "plain.zip"));
	const names = [...files.keys()];
	for (const n of ["agent/sessions/--w--/chat.jsonl", "agent/skills/web/SKILL.md", "workspace/site/index.html", "workspace/site/.env", "workspace/site/.git/HEAD", "home/.ssh/id_ed25519", "home/.ssh/id_ed25519.pub", "manifest.json"]) {
		assert.ok(names.includes(n), `${n} is in it`);
	}
	for (const n of names) {
		assert.ok(!/node_modules|\.venv|authorized_keys|checkpoints|backups\//.test(n), `${n} is left out`);
	}
	// Secrets: decrypted with the server's key, inside the encrypted zip.
	const integrations = JSON.parse(files.get("secure/griphub/integrations.json").toString());
	assert.equal(integrations.github.token, SECRET);
	assert.equal(JSON.parse(files.get("secure/griphub/custom-providers.json").toString())[0].apiKey, "sk-router-key");
	assert.ok(!names.includes("agent/griphub/integrations.json"), "never the server-encrypted copy");
	assert.ok(!names.some((n) => n.includes("auto-backup.json")), "never the backup key itself");
	const manifest = JSON.parse(files.get("manifest.json").toString());
	assert.equal(manifest.workspace, s.workspace);
});

test("only when something changed; the newest three are kept; turning it off deletes them", async (t) => {
	const s = server(t);
	let now = 1_000_000;
	const b = backups(t, s, { now: () => now++ });
	b.configure(KEY);
	assert.ok(await b.tick());
	assert.equal(await b.tick(), null, "nothing changed");
	for (let i = 0; i < 4; i++) {
		write(s.workspace, "site/index.html", `<h1>v${i}</h1>`);
		utimesSync(join(s.workspace, "site/index.html"), new Date(), new Date(Date.now() + (i + 1) * 5000));
		assert.ok(await b.tick(), `change ${i} makes one`);
	}
	assert.equal(b.list().length, 3);
	assert.ok(await b.tick(true), "a forced one even without a change");
	b.configure(null);
	assert.equal(b.list().length, 0);
	assert.equal(b.status().enabled, false);
	assert.throws(() => b.configure("short"), /64 hex/);
});

test("another key, or a changed byte, is refused", async (t) => {
	const s = server(t);
	const b = backups(t, s);
	b.configure(KEY);
	const made = await b.tick();
	assert.throws(() => decryptBackup(made.path, "cd".repeat(32), join(s.root, "x.zip")), /another key/);
	assert.equal(existsSync(join(s.root, "x.zip")), false, "nothing half-decrypted is left");
	const raw = readFileSync(made.path);
	raw[100] ^= 1;
	writeFileSync(join(s.root, "bad.ghb"), raw);
	assert.throws(() => decryptBackup(join(s.root, "bad.ghb"), KEY, join(s.root, "y.zip")), /damaged/);
	writeFileSync(join(s.root, "other.bin"), "not a backup at all, just text");
	assert.throws(() => decryptBackup(join(s.root, "other.bin"), KEY, join(s.root, "z.zip")), /not a GripHub server backup/);
});

test("a phone's backups: no secrets in them, the key comes back as a recovery code, and they restore without it all", async (t) => {
	const s = server(t);
	const b = backups(t, s, { noSecrets: true });
	assert.equal(b.recoveryKey(), null, "no key while they are off");
	b.configure(KEY);
	assert.equal(b.recoveryKey(), KEY, "the phone's app shows this once to write down");
	const made = await b.tick();
	assert.ok(made);
	const files = backupFiles(made.path, KEY, join(s.root, "phone-plain.zip"));
	const names = [...files.keys()];
	assert.ok(!names.some((n) => n.startsWith("secure/")), "API keys, tokens and MCP servers stay out");
	assert.ok(!names.includes("agent/griphub/integrations.json"), "nor the machine-encrypted copies");
	for (const n of ["agent/sessions/--w--/chat.jsonl", "agent/skills/web/SKILL.md", "workspace/site/index.html", "home/.ssh/id_ed25519"]) {
		assert.ok(names.includes(n), `${n} is in it`);
	}
	assert.equal(readFileSync(made.path).includes(Buffer.from(SECRET)), false, "no secret readable in the file");

	// Restored on another phone (the point of the recovery code): data back, no secrets to leak, nothing fails on their absence.
	const zip = join(s.root, "phone-restore.zip");
	decryptBackup(made.path, KEY, zip);
	const other = tempDir(t, "other-");
	const to = { agentDir: join(other, "agent"), workspace: join(other, "workspace"), home: join(other, "home") };
	const r = restoreBackup(zip, to);
	assert.ok(r.restored > 0);
	assert.equal(JSON.parse(readFileSync(join(to.agentDir, "sessions/--w--/chat.jsonl"), "utf8").split("\n")[0]).cwd, `${to.workspace}/site`);
	assert.equal(existsSync(join(to.agentDir, "griphub", "integrations.json")), false, "no keys appeared out of nowhere");
});

test("restored on the phone: chats moved to its workspace, secrets kept encrypted, its own settings and SSH key stay", async (t) => {
	const s = server(t);
	const b = backups(t, s);
	b.configure(KEY);
	const made = await b.tick();
	const zip = join(s.root, "restore.zip");
	decryptBackup(made.path, KEY, zip);
	assert.equal(readManifest(zip).workspace, s.workspace);

	const phone = tempDir(t, "phone-");
	const to = { agentDir: join(phone, "agent"), workspace: join(phone, "workspace"), home: join(phone, "home") };
	mkdirSync(join(to.agentDir, "griphub"), { recursive: true });
	writeSecureJson(join(to.agentDir, "griphub", "integrations.json"), { sshHosts: [], settings: { dns: "cloudflare" } });
	write(to.agentDir, "settings.json", '{"shellPath":"/data/linux/shell"}');
	const r = restoreBackup(zip, to);
	assert.ok(r.restored > 0);
	assert.equal(r.keptSshKey, false);

	const chat = readFileSync(join(to.agentDir, "sessions/--w--/chat.jsonl"), "utf8").split("\n");
	assert.equal(JSON.parse(chat[0]).cwd, `${to.workspace}/site`, "the chat's folder is this phone's");
	assert.match(chat[1], new RegExp(s.workspace.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")), "what was said stays as it was");
	assert.equal(JSON.parse(readFileSync(join(to.agentDir, "griphub/runs.json"), "utf8")).schedules[0].cwd, `${to.workspace}/site`);
	assert.equal(readFileSync(join(to.workspace, "site/.git/HEAD"), "utf8"), "ref: refs/heads/main\n");
	assert.equal(readFileSync(join(to.agentDir, "settings.json"), "utf8"), '{"shellPath":"/data/linux/shell"}', "the phone keeps its shell");

	const file = join(to.agentDir, "griphub", "integrations.json");
	assert.ok(readFileSync(file, "utf8").startsWith("enc1:"), "encrypted again on the phone");
	const store = readSecureJson(file, {});
	assert.equal(store.github.token, SECRET);
	assert.equal(store.settings.approvalMode, "ask_all", "the user's choices come along");
	assert.equal(store.settings.dailyBudget, 25);
	assert.equal(store.settings.dns, "cloudflare", "the machine's own settings stay");
	assert.equal("timeZone" in store.settings, false);
	assert.deepEqual(store.settings.projectSearch, { [`${to.workspace}/site`]: false });
	assert.equal(readSecureJson(join(to.agentDir, "griphub", "custom-providers.json"), [])[0].apiKey, "sk-router-key");

	assert.equal(readFileSync(join(to.home, ".ssh/id_ed25519"), "utf8"), "PRIVATE KEY");
	assert.equal((statSync(join(to.home, ".ssh/id_ed25519")).mode & 0o777).toString(8), "600");
	assert.equal(existsSync(join(to.home, ".ssh/authorized_keys")), false);

	// A phone with a deploy key of its own keeps it.
	write(to.home, ".ssh/id_ed25519", "PHONE KEY");
	assert.equal(restoreBackup(zip, to).keptSshKey, true);
	assert.equal(readFileSync(join(to.home, ".ssh/id_ed25519"), "utf8"), "PHONE KEY");
});

test("a store that cannot be read is left out of a backup (it used to be saved as `null`), and restoring a `null` store writes nothing", async (t) => {
	const s = server(t);
	const damaged = join(s.agentDir, "griphub", "custom-providers.json");
	writeFileSync(damaged, readFileSync(damaged).subarray(0, 30)); // cut short
	const b = backups(t, s);
	b.configure(KEY);
	const made = await b.tick();
	const files = backupFiles(made.path, KEY, join(s.root, "plain.zip"));
	assert.ok(!files.has("secure/griphub/custom-providers.json"), "not stored as null");
	assert.ok(files.has("secure/griphub/integrations.json"), "the readable one is");
	const zipPath = join(s.root, "again.zip");
	decryptBackup(made.path, KEY, zipPath);
	const skipped = readManifest(zipPath).skipped;
	assert.ok(skipped.some((x) => x.name === "secure/griphub/custom-providers.json" && /could not be read/.test(x.why)), JSON.stringify(skipped));

	// A backup made before this fix holds `null` for it; restoring must leave the phone's own store alone.
	const phone = tempDir(t, "phone-");
	const to = { agentDir: join(phone, "agent"), workspace: join(phone, "workspace"), home: join(phone, "home") };
	mkdirSync(join(to.agentDir, "griphub"), { recursive: true });
	const mine = join(to.agentDir, "griphub", "custom-providers.json");
	writeSecureJson(mine, [{ id: "griphub", apiKey: "sk-phone" }]);
	const { writeZip } = await bundle("workbench");
	const zip = join(s.root, "nulls.zip");
	writeFileSync(zip, writeZip([{ name: "secure/griphub/custom-providers.json", data: Buffer.from("null") }, { name: "manifest.json", data: Buffer.from("{}") }]));
	restoreBackup(zip, to);
	assert.equal(readSecureJson(mine, [])[0].apiKey, "sk-phone", "the phone's store is untouched");
});

test("the workspace's dot folders and build output stay out of a backup; project files, dot files and .git stay in", async (t) => {
	const s = server(t);
	// What grew a real server's backup from 88 MB to 719 MB: a toolchain in a dot folder, and build caches.
	write(s.workspace, ".toolchains/jdk/lib/modules", "x".repeat(2000));
	write(s.workspace, ".toolchains/android-tools.zip", "z");
	write(s.workspace, "site/.next/cache/x.js", "cache");
	write(s.workspace, "site/.idea/workspace.xml", "ide");
	write(s.workspace, "griphub/build/test_cache/cache.dill", "dill");
	write(s.workspace, "griphub/android/app/build/outputs/app.apk", "apk");
	write(s.workspace, "tiksave/target/debug/deps/a.rlib", "rust");
	write(s.workspace, "site/dist/bundle.js", "bundle");
	// What belongs in it, including look-alikes: a file called build, a folder that only contains the word.
	write(s.workspace, "site/src/build.ts", "export const a = 1;");
	write(s.workspace, "site/src/builder/index.ts", "b");
	write(s.workspace, "site/.gitignore", "dist\n");
	write(s.workspace, "site/sub/.git/HEAD", "ref: refs/heads/dev\n");
	write(s.workspace, "site/vendor/lib.go", "vendored");
	// The agent's own tree is not filtered like this: a dot file or folder there is real data.
	write(s.agentDir, ".state/keep.json", "{}");
	write(s.agentDir, "sessions/build/chat.jsonl", "{}");

	const b = backups(t, s);
	b.configure(KEY);
	const made = await b.tick();
	const names = [...backupFiles(made.path, KEY, join(s.root, "plain.zip")).keys()];
	for (const n of [
		"workspace/site/index.html",
		"workspace/site/.env",
		"workspace/site/.git/HEAD",
		"workspace/site/sub/.git/HEAD",
		"workspace/site/.gitignore",
		"workspace/site/src/build.ts",
		"workspace/site/src/builder/index.ts",
		"workspace/site/vendor/lib.go",
		"agent/.state/keep.json",
		"agent/sessions/build/chat.jsonl",
	]) {
		assert.ok(names.includes(n), `${n} is in it`);
	}
	for (const n of names) {
		assert.ok(!/^workspace\/\.toolchains|\.next|\.idea|\/build\/|\/target\/|\/dist\//.test(n.replace(/^agent\/sessions\/build\//, "")), `${n} is left out`);
	}
});

test("a backup that was cut short is cleaned away once it is old, never one being written or written to lately", async (t) => {
	const s = server(t);
	const b = backups(t, s);
	b.configure(KEY);
	const dir = join(s.home, ".griphub", "backups");
	const hourAgo = (Date.now() - 3_600_000) / 1000;
	const old = join(dir, ".auto-111.ghb.tmp");
	const busy = join(dir, ".auto-222.ghb.tmp");
	const fresh = join(dir, ".auto-333.ghb.tmp");
	const other = join(dir, "notes.tmp");
	for (const f of [old, busy, fresh, other]) write(dir, f.slice(dir.length + 1), "x".repeat(1000));
	for (const f of [old, busy, other]) utimesSync(f, hourAgo, hourAgo);

	b.writing = busy; // the file this process is writing, however still it looks
	b.cleanTmp();
	assert.equal(existsSync(old), false, "an old leftover is removed");
	assert.equal(existsSync(busy), true, "the one being written stays");
	b.writing = null;
	write(dir, ".auto-111.ghb.tmp", "x");
	utimesSync(old, hourAgo, hourAgo);

	await b.tick();
	assert.equal(existsSync(old), false, "an old leftover is removed after a backup");
	assert.equal(existsSync(busy), false, "once nothing is writing it, an old one goes too");
	assert.equal(existsSync(fresh), true, "one written to a moment ago may be another process's");
	assert.equal(existsSync(other), true, "only unfinished backups, not any .tmp");
	assert.equal(readdirSync(dir).filter((n) => /^auto-\d+\.ghb$/.test(n)).length, 1, "the backup itself is untouched");

	// And at start, so a host that was killed mid-backup does not carry the leftover until its next backup.
	write(dir, ".auto-444.ghb.tmp", "x");
	utimesSync(join(dir, ".auto-444.ghb.tmp"), hourAgo, hourAgo);
	b.start();
	b.stop();
	assert.equal(existsSync(join(dir, ".auto-444.ghb.tmp")), false);
	assert.equal(existsSync(fresh), true);
});

// ---------------------------------------------------------------------------
// Incremental (a server's): blobs and snapshots, so the phone fetches only what changed.

const { readSnapshot, readBlob, restoreSnapshot, isSnapshot } = await bundle("autobackup");

/** What the phone does: asks what a snapshot needs, fetches the blobs it lacks into [phone], and the snapshot. */
function fetchTo(b, name, phone) {
	const needs = b.needs(name);
	mkdirSync(join(phone, "blobs"), { recursive: true });
	const have = new Set(existsSync(join(phone, "blobs")) ? readdirSync(join(phone, "blobs")) : []);
	const want = needs.blobs.filter((x) => !have.has(x.id));
	let fetched = 0;
	let answers = 0;
	const parts = new Map();
	let queue = want.map((x) => ({ id: x.id, offset: 0 }));
	while (queue.length) {
		const { chunks } = b.read(queue, 64 * 1024);
		answers++;
		const next = [];
		const done = new Set();
		for (const c of chunks) {
			const data = Buffer.from(c.data, "base64");
			parts.set(c.id, Buffer.concat([parts.get(c.id) ?? Buffer.alloc(0), data]));
			fetched += data.length;
			if (c.offset + data.length < c.size) next.push({ id: c.id, offset: c.offset + data.length });
			else done.add(c.id);
		}
		for (const id of done) writeFileSync(join(phone, "blobs", id), parts.get(id));
		const answered = new Set(chunks.map((c) => c.id));
		queue = [...next, ...queue.filter((q) => !answered.has(q.id))];
	}
	writeFileSync(join(phone, name), Buffer.from(needs.snapshot, "base64"));
	return { fetched, blobs: want.length, answers, total: needs.blobs.length };
}

test("incremental: a second backup stores and sends only what changed", async (t) => {
	const s = server(t);
	write(s.workspace, "site/big.bin", Buffer.alloc(300 * 1024, 7));
	let now = 2_000_000;
	const b = backups(t, s, { incremental: true, now: () => now++ });
	b.configure(KEY);
	const first = await b.tick();
	assert.match(first.name, /^auto-\d+\.ghs$/);
	assert.equal(first.added, first.size, "the first one adds everything it needs");
	const phone = tempDir(t, "phone-");
	const one = fetchTo(b, first.name, phone);
	assert.ok(one.blobs > 5);

	// One file changes: one new blob, and a fresh snapshot that lists everything.
	write(s.workspace, "site/index.html", "<h1>changed</h1>");
	utimesSync(join(s.workspace, "site/index.html"), new Date(), new Date(Date.now() + 5000));
	const second = await b.tick();
	assert.ok(second && second.name !== first.name);
	assert.ok(second.added < 2048, `only the change and the snapshot are new (${second.added} bytes)`);
	assert.ok(second.size > 1024, "its size counts every blob it needs");
	const two = fetchTo(b, second.name, phone);
	assert.equal(two.blobs, 1, "the phone fetches the one changed file");
	assert.ok(two.fetched < 1024, `${two.fetched} bytes fetched`);
	assert.equal(two.total, one.total, "the snapshot still names every file");

	// Restored from the phone's copy: the whole tree, with the change.
	const other = tempDir(t, "restored-");
	const to = { agentDir: join(other, "agent"), workspace: join(other, "workspace"), home: join(other, "home") };
	assert.ok(isSnapshot(join(phone, second.name)));
	const r = restoreSnapshot(join(phone, second.name), KEY, to);
	assert.ok(r.restored > 0);
	assert.equal(readFileSync(join(to.workspace, "site/index.html"), "utf8"), "<h1>changed</h1>");
	assert.equal(readFileSync(join(to.workspace, "site/big.bin")).length, 300 * 1024);
	assert.equal(JSON.parse(readFileSync(join(to.agentDir, "sessions/--w--/chat.jsonl"), "utf8").split("\n")[0]).cwd, `${to.workspace}/site`);
	assert.equal(readSecureJson(join(to.agentDir, "griphub", "integrations.json"), {}).github.token, SECRET);
	// The older snapshot still restores: its blobs are shared, not replaced.
	const older = tempDir(t, "older-");
	const to2 = { agentDir: join(older, "agent"), workspace: join(older, "workspace"), home: join(older, "home") };
	restoreSnapshot(join(phone, first.name), KEY, to2);
	assert.equal(readFileSync(join(to2.workspace, "site/index.html"), "utf8"), "<h1>hi</h1>");
});

test("incremental: an unchanged file is not read again, the same content is stored once, and nothing is readable", async (t) => {
	const s = server(t);
	write(s.workspace, "a/copy1.txt", "same words in two places");
	write(s.workspace, "b/copy2.txt", "same words in two places");
	// A whole second, so putting the same time back is exact: a Date only keeps milliseconds, and writing a
	// sub-millisecond mtime back through one can round it up to the next millisecond (it did on CI).
	const stamp = 1_790_000_000;
	utimesSync(join(s.workspace, "site/index.html"), stamp, stamp);
	let now = 3_000_000;
	const b = backups(t, s, { incremental: true, now: () => now++ });
	b.configure(KEY);
	const first = await b.tick();
	const snap = readSnapshot(first.path, KEY);
	const ids = snap.files.filter((f) => f.name.endsWith("copy1.txt") || f.name.endsWith("copy2.txt")).map((f) => f.id);
	assert.equal(ids.length, 2);
	assert.equal(ids[0], ids[1], "one blob for both");
	for (const n of readdirSync(b.blobsDir)) {
		const raw = readFileSync(join(b.blobsDir, n));
		assert.equal(raw.subarray(0, 4).toString(), "GHO1");
		for (const plain of [SECRET, "sk-router-key", "PRIVATE KEY", "<h1>hi</h1>", "same words"]) {
			assert.equal(raw.includes(Buffer.from(plain)), false, `${plain} is not readable in a blob`);
		}
	}
	assert.equal(readFileSync(first.path).includes(Buffer.from("index.html")), false, "file names are not readable in the snapshot");
	assert.equal(readdirSync(b.blobsDir).includes(createHash("sha256").update("<h1>hi</h1>").digest("hex")), false, "a blob's name says nothing of its content");
	assert.throws(() => readSnapshot(first.path, "cd".repeat(32)), /another key/);

	// The same size and time: taken from the index, without reading (a changed byte under an unchanged time is the
	// one thing that slips by, as with the old fingerprint and as with rsync).
	writeFileSync(join(s.workspace, "site/index.html"), "<h1>HI</h1>");
	utimesSync(join(s.workspace, "site/index.html"), stamp, stamp);
	const again = await b.tick(true);
	const html = (x) => readSnapshot(x.path, KEY).files.find((f) => f.name === "workspace/site/index.html").id;
	assert.equal(html(again), html(first), "not read again");
	// A blob that went missing is written again rather than trusted.
	rmSync(join(b.blobsDir, html(first)));
	const healed = await b.tick(true);
	assert.notEqual(html(healed), html(first), "read again: its content had changed");
	assert.ok(existsSync(join(b.blobsDir, html(healed))));
});

test("incremental: the newest three are kept and the blobs only they needed go; off removes everything", async (t) => {
	const s = server(t);
	let now = 4_000_000;
	const b = backups(t, s, { incremental: true, now: () => now++ });
	b.configure(KEY);
	const made = [];
	for (let i = 0; i < 5; i++) {
		write(s.workspace, "site/index.html", `<h1>version ${i}</h1>`);
		utimesSync(join(s.workspace, "site/index.html"), new Date(), new Date(Date.now() + (i + 1) * 5000));
		made.push(await b.tick());
	}
	assert.deepEqual(b.list().map((x) => x.name), made.slice(2).reverse().map((x) => x.name));
	const live = new Set(b.list().flatMap((x) => readSnapshot(x.path, KEY).files.map((f) => f.id)));
	assert.deepEqual(new Set(readdirSync(b.blobsDir)), live, "only blobs a kept snapshot needs");
	for (const x of b.list()) {
		const other = tempDir(t, "keep-");
		restoreSnapshot(x.path, KEY, { agentDir: join(other, "a"), workspace: join(other, "w"), home: join(other, "h") });
	}
	b.configure(null);
	assert.equal(b.list().length, 0);
	assert.equal(existsSync(b.blobsDir), false);
	assert.equal(existsSync(join(s.home, ".griphub", "backups", "index.json")), false);
});

test("incremental: a server that still has zip backups from before lists both, newest first", async (t) => {
	const s = server(t);
	let now = 5_000_000;
	const old = backups(t, s, { now: () => now++ });
	old.configure(KEY);
	const zip = await old.tick();
	const b = backups(t, s, { incremental: true, now: () => now++ });
	const snap = await b.tick(true);
	assert.deepEqual(b.list().map((x) => x.name), [snap.name, zip.name]);
	assert.equal(isSnapshot(zip.path), false);
	assert.throws(() => b.needs(zip.name), /Not a snapshot/);
});

test("incremental: what the phone asks for is checked, a large blob comes over several answers, a damaged one is refused", async (t) => {
	const s = server(t);
	write(s.workspace, "site/noise.bin", randomBytes(200 * 1024));
	const b = backups(t, s, { incremental: true });
	b.configure(KEY);
	const made = await b.tick();
	assert.throws(() => b.read([{ id: "../auto-backup.json" }]), /Not a blob/);
	assert.throws(() => b.needs("../../etc/passwd"), /Not a snapshot/);
	const phone = tempDir(t, "phone-");
	const got = fetchTo(b, made.name, phone);
	assert.ok(got.answers >= 4, `200 KB in 64 KB answers (${got.answers})`);
	assert.equal(readBlob(join(phone, "blobs"), readSnapshot(join(phone, made.name), KEY).files.find((f) => f.name.endsWith("noise.bin")).id, KEY).length, 200 * 1024);

	// One flipped byte in one blob: the restore stops before writing anything.
	const victim = readdirSync(join(phone, "blobs"))[0];
	const raw = readFileSync(join(phone, "blobs", victim));
	raw[40] ^= 1;
	writeFileSync(join(phone, "blobs", victim), raw);
	const other = tempDir(t, "bad-");
	const to = { agentDir: join(other, "agent"), workspace: join(other, "workspace"), home: join(other, "home") };
	assert.throws(() => restoreSnapshot(join(phone, made.name), KEY, to), /damaged/);
	assert.equal(existsSync(to.workspace), false, "nothing written");
	rmSync(join(phone, "blobs", victim));
	assert.throws(() => restoreSnapshot(join(phone, made.name), KEY, to), /missing/);
});
