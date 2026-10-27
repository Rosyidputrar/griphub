// Cloning: repositories are told apart by owner, not by folder name. Before,
// cloning akun1/repo1 made akun2/repo1 show "On device", and opening it opened
// akun1's folder (so commits and pushes went to the wrong repository).
// Real git, offline: https://github.com/ is redirected to local bare repos.
import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { join, dirname, basename } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { build } from "esbuild";

const here = dirname(fileURLToPath(import.meta.url));
mkdirSync(join(here, "..", "build"), { recursive: true });
const out = mkdtempSync(join(here, "..", "build", "clone-test-"));
async function bundle(name) {
	const outfile = join(out, `${name}.mjs`);
	await build({ entryPoints: [join(here, "..", "src", `${name}.ts`)], outfile, bundle: true, platform: "node", format: "esm", packages: "external", logLevel: "error" });
	return import(pathToFileURL(outfile).href);
}
const { Integrations } = await bundle("integrations");
const gitops = await bundle("gitops");

const git = (cwd, ...args) => execFileSync("git", args, { cwd, stdio: "pipe" }).toString().trim();
const realHome = process.env.HOME;
const realFetch = globalThis.fetch;
const remotes = join(out, "remotes");

/** A bare repo served as https://github.com/<slug>.git, with one file naming its owner. */
function remote(slug) {
	const work = mkdtempSync(join(out, "work-"));
	git(work, "init", "-q", "-b", "main");
	git(work, "config", "user.email", "t@t");
	git(work, "config", "user.name", "t");
	writeFileSync(join(work, "OWNER"), slug);
	git(work, "add", "-A");
	git(work, "commit", "-qm", "init");
	const bare = join(remotes, `${slug}.git`);
	mkdirSync(dirname(bare), { recursive: true });
	git(out, "clone", "-q", "--bare", work, bare);
}

let it;
let ws;
const noLog = () => {};

before(() => {
	process.env.HOME = mkdtempSync(join(out, "home-"));
	git(out, "config", "--global", `url.file://${remotes}/.insteadOf`, "https://github.com/");
	git(out, "config", "--global", "protocol.file.allow", "always");
	for (const slug of ["akun1/repo1", "akun2/repo1", "akun2/Other"]) remote(slug);
	ws = mkdtempSync(join(out, "ws-"));
	it = new Integrations(mkdtempSync(join(out, "agentdir-")), ws);
	it.store.github = { token: "t", login: "akun1", name: null, email: "e", avatarUrl: "a" };
	// GitHub lists both repos named "repo1" (one owned, one as a collaborator).
	globalThis.fetch = async () =>
		new Response(
			JSON.stringify([
				{ full_name: "akun1/repo1", name: "repo1", owner: { login: "akun1" } },
				{ full_name: "akun2/repo1", name: "repo1", owner: { login: "akun2" } },
				{ full_name: "akun2/Other", name: "Other", owner: { login: "akun2" } },
			]),
			{ status: 200 },
		);
});
after(() => {
	process.env.HOME = realHome;
	globalThis.fetch = realFetch;
});

const ownerOf = (dir) => execFileSync("cat", [join(dir, "OWNER")]).toString();

test("cloning akun1/repo1 doesn't mark akun2/repo1 as on the device", async () => {
	const { path } = await it.clone("akun1/repo1", noLog);
	assert.equal(basename(path), "repo1");
	assert.equal(ownerOf(path), "akun1/repo1");
	const repos = await it.repos();
	const by = Object.fromEntries(repos.map((r) => [r.fullName, r]));
	assert.equal(by["akun1/repo1"].cloned, true);
	assert.equal(by["akun1/repo1"].path, path);
	assert.equal(by["akun2/repo1"].cloned, false);
});

test("opening akun2/repo1 clones it next to akun1's, instead of opening akun1's folder", async () => {
	const { path } = await it.clone("akun2/repo1", noLog);
	assert.equal(basename(path), "repo1-akun2");
	assert.equal(ownerOf(path), "akun2/repo1");
	// And each repo now opens its own folder.
	assert.equal(ownerOf((await it.clone("akun1/repo1", noLog)).path), "akun1/repo1");
	assert.equal(ownerOf((await it.clone("akun2/repo1", noLog)).path), "akun2/repo1");
	const repos = await it.repos();
	assert.ok(repos.every((r) => r.fullName === "akun2/Other" || r.cloned));
});

test("owner and name match case-insensitively, as on GitHub", async () => {
	const { path } = await it.clone("akun2/Other", noLog);
	assert.equal((await it.clone("AKUN2/other", noLog)).path, path);
});

