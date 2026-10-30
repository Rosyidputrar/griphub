// Automatic server backups (src/autobackup.ts), on real files: what goes in and what stays out, that nothing is
// readable without the phone's key, that a backup is made only when something changed, and what a restore on the
// phone puts where.
import { test } from "node:test";
import assert from "node:assert/strict";
import { existsSync, mkdirSync, readFileSync, statSync, utimesSync, writeFileSync } from "node:fs";
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
