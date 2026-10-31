// The host's state files (secure.ts, state.ts). A save used to be writeFileSync (empty the file, then fill it), and a file
// that could not be read was taken for an empty one: a host killed mid-save, or started with another key, came up without
// its sign-ins and settings, said nothing, and the next save wrote that over what was left. These tests kill a process in
// the middle of saving, cut a store short, change its key, and take the key away.
import { test, after } from "node:test";
import assert from "node:assert/strict";
import { createCipheriv, randomBytes } from "node:crypto";
import { spawn, spawnSync } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, statSync, truncateSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { build } from "esbuild";

const here = dirname(fileURLToPath(import.meta.url));
const KEY = "ab".repeat(32);
const OTHER_KEY = "cd".repeat(32);

mkdirSync(join(here, "..", "build"), { recursive: true });
const dir = mkdtempSync(join(here, "..", "build", "store-"));
after(() => rmSync(dir, { recursive: true, force: true }));
// secure.ts reads its key from the environment once, at import, so every case that needs another key (or none) is a child
// process. One bundle holds secure.ts and state.ts, so they share the list of problems the way they do in the host.
const entry = join(dir, "entry.ts");
writeFileSync(entry, `export * from ${JSON.stringify(join(here, "..", "src", "secure.ts"))};\nexport * from ${JSON.stringify(join(here, "..", "src", "state.ts"))};\n`);
const store = join(dir, "store.mjs");
await build({ entryPoints: [entry], outfile: store, bundle: true, platform: "node", format: "esm", logLevel: "error" });
process.env.GRIPHUB_STORE_KEY = KEY;
const secure = await import(store);

let n = 0;
const fresh = () => {
	const d = join(dir, `t${++n}`);
	mkdirSync(d, { recursive: true });
	return d;
};
const J = JSON.stringify;
const corrupt = (d) => readdirSync(d).filter((f) => f.includes(".corrupt-"));

/** Encrypts [value] the way writeSecureJson does, with [keyHex]: a store written by another install. */
function encryptWith(keyHex, value) {
	const iv = randomBytes(12);
	const c = createCipheriv("aes-256-gcm", Buffer.from(keyHex, "hex"), iv);
	const ct = Buffer.concat([c.update(JSON.stringify(value), "utf8"), c.final()]);
	return "enc1:" + Buffer.concat([iv, c.getAuthTag(), ct]).toString("base64");
}

/** Runs [body] (with `store` imported) in a child process, with [key] as the store key or none. */
function child(body, { key = KEY } = {}) {
	const file = join(dir, `child-${++n}.mjs`);
	writeFileSync(file, `import * as store from ${J(store)};\nconst problems = [];\nstore.onStoreProblem((p) => problems.push(p));\n${body}\n`);
	const env = { ...process.env };
	delete env.GRIPHUB_STORE_KEY;
	if (key) env.GRIPHUB_STORE_KEY = key;
	const r = spawnSync(process.execPath, [file], { env, encoding: "utf8", timeout: 30_000 });
	assert.equal(r.status, 0, r.stderr);
	return r.stdout.trim() ? JSON.parse(r.stdout.trim().split("\n").pop()) : null;
}

test("a save is whole or not at all: a process killed in the middle of saving never leaves half a file", async () => {
	const file = join(fresh(), "store.json");
	const writer = join(dir, "writer.mjs");
	writeFileSync(
		writer,
		`import { writeSecureJson } from ${J(store)};
const pad = "x".repeat(8_000_000); // large, so that a save takes long enough to be caught in the middle
for (let i = 0; ; i++) { writeSecureJson(${J(file)}, { i, pad }); if (i === 0) console.log("first"); }`,
	);
	for (let round = 0; round < 8; round++) {
		const p = spawn(process.execPath, [writer], { env: { ...process.env, GRIPHUB_STORE_KEY: KEY }, stdio: ["ignore", "pipe", "ignore"] });
		await new Promise((r) => p.stdout.once("data", r)); // the first save is done
		await new Promise((r) => setTimeout(r, 40 + round * 23)); // then killed at a different moment each round
		p.kill("SIGKILL");
		await new Promise((r) => p.once("exit", r));
		const out = child(`const v = store.readSecureJson(${J(file)}, "UNREADABLE"); console.log(JSON.stringify(v === "UNREADABLE" ? v : "ok " + v.i));`);
		assert.match(out, /^ok \d+/, `round ${round}`);
		assert.equal(corrupt(dirname(file)).length, 0, "nothing had to be set aside");
	}
});

