// griphub-setup.sh, the server/ folder in one script the app carries (Settings > Server agent): it must unpack exactly
// the files bootstrap.sh needs, refuse a copy that was damaged on the way, and work as the one paste the app copies.
import { test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { SERVER_DIR, SERVER_FILES, serverInstaller } from "../server-installer.mjs";

const KEY = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEXAMPLEKEYONEEXAMPLEKEYONEEXAMPLEKEYONE00 griphub-app";

function scratch(t) {
	const dir = mkdtempSync(join(tmpdir(), "gh-installer-"));
	t.after(() => rmSync(dir, { recursive: true, force: true, maxRetries: 10, retryDelay: 100 }));
	return dir;
}

const run = (cmd, args, cwd, env = {}) =>
	spawnSync(cmd, args, { cwd, encoding: "utf8", env: { ...process.env, HOME: cwd, ...env } });

test("it unpacks the server files byte for byte, with their modes, and runs bootstrap.sh with the options given", (t) => {
	const dir = scratch(t);
	writeFileSync(join(dir, "griphub-setup.sh"), serverInstaller(SERVER_DIR, "1.3.0 1700000000000"));
	const r = run("sh", ["griphub-setup.sh", "--dry-run", "--pubkey", KEY, "--address", "agentai.example.com"], dir);
	assert.equal(r.status, 0, r.stderr);
	for (const f of SERVER_FILES) {
		const got = join(dir, "griphub-server", f);
		assert.deepEqual(readFileSync(got), readFileSync(join(SERVER_DIR, f)), f);
		assert.equal(statSync(got).mode & 0o111, statSync(join(SERVER_DIR, f)).mode & 0o111, `${f} keeps its mode`);
	}
	assert.match(r.stdout, /GripHub server files are in/);
	assert.match(r.stdout, /dry run: nothing will be changed/);
	assert.match(r.stdout, /griphub1:[A-Za-z0-9+/=]+/, "bootstrap.sh ran and printed the setup code");
	assert.match(readFileSync(join(dir, "griphub-setup.sh"), "utf8"), /GripHub server setup \(1\.3\.0 1700000000000\)/);
});

test("the one paste the app copies writes the script and runs it", (t) => {
	const dir = scratch(t);
	// What RemoteSetup.setupPaste makes (lib/agent/remote_profile.dart), run the way a terminal runs a paste.
	const paste = `cat > griphub-setup.sh <<'GRIPHUB_SETUP'\n${serverInstaller()}GRIPHUB_SETUP\nsh griphub-setup.sh --dry-run --pubkey '${KEY}'\n`;
	const r = spawnSync("bash", ["-s"], { cwd: dir, input: paste, encoding: "utf8", env: { ...process.env, HOME: dir } });
	assert.equal(r.status, 0, r.stderr);
	assert.match(r.stdout, /griphub1:/);
	assert.deepEqual(readFileSync(join(dir, "griphub-server", "bootstrap.sh")), readFileSync(join(SERVER_DIR, "bootstrap.sh")));
});

test("a copy that lost a character on the way stops before anything runs, and says to copy it again", (t) => {
	const dir = scratch(t);
	const lines = serverInstaller().split("\n");
	// A line in the middle of bootstrap.sh's payload loses one character, as a terminal paste can.
	const start = lines.findIndex((l) => l.startsWith("put bootstrap.sh "));
	lines[start + 20] = lines[start + 20].slice(0, 40) + lines[start + 20].slice(41);
	writeFileSync(join(dir, "griphub-setup.sh"), lines.join("\n"));
	const r = run("sh", ["griphub-setup.sh", "--dry-run", "--pubkey", KEY], dir);
	assert.notEqual(r.status, 0);
	assert.match(r.stderr, /bootstrap\.sh arrived damaged .*copy it from the app again/);
	assert.doesNotMatch(r.stdout, /dry run/, "bootstrap.sh did not run");
});

test("no server file can end its own part of the script early", () => {
	for (const f of SERVER_FILES) {
		const lines = readFileSync(join(SERVER_DIR, f), "utf8").split("\n");
		assert.ok(!lines.includes("GRIPHUB_FILE") && !lines.includes("GRIPHUB_SETUP"), f);
	}
});

test("shellcheck is clean on the generated script", { skip: spawnSync("shellcheck", ["--version"]).status !== 0 && "shellcheck is not installed" }, (t) => {
	const dir = scratch(t);
	writeFileSync(join(dir, "griphub-setup.sh"), serverInstaller());
	const r = spawnSync("shellcheck", [join(dir, "griphub-setup.sh")], { encoding: "utf8" });
	assert.equal(r.status, 0, r.stdout);
});
