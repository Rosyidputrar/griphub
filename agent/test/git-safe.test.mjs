// Git run by the host on a project folder (gitsafe.ts). The agent can write a project's `.git/config`, `.git/hooks` and
// `.gitattributes` from inside the box, and git runs the programs named there: on a status, a commit, a fetch, an add, a
// diff. The host runs git outside the box with the sign-in tokens around, so a project could make the host run what it
// liked, with no approval. Each test first shows the attack works against plain git (a marker file appears), then that
// the host's git does not run it.
import { test, beforeEach, afterEach } from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { appendFileSync, chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { bundle } from "./helpers.mjs";

// secure.ts (behind integrations) reads the store key once, at import.
process.env.GRIPHUB_STORE_KEY = "ab".repeat(32);
const gitops = await bundle("gitops");
const { gitRun, Integrations } = await bundle("integrations");
const { SAFE_GIT_FLAGS, assertRepoConfigSafe, gitEnv } = await bundle("gitsafe");

let root;
let marker;
let boom;
const realHome = process.env.HOME;

beforeEach(() => {
	root = mkdtempSync(join(tmpdir(), "gh-gitsafe-"));
	process.env.HOME = join(root, "home"); // no global git settings of the machine running the tests
	mkdirSync(process.env.HOME);
	marker = join(root, "marker");
	boom = join(root, "boom.sh");
	writeFileSync(boom, `#!/bin/sh\necho "$0 $*" >> "${marker}"\nexit 0\n`);
	chmodSync(boom, 0o755);
});
afterEach(() => {
	process.env.HOME = realHome;
	rmSync(root, { recursive: true, force: true });
});

const raw = (cwd, ...args) => {
	try {
		return execFileSync("git", args, { cwd, encoding: "utf8", stdio: ["ignore", "pipe", "pipe"], env: { ...process.env, GIT_TERMINAL_PROMPT: "0" }, timeout: 20_000 });
	} catch (e) {
		return `${e.stdout ?? ""}${e.stderr ?? ""}`;
	}
};
const ran = () => existsSync(marker);
const reset = () => rmSync(marker, { force: true });

/** A repository with one commit, a clean tree. */
function repo(name = "proj") {
	const dir = join(root, name);
	mkdirSync(dir, { recursive: true });
	raw(dir, "init", "-q", "-b", "main");
	raw(dir, "config", "user.email", "t@example.com");
	raw(dir, "config", "user.name", "T");
	writeFileSync(join(dir, "a.txt"), "one\n");
	raw(dir, "add", "-A");
	raw(dir, "commit", "-qm", "init");
	return dir;
}
const config = (dir, key, value) => raw(dir, "config", key, value);
// By name: each bundle() carries its own copy of the class, so instanceof across bundles is never true.
const refused = (promise, pattern) => assert.rejects(promise, (e) => e?.name === "UnsafeRepoConfig" && pattern.test(e.message), "refused with a reason");

test("a status does not run the fsmonitor program a project names", async () => {
	const dir = repo();
	config(dir, "core.fsmonitor", boom);
	raw(dir, "status", "--porcelain");
	assert.ok(ran(), "plain git runs it (the attack is real)");
	reset();
	const st = await gitops.status(dir);
	assert.equal(st.repo, true);
	assert.equal(st.branch, "main");
	assert.ok(!ran(), "the host's git does not");
});

test("a commit does not run the project's hooks", async () => {
	const dir = repo();
	mkdirSync(join(dir, ".git", "hooks"), { recursive: true });
	for (const hook of ["pre-commit", "commit-msg", "post-commit"]) {
		writeFileSync(join(dir, ".git", "hooks", hook), `#!/bin/sh\necho ${hook} >> "${marker}"\n`);
		chmodSync(join(dir, ".git", "hooks", hook), 0o755);
	}
	writeFileSync(join(dir, "a.txt"), "two\n");
	raw(dir, "commit", "-qam", "plain");
	assert.ok(ran(), "plain git runs the hooks");
	reset();
	writeFileSync(join(dir, "a.txt"), "three\n");
	await gitops.commit(dir, "from the host", true);
	assert.ok(!ran(), "the host's commit runs none");
	assert.match(raw(dir, "log", "-1", "--format=%s"), /from the host/, "and it still committed");
});

test("a fetch over ssh does not run the project's sshCommand", async () => {
	const dir = repo();
	raw(dir, "remote", "add", "origin", "ssh://127.0.0.1:1/x");
	config(dir, "core.sshCommand", boom);
	raw(dir, "fetch", "origin");
	assert.ok(ran(), "plain git runs it");
	reset();
	await gitops.fetch(dir).catch(() => {}); // nothing listens on that port: it fails, that is not the point
	assert.ok(!ran(), "the host's fetch does not");
});

test("a diff does not run a text-conversion or external program", async () => {
	const dir = repo();
	writeFileSync(join(dir, ".gitattributes"), "*.txt diff=x\n");
	config(dir, "diff.x.textconv", `${boom} conv`);
	writeFileSync(join(dir, "a.txt"), "changed\n");
	raw(dir, "diff");
	assert.ok(ran(), "plain git runs the converter");
	reset();
	// The flags alone take it away...
	raw(dir, ...SAFE_GIT_FLAGS, "diff", "--no-ext-diff", "--no-textconv");
	assert.ok(!ran(), "no converter with the flags");
	// ...and the host will not run git where the settings name one at all.
	await refused(gitops.diff(dir), /run a program to compare files: "diff\.x\.textconv"/);
	config(dir, "diff.external", boom);
	await refused(gitops.review(dir), /run a program to compare files/);
	assert.ok(!ran());
});

test("adding or committing does not run a filter program a project names", async () => {
	const dir = repo();
	writeFileSync(join(dir, ".gitattributes"), "* filter=x\n");
	config(dir, "filter.x.clean", `${boom} clean`);
	writeFileSync(join(dir, "a.txt"), "changed\n");
	raw(dir, "add", "-A");
	assert.ok(ran(), "plain git runs the filter on an add");
	reset();
	raw(dir, "reset", "-q");
	reset();
	await refused(gitops.stage(dir, "all"), /run a program on every file git adds or checks out: "filter\.x\.clean"/);
	await refused(gitops.commit(dir, "m", true), /filter\.x\.clean/);
	await refused(gitops.status(dir), /filter\.x\.clean/);
	assert.ok(!ran(), "no program ran");
	for (const key of ["smudge", "process"]) {
		raw(dir, "config", "--remove-section", "filter.x"); // only this one is there, so it is the one named
		config(dir, `filter.x.${key}`, boom);
		await refused(gitops.status(dir), new RegExp(`filter\\.x\\.${key}`));
	}
});

test("settings that include another file, name a merge driver, a credential helper for an address, or a git proxy are refused", async () => {
	for (const [key, value, pattern] of [
		["include.path", "../other.cfg", /include another file/],
		["includeIf.gitdir:/x/.path", "../other.cfg", /include another file/],
		["merge.x.driver", boom, /run a program to merge files/],
		["credential.https://github.com.helper", `!${boom}`, /run a program to look up a password/],
		["core.gitProxy", boom, /run a program to reach a git:\/\/ address/],
		["submodule.s.update", `!${boom}`, /run a program to update a submodule/],
	]) {
		const dir = repo(`p-${key.replace(/\W/g, "")}`);
		config(dir, key, value);
		await refused(gitops.status(dir), pattern);
		await refused(gitRun(["status"], { cwd: dir }), pattern);
	}
	assert.ok(!ran());
});

test("what the flags turn off is allowed in the settings: it cannot run", async () => {
	const dir = repo();
	for (const [key, value] of [["core.fsmonitor", boom], ["core.hooksPath", "hooks-of-mine"], ["core.sshCommand", boom], ["core.pager", boom], ["core.editor", boom], ["credential.helper", `!${boom}`], ["commit.gpgsign", "true"], ["gpg.program", boom], ["alias.st", `!${boom}`]]) {
		config(dir, key, value);
	}
	await assertRepoConfigSafe(dir);
	assert.equal((await gitops.status(dir)).repo, true);
	assert.ok(!ran());
});

test("git-lfs's own filter settings are allowed; anything that only looks like them is not", async () => {
	const dir = repo();
	config(dir, "filter.lfs.clean", "git-lfs clean -- %f");
	config(dir, "filter.lfs.smudge", "git-lfs smudge -- %f");
	config(dir, "filter.lfs.process", "git-lfs filter-process");
	config(dir, "filter.lfs.required", "true");
	await assertRepoConfigSafe(dir);
	config(dir, "filter.lfs.clean", `git-lfs clean -- %f; ${boom}`);
	await refused(assertRepoConfigSafe(dir), /filter\.lfs\.clean/);
	config(dir, "filter.lfs.clean", "git-lfs clean -- %f");
	config(dir, "filter.lfs2.clean", "git-lfs clean -- %f");
	await refused(assertRepoConfigSafe(dir), /filter\.lfs2\.clean/);
});

test("a linked worktree is read through to the settings it shares", async () => {
	const dir = repo();
	const wt = join(root, "wt");
	raw(dir, "worktree", "add", "-q", wt);
	assert.ok(existsSync(join(wt, ".git")));
	await assertRepoConfigSafe(wt);
	config(dir, "filter.x.clean", boom);
	await refused(gitops.status(wt), /filter\.x\.clean/);
});

test("the settings of the repository around a folder count: a subfolder, an empty .git put in the way, and a folder that looks bare", async () => {
	const dir = repo();
	config(dir, "filter.x.clean", boom);
	mkdirSync(join(dir, "sub", "deeper"), { recursive: true });
	await refused(gitops.status(join(dir, "sub", "deeper")), /filter\.x\.clean/);
	// A `.git` folder with nothing in it is no repository to git, which goes on to the one above.
	mkdirSync(join(dir, "sub", ".git"));
	await refused(gitops.status(join(dir, "sub")), /filter\.x\.clean/);
	// A folder with HEAD, objects and a config of its own is a bare repository to git unless it is told otherwise.
	const bare = join(root, "looks-bare");
	mkdirSync(join(bare, "objects"), { recursive: true });
	writeFileSync(join(bare, "HEAD"), "ref: refs/heads/main\n");
	writeFileSync(join(bare, "config"), `[core]\n\tbare = true\n[filter "y"]\n\tclean = ${boom}\n`);
	await refused(gitops.status(bare), /filter\.y\.clean/);
	assert.match(raw(bare, ...SAFE_GIT_FLAGS, "rev-parse", "--is-bare-repository"), /fatal|not a git repository/i, "and with the flags git does not take it for a repository");
	assert.ok(!ran());
});

test("a folder reached through a link is judged where it really is: git looks at the folders above the real one", async () => {
	const dir = repo("real-repo");
	config(dir, "filter.x.clean", boom);
	mkdirSync(join(dir, "sub"));
	const link = join(root, "link"); // not under the repository by name, but is the repository's sub folder
	symlinkSync(join(dir, "sub"), link);
	assert.match(raw(link, "rev-parse", "--show-toplevel"), /real-repo/, "git works in the repository from there");
	await refused(gitops.status(link), /filter\.x\.clean/);
	await refused(gitRun(["status"], { cwd: link }), /filter\.x\.clean/);
});

test("a change to the settings is noticed at once, and so is putting them right", async () => {
	const dir = repo();
	await assertRepoConfigSafe(dir);
	await assertRepoConfigSafe(dir); // cached
	appendFileSync(join(dir, ".git", "config"), `[filter "z"]\n\tclean = ${boom}\n`);
	await refused(assertRepoConfigSafe(dir), /filter\.z\.clean/);
	config(dir, "--remove-section", "filter.z");
	await assertRepoConfigSafe(dir);
	// Even a change that keeps the file's size: what is looked at is its content.
	const file = join(dir, ".git", "config");
	const text = readFileSync(file, "utf8");
	writeFileSync(file, text.replace("name = T", "name = U"));
	await assertRepoConfigSafe(dir);
	writeFileSync(file, `${text.replace("name = T", "name = U")}[filter "q"]\n\tclean = x\n`);
	await refused(assertRepoConfigSafe(dir), /filter\.q\.clean/);
});

test("a folder that is no repository is left to git: nothing is refused, git says what it says", async () => {
	const plain = join(root, "plain");
	mkdirSync(plain);
	await assertRepoConfigSafe(plain);
	assert.deepEqual(await gitops.status(plain), { repo: false });
});

test("the project list does not run what a project names, and still reads the project", async () => {
	const ws = join(root, "workspace");
	mkdirSync(ws);
	const dir = repo("workspace/shop");
	raw(dir, "remote", "add", "origin", "https://github.com/me/shop.git");
	config(dir, "core.fsmonitor", boom);
	writeFileSync(join(dir, "a.txt"), "changed\n");
	const it = new Integrations(join(root, "agent"), ws);
	const shop = (await it.projects()).find((p) => p.name === "shop");
	assert.ok(shop, "listed");
	assert.equal(shop.dirty, true, "its changes are seen");
	assert.equal(shop.branch, "main");
	assert.ok(!ran(), "nothing was run");
	// With settings that name a program the flags cannot turn off, the project is still listed, without git's answers.
	config(dir, "filter.x.clean", boom);
	const again = (await it.projects()).find((p) => p.name === "shop");
	assert.ok(again && again.dirty === false && again.branch === null, "listed, with nothing read from it");
	assert.ok(!ran());
});

test("git's environment has no tokens or keys and nothing to ask a person with", async () => {
	const env = gitEnv({ PATH: "/bin", HOME: "/h", GITHUB_TOKEN: "t", GH_TOKEN: "t", VERCEL_TOKEN: "t", CLOUDFLARE_API_TOKEN: "t", GRIPHUB_STORE_KEY: "k", OPENAI_API_KEY: "k", MY_SECRET: "s", DB_PASSWORD: "p", SSH_AUTH_SOCK: "/s", GIT_EXTERNAL_DIFF: "x", LANG: "C" });
	assert.deepEqual(Object.keys(env).sort(), ["GIT_ASKPASS", "GIT_EDITOR", "GIT_PAGER", "GIT_TERMINAL_PROMPT", "HOME", "LANG", "PATH", "SSH_AUTH_SOCK"]);
	assert.equal(env.GIT_TERMINAL_PROMPT, "0");
	// And that is what the child gets: an alias that prints its environment.
	const dir = repo();
	process.env.GITHUB_TOKEN = "ghp_should-not-reach-git";
	process.env.GRIPHUB_STORE_KEY = "ab".repeat(32);
	try {
		const printed = await gitRun(["-c", "alias.e=!env", "e"], { cwd: dir });
		assert.ok(!/ghp_should-not-reach-git|GITHUB_TOKEN|GRIPHUB_STORE_KEY/.test(printed), "no secrets in git's environment");
		assert.match(printed, /^GIT_TERMINAL_PROMPT=0$/m);
		assert.match(printed, /^HOME=/m, "but git still finds its settings");
	} finally {
		delete process.env.GITHUB_TOKEN;
	}
});

test("ordinary git work is as it was: status, diff, commit, branches and a fetch from a local remote", async () => {
	const remote = join(root, "remote.git");
	mkdirSync(remote);
	raw(remote, "init", "-q", "--bare", "-b", "main");
	const dir = repo();
	raw(dir, "remote", "add", "origin", remote);
	raw(dir, "push", "-q", "-u", "origin", "main");
	writeFileSync(join(dir, "a.txt"), "two\n");
	writeFileSync(join(dir, "new.txt"), "new\n");
	const st = await gitops.status(dir);
	assert.deepEqual(st.files.map((f) => f.path).sort(), ["a.txt", "new.txt"]);
	assert.match((await gitops.diff(dir)).patch ?? (await gitops.diff(dir)), /two/);
	await gitops.stage(dir, "all");
	await gitops.commit(dir, "second", false);
	assert.equal(raw(dir, "log", "-1", "--format=%s").trim(), "second");
	await gitops.push(dir, () => {});
	assert.equal((await gitops.status(dir)).ahead, 0);
	assert.ok((await gitops.branches(dir)).some((b) => b.name === "main"));
	await gitops.fetch(dir);
	const summary = await gitops.review(dir);
	assert.ok(summary, "the review reads");
});