test("a save leaves no temporary file behind and the store private", () => {
	const d = fresh();
	const file = join(d, "store.json");
	secure.writeSecureJson(file, { a: 1 });
	secure.writeSecureJson(file, { a: 2 });
	assert.deepEqual(readdirSync(d).sort(), ["store.json", "store.json.bak"]);
	assert.equal(statSync(file).mode & 0o777, 0o600);
	assert.equal(statSync(file + ".bak").mode & 0o777, 0o600, "the copy holds the same secrets");
	assert.deepEqual(secure.readSecureJson(file, {}), { a: 2 });
});

test("a store cut short is not an empty one: the last good copy is loaded, the damaged file is kept, and it is reported", () => {
	const d = fresh();
	const file = join(d, "store.json");
	secure.writeSecureJson(file, { tokens: ["one"] });
	secure.writeSecureJson(file, { tokens: ["one", "two"] }); // the copy now holds the first
	truncateSync(file, Math.floor(statSync(file).size / 2));
	const damaged = readFileSync(file);
	const out = child(`const v = store.readSecureJson(${J(file)}, {}); console.log(JSON.stringify({ v, problems, text: problems.map(store.storeProblemMessage) }));`);
	assert.deepEqual(out.v, { tokens: ["one"] }, "the copy, not {}");
	assert.equal(out.problems.length, 1);
	assert.equal(out.problems[0].kind, "recovered");
	assert.match(out.text[0], /store\.json was damaged, so the last good copy was loaded/);
	const kept = corrupt(d);
	assert.equal(kept.length, 1, "the damaged file was kept");
	assert.deepEqual(readFileSync(join(d, kept[0])), damaged, "byte for byte");
	assert.deepEqual(secure.readSecureJson(file, {}), { tokens: ["one"] }, "and it is the store again");
});

test("with no last good copy, an unreadable store starts empty but is set aside and reported, and the first save does not destroy it", () => {
	const d = fresh();
	const file = join(d, "store.json");
	writeFileSync(file, encryptWith(KEY, { github: "token" }).slice(0, 60)); // cut short
	const before = readFileSync(file);
	const out = child(`console.log(JSON.stringify({ v: store.readSecureJson(${J(file)}, { empty: true }), problems }));`);
	assert.deepEqual(out.v, { empty: true });
	assert.equal(out.problems[0].kind, "quarantined");
	const kept = corrupt(d);
	assert.equal(kept.length, 1);
	assert.deepEqual(readFileSync(join(d, kept[0])), before);
	assert.ok(!existsSync(file), "the name is free for the new store");
	secure.writeSecureJson(file, { fresh: 1 }); // what the first save does
	assert.deepEqual(readFileSync(join(d, kept[0])), before, "the old one is still there after it");
});

test("a store saved with another key is set aside, not overwritten, and reported", () => {
	const d = fresh();
	const file = join(d, "store.json");
	writeFileSync(file, encryptWith(OTHER_KEY, { github: "token" }));
	const before = readFileSync(file);
	const out = child(`console.log(JSON.stringify({ v: store.readSecureJson(${J(file)}, {}), problems }));`);
	assert.deepEqual(out.v, {});
	assert.equal(out.problems[0].kind, "quarantined");
	const kept = corrupt(d);
	assert.equal(kept.length, 1);
	assert.deepEqual(readFileSync(join(d, kept[0])), before);
});