test("a plain folder with the repo's name is not mistaken for the clone", async () => {
	const ws2 = mkdtempSync(join(out, "ws-"));
	mkdirSync(join(ws2, "repo1"));
	writeFileSync(join(ws2, "repo1", "notes.txt"), "mine");
	const it2 = new Integrations(mkdtempSync(join(out, "agentdir-")), ws2);
	it2.store.github = it.store.github;
	const { path } = await it2.clone("akun1/repo1", noLog);
	assert.equal(basename(path), "repo1-akun1");
	assert.equal(ownerOf(path), "akun1/repo1");
});

test("a git folder whose origin is elsewhere is not the clone either", async () => {
	const ws3 = mkdtempSync(join(out, "ws-"));
	mkdirSync(join(ws3, "repo1"));
	git(join(ws3, "repo1"), "init", "-q");
	git(join(ws3, "repo1"), "remote", "add", "origin", "https://gitlab.com/akun1/repo1.git");
	const it3 = new Integrations(mkdtempSync(join(out, "agentdir-")), ws3);
	it3.store.github = it.store.github;
	const repos = await it3.repos();
	assert.equal(repos.find((r) => r.fullName === "akun1/repo1").cloned, false);
	assert.equal(basename((await it3.clone("akun1/repo1", noLog)).path), "repo1-akun1");
});

test("an SSH origin (git@github.com:owner/repo.git) counts as that repo", async () => {
	const ws4 = mkdtempSync(join(out, "ws-"));
	mkdirSync(join(ws4, "mine"));
	git(join(ws4, "mine"), "init", "-q");
	git(join(ws4, "mine"), "remote", "add", "origin", "git@github.com:akun2/repo1.git");
	const it4 = new Integrations(mkdtempSync(join(out, "agentdir-")), ws4);
	it4.store.github = it.store.github;
	assert.equal(basename((await it4.clone("akun2/repo1", noLog)).path), "mine");
});

test("names that could escape the workspace are refused", async () => {
	for (const bad of ["../x", "a/..", "a/b/c", "a", "a/b;rm -rf"]) {
		await assert.rejects(it.clone(bad, noLog), /Not a GitHub repository name/, bad);
	}
});

test("a branch pushed to GitHub after the clone shows up after fetch, and checks out", async () => {
	const { path } = await it.clone("akun1/repo1", noLog);
	// Someone pushes a new branch and a commit on main.
	const other = mkdtempSync(join(out, "other-"));
	git(out, "clone", "-q", join(remotes, "akun1/repo1.git"), other);
	git(other, "config", "user.email", "t@t");
	git(other, "config", "user.name", "t");
	git(other, "checkout", "-q", "-b", "fitur-baru");
	writeFileSync(join(other, "fitur.txt"), "x");
	git(other, "add", "-A");
	git(other, "commit", "-qm", "fitur");
	git(other, "push", "-q", "origin", "fitur-baru");
	git(other, "checkout", "-q", "main");
	writeFileSync(join(other, "OWNER"), "akun1/repo1 v2");
	git(other, "commit", "-qam", "v2");
	git(other, "push", "-q", "origin", "main");

	const names = async () => (await gitops.branches(path)).map((b) => b.name);
	assert.ok(!(await names()).includes("origin/fitur-baru"), "not known before fetch");
	await gitops.fetch(path);
	assert.ok((await names()).includes("origin/fitur-baru"));
	assert.equal((await gitops.status(path)).behind, 1);

	// Pull fast-forwards main.
	await gitops.pull(path, noLog);
	assert.equal(ownerOf(path), "akun1/repo1 v2");
	assert.equal((await gitops.status(path)).behind, 0);

	// The remote branch checks out as a local branch tracking it.
	await gitops.checkout(path, "origin/fitur-baru", false);
	const st = await gitops.status(path);
	assert.equal(st.branch, "fitur-baru");
	assert.equal(st.upstream, "origin/fitur-baru");
});

test("fetch reports a failure (e.g. offline) instead of pretending", async () => {
	const ws5 = mkdtempSync(join(out, "ws-"));
	mkdirSync(join(ws5, "x"));
	git(join(ws5, "x"), "init", "-q");
	git(join(ws5, "x"), "remote", "add", "origin", join(out, "does-not-exist.git"));
	await assert.rejects(gitops.fetch(join(ws5, "x")));
});

test("cleanup", () => rmSync(out, { recursive: true, force: true }));
