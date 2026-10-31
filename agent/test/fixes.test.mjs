// Host regression tests for the audit fixes, run with real git/rsync:
//   cd agent && npm test
// The TypeScript sources are bundled on the fly with esbuild (see bundle()).
import { test } from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync, renameSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { build } from "esbuild";

const here = dirname(fileURLToPath(import.meta.url));
// Inside agent/ so the bundles resolve agent/node_modules; build/ is ignored by git.
mkdirSync(join(here, "..", "build"), { recursive: true });
const out = mkdtempSync(join(here, "..", "build", "host-test-"));

/** Bundles one source module (its own imports included) and imports it. */
async function bundle(name) {
	const outfile = join(out, `${name}.mjs`);
	await build({
		entryPoints: [join(here, "..", "src", `${name}.ts`)],
		outfile,
		bundle: true,
		platform: "node",
		format: "esm",
		packages: "external",
		logLevel: "error",
	});
	return import(pathToFileURL(outfile).href);
}

function tmp(prefix) {
	return mkdtempSync(join(out, prefix));
}

function write(root, rel, body = rel) {
	mkdirSync(dirname(join(root, rel)), { recursive: true });
	writeFileSync(join(root, rel), body);
}

const sh = (cwd, ...args) => execFileSync("git", args, { cwd, stdio: "pipe" }).toString();

test("#7 git status: renames and odd names come through -z intact", async () => {
	const { parseStatus, status } = await bundle("gitops");
	const repo = tmp("repo-");
	sh(repo, "init", "-q", "-b", "main");
	sh(repo, "config", "user.email", "t@t");
	sh(repo, "config", "user.name", "t");
	write(repo, "old name.txt", "hello\n");
	write(repo, 'quote"d.txt', "q\n");
	sh(repo, "add", "-A");
	sh(repo, "commit", "-qm", "init");
	sh(repo, "mv", "old name.txt", "new name.txt");
	write(repo, "naïve ünicode.md", "u\n");
	const s = await status(repo);
	const renamed = s.files.find((f) => f.code.startsWith("R"));
	assert.equal(renamed.path, "new name.txt");
	assert.equal(renamed.from, "old name.txt");
	assert.ok(s.files.some((f) => f.path === "naïve ünicode.md" && f.untracked));
	// The parser on its own, with a header and a copy.
	const p = parseStatus("## main...origin/main [ahead 1]\0R  b\0a\0 M c d\0C  e\0f\0?? g\0");
	assert.equal(p.head, "## main...origin/main [ahead 1]");
	assert.deepEqual(
		p.files.map((f) => [f.code, f.path, f.from]),
		[["R ", "b", "a"], [" M", "c d", undefined], ["C ", "e", "f"], ["??", "g", undefined]],
	);
	// Staging both sides of the rename works (it used to fail on "old -> new").
	const { stage, unstage } = await bundle("gitops");
	await unstage(repo, "all");
	await stage(repo, ["new name.txt", "old name.txt"]);
	assert.ok((await status(repo)).files.some((f) => f.code === "R " && f.from === "old name.txt"));
});

test("git in a subfolder of a repository: diff, stage, unstage and discard reach the files the status names", async () => {
	const { status, diff, stage, unstage, discard } = await bundle("gitops");
	const repo = tmp("repo-");
	sh(repo, "init", "-q", "-b", "main");
	sh(repo, "config", "user.email", "t@t");
	sh(repo, "config", "user.name", "t");
	write(repo, "site/index.html", "<h1>v1</h1>\n");
	write(repo, "site/old.css", "a{}\n");
	sh(repo, "add", "-A");
	sh(repo, "commit", "-qm", "init");
	const project = join(repo, "site");
	write(repo, "site/index.html", "<h1>v2</h1>\n");
	write(repo, "site/old.css", "a{color:red}\n");
	write(repo, "site/new.js", "x\n");

	const s = await status(project);
	assert.equal(s.root, sh(repo, "rev-parse", "--show-toplevel").trim(), "where the paths start");
	assert.deepEqual(s.files.map((f) => f.path).sort(), ["site/index.html", "site/new.js", "site/old.css"]);
	// The diff of one file, as the status names it (it was empty when run from the subfolder).
	assert.match((await diff(project, "site/index.html")).patch, /\+<h1>v2<\/h1>/);
	assert.match((await diff(project, "site/new.js")).patch, /\+x/, "an untracked file shows as all new");
	// The whole project's diff is still its own.
	assert.match((await diff(project)).patch, /index\.html/);

	await stage(project, ["site/index.html"]);
	assert.equal((await status(project)).files.find((f) => f.path === "site/index.html").code, "M ");
	assert.match((await diff(project, "site/index.html", true)).patch, /\+<h1>v2<\/h1>/);
	await unstage(project, ["site/index.html"]);
	assert.equal((await status(project)).files.find((f) => f.path === "site/index.html").code, " M");

	// A tracked file goes back to its committed text; an untracked one goes away.
	await discard(project, ["site/old.css", "site/new.js"]);
	assert.equal(readFileSync(join(repo, "site/old.css"), "utf8"), "a{}\n");
	assert.equal(existsSync(join(repo, "site/new.js")), false);
	assert.equal(readFileSync(join(repo, "site/index.html"), "utf8"), "<h1>v2</h1>\n", "only what was named");
});