test("a store that waits for a key (none given) is left exactly as it is, and nothing can be saved over it", () => {
	const d = fresh();
	const file = join(d, "store.json");
	writeFileSync(file, encryptWith(KEY, { github: "token" }));
	const before = readFileSync(file);
	const out = child(
		`const v = store.readSecureJson(${J(file)}, { empty: true });
		let refused = false;
		try { store.writeSecureJson(${J(file)}, { empty: true }); } catch { refused = true; }
		console.log(JSON.stringify({ v, refused, problems }));`,
		{ key: null },
	);
	assert.deepEqual(out.v, { empty: true });
	assert.equal(out.refused, true);
	assert.equal(out.problems[0].kind, "locked");
	assert.deepEqual(readdirSync(d), ["store.json"]);
	assert.deepEqual(readFileSync(file), before);
});

test("a store of the wrong shape is not taken for the right one", () => {
	const d = fresh();
	const file = join(d, "mcp.json");
	secure.writeSecureJson(file, { not: "a list" });
	const out = child(`console.log(JSON.stringify({ v: store.readSecureJson(${J(file)}, [], Array.isArray), problems }));`);
	assert.deepEqual(out.v, []);
	assert.equal(out.problems.length, 1);
	assert.equal(corrupt(d).length, 1, "set aside, so the next save keeps it");
});

test("`null` is never a store: it cannot be written, and one found is not loaded (a backup of an unreadable store held it)", () => {
	const d = fresh();
	const file = join(d, "providers.json");
	assert.throws(() => secure.writeSecureJson(file, null), /Refusing to write an empty store/);
	assert.throws(() => secure.writeSecureJson(file, undefined));
	assert.ok(!existsSync(file));
	writeFileSync(file, encryptWith(KEY, null));
	const out = child(`console.log(JSON.stringify({ v: store.readSecureJson(${J(file)}, [], Array.isArray) }));`);
	assert.deepEqual(out.v, []);
	assert.equal(corrupt(d).length, 1);
});

test("a damaged file never replaces the last good copy", () => {
	const d = fresh();
	const file = join(d, "store.json");
	secure.writeSecureJson(file, { v: 1 });
	secure.writeSecureJson(file, { v: 2 }); // the copy: 1
	writeFileSync(file, "enc1:garbage");
	secure.writeSecureJson(file, { v: 3 }); // the file in place is damaged: the copy must stay the good one
	assert.deepEqual(secure.readSecureJsonStrict(file + ".bak"), { v: 1 });
	assert.deepEqual(secure.readSecureJson(file, {}), { v: 3 });
});

test("a plain (not encrypted) state file gets the same care: runs.json cut short is set aside and its last copy used", () => {
	const d = fresh();
	const file = join(d, "runs.json");
	const reader = `const { loadStore, keepBackup, atomicWrite, readJsonFile, isObject } = store;`;
	child(`${reader}
		for (const text of ['{"runs":[1]}', '{"runs":[1,2],"schedules":[{"id":"s"}]}']) { keepBackup(${J(file)}, readJsonFile, isObject); atomicWrite(${J(file)}, text); }`);
	truncateSync(file, 10);
	const out = child(`${reader}
		const v = loadStore(${J(file)}, readJsonFile, null, isObject);
		console.log(JSON.stringify({ v, problems }));`);
	assert.deepEqual(out.v, { runs: [1] });
	assert.equal(out.problems[0].kind, "recovered");
	assert.equal(corrupt(d).length, 1);
});

test("only the newest few set-aside files are kept", () => {
	const d = fresh();
	const file = join(d, "store.json");
	for (let i = 0; i < 6; i++) {
		writeFileSync(file, `{ broken ${i}`);
		child(`store.readSecureJson(${J(file)}, {});`);
		// timestamps are milliseconds: two within one would share a name
		Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 5);
	}
	assert.equal(corrupt(d).length, 3);
});

test("problems reach a listener that starts late, and the message says what happened and what is kept", () => {
	const d = fresh();
	const a = join(d, "a.json");
	writeFileSync(a, "{ broken");
	const out = child(`
		store.onStoreProblem(null);
		store.readSecureJson(${J(a)}, {}); // found before anybody listens
		const got = [];
		store.onStoreProblem((p) => got.push(store.storeProblemMessage(p)));
		console.log(JSON.stringify(got));
	`);
	assert.equal(out.length, 1);
	assert.match(out[0], /a\.json could not be read .* set aside as a\.json\.corrupt-\d+ and started empty/);
});
