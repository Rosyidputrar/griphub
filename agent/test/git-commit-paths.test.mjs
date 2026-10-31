// "Review & commit" used to run `git add -A`: everything went in, including an untracked .env the person never looked
// at. A commit can now name its files, and then only those go in (UX-04).
import { test, beforeEach, afterEach } from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync, unlinkSync, renameSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { bundle } from "./helpers.mjs";

process.env.GRIPHUB_STORE_KEY = "ab".repeat(32);
const gitops = await bundle("gitops");

let root;
let repo;
const realHome = process.env.HOME;
const git = (...args) => execFileSync("git", args, { cwd: repo, encoding: "utf8" });

beforeEach(() => {
	root = mkdtempSync(join(tmpdir(), "gh-commit-"));
	process.env.HOME = join(root, "home");
	mkdirSync(process.env.HOME);
	repo = join(root, "repo");
	mkdirSync(join(repo, "src"), { recursive: true });
	git("init", "-q", "-b", "main");
	git("config", "user.email", "t@t");
	git("config", "user.name", "t");
	writeFileSync(join(repo, "src", "a.txt"), "a\n");
	writeFileSync(join(repo, "keep.txt"), "k\n");
	git("add", "-A");
	git("commit", "-q", "-m", "first");
});
afterEach(() => {
	process.env.HOME = realHome;
	rmSync(root, { recursive: true, force: true });
});

const lastFiles = () => git("show", "--name-only", "--no-renames", "--format=", "HEAD").trim().split("\n").filter(Boolean).sort();
const status = () => git("status", "--porcelain").split("\n").filter(Boolean).sort();

test("only the named files are committed: not an untracked .env, not what the agent left staged, not other edits", async () => {
	writeFileSync(join(repo, "src", "a.txt"), "a2\n"); // picked
	writeFileSync(join(repo, "new.txt"), "n\n"); // picked, untracked
	writeFileSync(join(repo, ".env"), "SECRET=1\n"); // untracked, not picked
	writeFileSync(join(repo, "keep.txt"), "k2\n"); // edited, not picked
	writeFileSync(join(repo, "staged.txt"), "s\n");
	git("add", "staged.txt"); // staged by the agent, not picked
	await gitops.commit(join(repo, "src"), "Only some", false, ["src/a.txt", "new.txt"]);
	assert.deepEqual(lastFiles(), ["new.txt", "src/a.txt"]);
	assert.deepEqual(status(), [" M keep.txt", "?? .env", "A  staged.txt"], "everything else is left as it was");
});

test("a deleted file and a rename (both paths) are committed when picked", async () => {
	unlinkSync(join(repo, "keep.txt"));
	renameSync(join(repo, "src", "a.txt"), join(repo, "src", "b.txt"));
	await gitops.commit(repo, "Remove and rename", false, ["keep.txt", "src/b.txt", "src/a.txt"]);
	assert.deepEqual(lastFiles(), ["keep.txt", "src/a.txt", "src/b.txt"]);
	assert.deepEqual(status(), []);
});

test("a name that looks like a pattern is that file, not a pattern", async () => {
	writeFileSync(join(repo, "a.env"), "1\n");
	writeFileSync(join(repo, "b.env"), "2\n");
	writeFileSync(join(repo, "*.env"), "3\n");
	await gitops.commit(repo, "Star", false, ["*.env"]);
	assert.deepEqual(lastFiles(), ["*.env"], "not a.env and b.env");
	assert.deepEqual(status(), ["?? a.env", "?? b.env"]);
});

test("no files selected is refused, and nothing is committed", async () => {
	writeFileSync(join(repo, "x.txt"), "x\n");
	await assert.rejects(gitops.commit(repo, "Nothing", false, []), /No files were selected/);
	assert.equal(git("log", "--format=%s").trim(), "first");
});

test("without paths it is what it was: all adds everything", async () => {
	writeFileSync(join(repo, "x.txt"), "x\n");
	writeFileSync(join(repo, "y.txt"), "y\n");
	await gitops.commit(repo, "All", true);
	assert.deepEqual(lastFiles(), ["x.txt", "y.txt"]);
});