test("#6 undo: lists what it deletes, and keeps what the user ticks", async () => {
	const { Checkpoints } = await bundle("checkpoints");
	const cwd = tmp("proj-");
	const cps = new Checkpoints(tmp("cps-"));
	write(cwd, "a.txt", "v1");
	await cps.snapshot(cwd, "Before the agent's changes");
	const [cp] = await cps.list(cwd);
	write(cwd, "a.txt", "v2 by agent");
	write(cwd, "agent-new.js", "agent");
	write(cwd, "notes/mine.md", "the user's own file");
	const plan = await cps.restorePlan(cwd, cp.id);
	assert.deepEqual([...plan.removes].sort(), ["agent-new.js", "notes/mine.md"]);
	await cps.restore(cwd, cp.id, ["notes/mine.md"]);
	assert.equal(readFileSync(join(cwd, "a.txt"), "utf8"), "v1");
	assert.equal(existsSync(join(cwd, "agent-new.js")), false);
	assert.equal(readFileSync(join(cwd, "notes/mine.md"), "utf8"), "the user's own file");
	await assert.rejects(cps.restorePlan(cwd, "deadbeef"), /Unknown checkpoint/);
});

test("#1 SSH deploy uploads exactly what the other targets do: no .env or dotfiles", async () => {
	const { Integrations, walk, skippedEntries } = await bundle("integrations");
	const proj = tmp("site-");
	write(proj, "index.html", "<h1>hi</h1>");
	write(proj, "assets/app.js", "x");
	write(proj, ".env", "DB_PASSWORD=secret");
	write(proj, ".npmrc", "//registry:_authToken=t");
	write(proj, "assets/.secret", "s");
	write(proj, "node_modules/pkg/index.js", "m");
	write(proj, ".git/config", "c");
	assert.deepEqual(walk(proj).sort(), ["assets/app.js", "index.html"]);
	assert.deepEqual(skippedEntries(proj), [".env", ".git", ".npmrc", "node_modules"]);

	// A fake `ssh` on PATH: it ignores options and the host, and runs the
	// remote command locally, so the real rsync (and mkdir) go through it.
	const remote = tmp("remote-");
	const bin = tmp("bin-");
	writeFileSync(
		join(bin, "ssh"),
		`#!/bin/sh\nwhile [ $# -gt 0 ]; do case "$1" in -F|-o|-l|-p) shift 2;; -*) shift;; *) break;; esac; done\nshift\nexec sh -c "$*"\n`,
		{ mode: 0o755 },
	);
	const home = tmp("home-");
	const agentDir = tmp("agentdir-");
	const env = { ...process.env };
	process.env.HOME = home;
	process.env.PATH = `${bin}:${process.env.PATH}`;
	try {
		const it = new Integrations(agentDir, proj);
		it.store.sshHosts = [{ id: "h1", name: "box", host: "example.test", user: "me", path: remote }];
		const plan = await it.deployPlan("ssh", proj, { hostId: "h1" });
		assert.equal(plan.files, 2);
		assert.ok(plan.skipped.includes(".env"));
		await assert.rejects(it.deploy("ssh", proj, { hostId: "h1" }, () => {}), /Confirm the deploy target/);
		await it.deploy("ssh", proj, { hostId: "h1", confirmed: true }, () => {});
		assert.equal(readFileSync(join(remote, "index.html"), "utf8"), "<h1>hi</h1>");
		assert.ok(existsSync(join(remote, "assets/app.js")));
		for (const leaked of [".env", ".npmrc", "assets/.secret", "node_modules", ".git"]) {
			assert.equal(existsSync(join(remote, leaked)), false, `${leaked} must not reach the server`);
		}
	} finally {
		process.env.HOME = env.HOME;
		process.env.PATH = env.PATH;
	}
});

test("#2 container: a failed install leaves the working rootfs untouched", async () => {
	const { Container } = await bundle("container");
	const files = tmp("files-");
	const rootfs = join(files, "linux", "rootfs");
	process.env.GRIPHUB_ROOTFS = rootfs;
	write(rootfs, "etc/os-release", "ID=debian");
	write(rootfs, "usr/bin/mytool", "installed by the user");
	writeFileSync(join(files, "linux", "container.json"), JSON.stringify({ distro: "debian" }));
	const c = new Container(files);
	// No network in the test: make the registry fail the way a dropped connection does.
	c.resolveLayers = async () => {
		throw new Error("fetch failed: network down");
	};
	const lines = [];
	await assert.rejects(c.install("alpine", (l) => lines.push(l)), /network down/);
	assert.equal(readFileSync(join(rootfs, "usr/bin/mytool"), "utf8"), "installed by the user");
	assert.equal(existsSync(`${rootfs}.new`), false);
	assert.ok(existsSync(join(files, "linux", "container.json")));
	assert.ok(lines.some((l) => /current container is unchanged/.test(l)));
	delete process.env.GRIPHUB_ROOTFS;
});

test("the default context limit follows the model's window: 65%, never under the floor", async () => {
	const { compactLimit, COMPACT_AT_DEFAULT, COMPACT_AT_SHARE } = await bundle("integrations");
	assert.equal(COMPACT_AT_SHARE, 0.65);
	assert.equal(compactLimit(undefined, 872_000), 567_000, "65% of the window, rounded to thousands");
	assert.equal(compactLimit(undefined, 1_000_000), 650_000);
	assert.equal(compactLimit(undefined, 2_000_000), 1_300_000);
	assert.equal(compactLimit(undefined, 200_000), COMPACT_AT_DEFAULT, "a small window stays on the floor: past it, pi's own compaction rules");
	assert.equal(compactLimit(undefined, undefined), COMPACT_AT_DEFAULT, "no window known: the floor");
	assert.equal(compactLimit(0, 872_000), 0, "0 is the user's: the host's summaries are off");
	assert.equal(compactLimit(500_000, 872_000), 500_000, "a set limit is used as it is");
	assert.equal(compactLimit(500_000, undefined), 500_000);
});

test("cleanup", () => {
	rmSync(out, { recursive: true, force: true });
});
