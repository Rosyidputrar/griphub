// The server/ scripts and the host must agree on names and paths: the account's folders, the unit, the socket, the
// environment the unit sets and the host reads, the box's image. A rename on one side alone would only show up on a
// real server. Also checks bootstrap.sh's input checks and its plan (--dry-run needs no root and changes nothing).
import { test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { readFileSync, statSync } from "node:fs";
import { fileURLToPath } from "node:url";

const server = (f) => fileURLToPath(new URL(`../../server/${f}`, import.meta.url));
const src = (f) => readFileSync(fileURLToPath(new URL(`../src/${f}`, import.meta.url)), "utf8");
const BOOTSTRAP = server("bootstrap.sh");
const UNIT = readFileSync(server("griphub-hostd.service"), "utf8");
const BOX = readFileSync(server("box/box"), "utf8");
const HOST = src("host.ts");
const KEY = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEXAMPLEKEYONEEXAMPLEKEYONEEXAMPLEKEYONE00 griphub-app";

const bootstrap = (...args) => spawnSync("bash", [BOOTSTRAP, ...args], { encoding: "utf8" });

test("the scripts are executable", () => {
	for (const f of ["bootstrap.sh", "field-report.sh", "griphub-attach", "box/box", "test/bootstrap-in-container.sh", "test/bootstrap-inner.sh"]) {
		assert.ok(statSync(server(f)).mode & 0o100, `${f} is executable`);
	}
});

test("the unit starts the host where the bootstrap and the app put it, with the settings the host reads", () => {
	assert.match(UNIT, /^ConditionPathExists=%h\/\.griphub\/host\/host\.mjs$/m);
	assert.match(UNIT, /^ExecStart=\/usr\/local\/bin\/node %h\/\.griphub\/host\/host\.mjs --listen %h\/\.griphub\/host\.sock$/m);
	assert.match(UNIT, /^EnvironmentFile=%h\/\.griphub\/env$/m);
	assert.match(UNIT, /^Environment=PATH=%h\/\.griphub\/bin:/m, "box and griphub-attach on PATH");
	// Every GRIPHUB_ variable the unit sets is one the host (or the box launcher it starts) reads.
	const set = [...UNIT.matchAll(/^Environment=(GRIPHUB_\w+)=/gm)].map((m) => m[1]);
	assert.ok(set.length >= 4);
	for (const name of set) assert.ok(HOST.includes(name) || BOX.includes(name), `${name} is read somewhere`);
	assert.match(UNIT, /^Environment=GRIPHUB_MODE=server$/m);
	// The store key: bootstrap writes it under the name secure.ts reads.
	assert.match(readFileSync(BOOTSTRAP, "utf8"), /GRIPHUB_STORE_KEY=/);
	assert.match(src("secure.ts"), /process\.env\.GRIPHUB_STORE_KEY/);
	// Long enough for the host to stop its subagents (5 s) before systemd kills it.
	assert.ok(Number(/^TimeoutStopSec=(\d+)$/m.exec(UNIT)[1]) > 5);
});

test("the host, the attach program and the box use the same folder, socket and container names", () => {
	assert.match(HOST, /join\(process\.env\.HOME \?\? agentDir, "\.griphub"\)/);
	assert.match(HOST, /join\(griphubDir, "bin", "box"\)/);
	assert.match(readFileSync(server("griphub-attach"), "utf8"), /"\.griphub", "host\.sock"/);
	assert.match(BOX, /GRIPHUB_DIR=\$\{GRIPHUB_DIR:-\$HOME_DIR\/\.griphub\}/);
	assert.match(BOX, /WS=\$\{GRIPHUB_WORKSPACE:-/);
	const podmanbox = src("podmanbox.ts");
	assert.match(BOX, /IMAGE=\$\{GRIPHUB_BOX_IMAGE:-localhost\/griphub-box\}/);
	assert.match(podmanbox, /"localhost\/griphub-box"/);
	assert.match(BOX, /NAME=\$\{GRIPHUB_BOX_NAME:-griphub-box\}/);
	assert.match(podmanbox, /"griphub-box"/);
	assert.match(readFileSync(BOOTSTRAP, "utf8"), /podman build -t localhost\/griphub-box/);
});

test("bootstrap refuses what it must not take: a key with options, two keys, an odd address, hardening without an admin", () => {
	for (const args of [
		[],
		["--pubkey", `command="rm -rf /" ${KEY}`],
		["--pubkey", `${KEY}\nssh-rsa AAAAB3NzaC1yc2E`],
		["--pubkey", "ssh-ed25519 not*base64"],
		["--pubkey", KEY, "--address", "a;rm -rf /"],
		["--pubkey", KEY, "--user", "Root"],
		["--pubkey", KEY, "--harden-ssh"],
	]) {
		const r = bootstrap("--dry-run", ...args);
		assert.notEqual(r.status, 0, JSON.stringify(args));
		assert.match(r.stderr, /^error: /m);
	}
});

test("bootstrap --dry-run shows the plan, the restricted key line and a setup code for the app", () => {
	const r = bootstrap("--dry-run", "--pubkey", KEY, "--address", "agentai.example.com");
	assert.equal(r.status, 0, r.stderr);
	const out = r.stdout;
	assert.match(out, /dry run: nothing will be changed/);
	assert.match(out, /useradd --create-home --shell \/bin\/bash griphub|user griphub exists/);
	assert.match(out, /restrict,pty,port-forwarding,permitopen="127\.0\.0\.1:\*",permitlisten="127\.0\.0\.1:1" ssh-ed25519 /);
	assert.match(out, /systemctl --user enable griphub-hostd\.service/);
	const code = /griphub1:([A-Za-z0-9+/=]+)/.exec(out)?.[1];
	assert.ok(code, "a setup code");
	const json = JSON.parse(Buffer.from(code, "base64").toString());
	assert.deepEqual([json.v, json.host, json.user], [1, "agentai.example.com", "griphub"]);
	assert.equal(typeof json.port, "number");
	assert.equal(typeof json.hostKey, "string");
	// Another agent on the same server is another account.
	const second = bootstrap("--dry-run", "--pubkey", KEY, "--user", "griphub2");
	assert.equal(second.status, 0, second.stderr);
	assert.match(second.stdout, /\/home\/griphub2\/\.griphub/);
});

test("bootstrap warns up front about a machine that is too small, and is quiet about one that is not", () => {
	const run = (env) =>
		spawnSync("bash", [BOOTSTRAP, "--dry-run", "--pubkey", KEY, "--address", "a.example.com"], {
			encoding: "utf8",
			env: { ...process.env, ...env },
		});
	const small = run({ GRIPHUB_TEST_MEM_KB: "1000000", GRIPHUB_TEST_DISK_KB: "3000000" });
	assert.equal(small.status, 0, "a warning, not a refusal");
	assert.match(small.stderr, /warning: this machine has 976 MB of memory; the agent wants at least 2 GB/);
	assert.match(small.stderr, /warning: only 2929 MB free on \/; packages, Node and the box image need about 5 GB/);
	const agentai = run({ GRIPHUB_TEST_MEM_KB: String(8 * 1024 * 1024), GRIPHUB_TEST_DISK_KB: String(90 * 1024 * 1024) });
	assert.equal(agentai.status, 0);
	assert.doesNotMatch(agentai.stderr, /memory|free on/);
	assert.match(agentai.stdout, /Settings > Agent on a VPS \/ server/);
});

// The field-test report (server_agent.md, phase 7) reads another account's service and log, so it wants root; its whole
// run is tried against a real systemd user service by hand (see server_agent.md 4.16), here only what it refuses.
test("field-report.sh explains itself, and refuses odd input, a missing account, and running without root", () => {
	const report = (...args) => spawnSync("bash", [server("field-report.sh"), ...args], { encoding: "utf8" });
	const help = report("--help");
	assert.equal(help.status, 0);
	assert.match(help.stdout, /sudo bash field-report\.sh/);
	assert.doesNotMatch(help.stdout, /^set -euo/m);
	for (const args of [["--user", "Root"], ["--lines", "many"], ["--bogus"]]) {
		const r = report(...args);
		assert.notEqual(r.status, 0, JSON.stringify(args));
		assert.match(r.stderr, /^error: /m);
	}
	const r = report("--user", "no-such-agent-account");
	assert.notEqual(r.status, 0);
	assert.match(r.stderr, process.getuid() === 0 ? /no account named no-such-agent-account/ : /run this as root/);
});
