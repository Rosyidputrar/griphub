/** Git for a project folder: status, diffs, commits, branches, sync, PRs. */

import { spawn } from "node:child_process";
import { open } from "node:fs/promises";
import { join } from "node:path";
import { assertRepoConfigSafe, gitEnv, SAFE_GIT_FLAGS } from "./gitsafe.js";

/** For a diff: no external diff program and no text-conversion program, whatever the project's settings say. */
const NO_PROGRAMS = ["--no-ext-diff", "--no-textconv"];

/**
 * Runs git in a project folder. The agent can write that folder's git settings, so every call here goes through
 * gitsafe.ts: flags that turn off the programs git would take from them, a refusal when the settings name one the flags
 * cannot turn off, and an environment with no tokens (see there).
 */
async function git(cwd: string, args: string[]): Promise<{ code: number; out: string; err: string }> {
	await assertRepoConfigSafe(cwd);
	return new Promise((resolve, reject) => {
		const child = spawn("git", [...SAFE_GIT_FLAGS, ...args], { cwd, env: gitEnv() });
		let out = "";
		let err = "";
		child.stdout.on("data", (c) => (out += c));
		child.stderr.on("data", (c) => (err += c));
		child.on("error", reject);
		child.on("close", (code) => resolve({ code: code ?? 1, out, err }));
	});
}

async function ok(cwd: string, args: string[]) {
	const r = await git(cwd, args);
	if (r.code !== 0) throw new Error((r.err || r.out).trim().split("\n").slice(-4).join("\n") || `git ${args[0]} failed`);
	return r.out;
}

export interface FileStatus {
	path: string;
	/** For a rename or copy: where it came from. */
	from?: string;
	/** Two-letter porcelain code, e.g. "M ", " M", "??", "A ", "R ". */
	code: string;
	staged: boolean;
	unstaged: boolean;
	untracked: boolean;
}

/**
 * Parses `git status --porcelain=v1 -z -b`. NUL-separated, so paths come
 * unquoted (spaces, quotes, unicode, newlines intact), and a rename is
 * "R  new\0old" — the line format "R  old -> new" used to be taken as one
 * path, so staging or diffing a renamed file failed.
 */
export function parseStatus(raw: string) {
	const parts = raw.split("\0");
	let head = "";
	const files: FileStatus[] = [];
	for (let i = 0; i < parts.length; i++) {
		const entry = parts[i];
		if (!entry) continue;
		if (entry.startsWith("## ")) {
			head = entry;
			continue;
		}
		const code = entry.slice(0, 2);
		const path = entry.slice(3);
		// Renames and copies carry their source as the next field.
		const from = code[0] === "R" || code[0] === "C" || code[1] === "R" || code[1] === "C" ? parts[++i] : undefined;
		files.push({
			path,
			...(from ? { from } : {}),
			code,
			staged: code[0] !== " " && code[0] !== "?",
			unstaged: code[1] !== " ",
			untracked: code === "??",
		});
	}
	return { head, files };
}

/**
 * The repository's top folder. `git status --porcelain` names files from there whatever folder it runs in, while a
 * pathspec (`git diff -- x`, `git add -- x`) is read from the folder git runs in; so every command that takes a path
 * from the status runs here, or a project in a subfolder of a repository saw empty diffs and could not stage, unstage
 * or discard its files.
 */
async function top(cwd: string): Promise<string> {
	return (await git(cwd, ["rev-parse", "--show-toplevel"])).out.trim() || cwd;
}

export async function status(cwd: string) {
	const inRepo = await git(cwd, ["rev-parse", "--is-inside-work-tree"]);
	if (inRepo.code !== 0) return { repo: false as const };
	const root = await top(cwd);
	const { head, files } = parseStatus(await ok(cwd, ["status", "--porcelain=v1", "-z", "-b", "-uall"]));
	// "## main...origin/main [ahead 1, behind 2]"
	const m = head.match(/^## (?:No commits yet on )?([^.\s]+)(?:\.\.\.(\S+))?(?: \[(.+)\])?/);
	const ahead = Number(head.match(/ahead (\d+)/)?.[1] ?? 0);
	const behind = Number(head.match(/behind (\d+)/)?.[1] ?? 0);
	const remote = (await git(cwd, ["remote", "get-url", "origin"])).out.trim() || null;
	// root: where the files' paths start (the app reads a changed file's contents from there).
	return { repo: true as const, root, branch: m?.[1] ?? "HEAD", upstream: m?.[2] ?? null, ahead, behind, remote, files };
}

export async function diff(cwd: string, file?: string, staged = false) {
	// A file's path comes from the status: relative to the top. The whole diff stays the project folder's own.
	if (file) cwd = await top(cwd);
	const args = ["diff", ...NO_PROGRAMS, "--no-color", "-U3"];
	if (staged) args.push("--cached");
	if (file) args.push("--", file);
	let patch = await ok(cwd, args);
	// Untracked files have no diff; show them as all-new.
	if (!patch && file && !staged) {
		const r = await git(cwd, ["diff", ...NO_PROGRAMS, "--no-color", "--no-index", "/dev/null", file]);
		patch = r.out;
	}
	return { patch };
}

export async function stage(cwd: string, paths: string[] | "all") {
	if (paths === "all") return void (await ok(cwd, ["add", "-A"]));
	await ok(await top(cwd), ["add", "--", ...paths]);
}

export async function unstage(cwd: string, paths: string[] | "all") {
	if (paths === "all") return void (await ok(cwd, ["reset", "-q"]));
	await ok(await top(cwd), ["reset", "-q", "--", ...paths]);
}

export async function discard(cwd: string, paths: string[]) {
	cwd = await top(cwd);
	for (const p of paths) {
		const tracked = (await git(cwd, ["ls-files", "--error-unmatch", "--", p])).code === 0;
		if (tracked) await ok(cwd, ["checkout", "--", p]);
		else await ok(cwd, ["clean", "-fdq", "--", p]);
	}
}

/**
 * Commits. With [paths] (relative to the top of the repository, as the status lists them), exactly those files and
 * nothing else: they are staged, and the commit is limited to them, so a file the agent left staged that the person did
 * not pick stays out, and so does everything untracked that was not picked. [all] adds everything (`add -A`).
 */
export async function commit(cwd: string, message: string, all: boolean, paths?: string[]) {
	if (paths) {
		if (!paths.length) throw new Error("No files were selected to commit.");
		const root = await top(cwd);
		// Literal: a name such as `*.env` or `:(top)x` is that file, not a pattern.
		await ok(root, ["--literal-pathspecs", "add", "-A", "--", ...paths]);
		await ok(root, ["--literal-pathspecs", "commit", "-q", "-m", message, "--", ...paths]);
		return (await ok(root, ["log", "-1", "--format=%h %s"])).trim();
	}
	if (all) await ok(cwd, ["add", "-A"]);
	await ok(cwd, ["commit", "-q", "-m", message]);
	return (await ok(cwd, ["log", "-1", "--format=%h %s"])).trim();
}

/** Lines added and removed in one file, or that it is binary. */
export interface FileStat {
	additions: number;
	deletions: number;
	binary?: boolean;
}

/** How many lines of an untracked file there are to add: it has no diff to count. Binary or past 2 MB: unknown. */
async function newFileStat(path: string): Promise<FileStat> {
	const f = await open(path).catch(() => null);
	if (!f) return { additions: 0, deletions: 0 };
	try {
		const buf = Buffer.alloc(2 * 1024 * 1024);
		const { bytesRead } = await f.read(buf, 0, buf.length, 0);
		const data = buf.subarray(0, bytesRead);
		if (data.includes(0)) return { additions: 0, deletions: 0, binary: true };
		let lines = 0;
		for (const b of data) if (b === 10) lines++;
		if (bytesRead > 0 && data[bytesRead - 1] !== 10) lines++;
		return { additions: lines, deletions: 0 };
	} finally {
		await f.close();
	}
}

/**
 * Everything the review before a commit shows at once: the status, and per file how many lines it adds and removes
 * against the last commit (staged and not alike; an untracked file counts its lines). A repository with no commit yet
 * counts against nothing.
 */
export async function review(cwd: string) {
	const st = await status(cwd);
	if (!st.repo) return { ...st, stats: {} as Record<string, FileStat> };
	const stats: Record<string, FileStat> = {};
	const hasHead = (await git(st.root, ["rev-parse", "--verify", "-q", "HEAD"])).code === 0;
	const numstat = await git(st.root, hasHead ? ["diff", ...NO_PROGRAMS, "--numstat", "-z", "HEAD"] : ["diff", ...NO_PROGRAMS, "--numstat", "-z", "--cached"]);
	// "adds\tdels\tpath\0", or for a rename "adds\tdels\t\0from\0to\0".
	const parts = numstat.out.split("\0");
	for (let i = 0; i < parts.length; i++) {
		const m = parts[i].match(/^(-|\d+)\t(-|\d+)\t(.*)$/s);
		if (!m) continue;
		let path = m[3];
		if (!path) {
			i += 2;
			path = parts[i] ?? "";
		}
		stats[path] = m[1] === "-" ? { additions: 0, deletions: 0, binary: true } : { additions: Number(m[1]), deletions: Number(m[2]) };
	}
	for (const f of st.files) if (f.untracked) stats[f.path] = await newFileStat(join(st.root, f.path));
	return { ...st, stats };
}

/** The whole change against the last commit, for writing its message: the stat, then the diff (cut at [max] chars). */
export async function changeSummary(cwd: string, max = 16_000) {
	const st = await status(cwd);
	if (!st.repo) return null;
	const hasHead = (await git(st.root, ["rev-parse", "--verify", "-q", "HEAD"])).code === 0;
	const base = hasHead ? ["HEAD"] : ["--cached"];
	const stat = (await git(st.root, ["diff", ...NO_PROGRAMS, "--stat=100", ...base])).out.trim();
	let patch = (await git(st.root, ["diff", ...NO_PROGRAMS, "--no-color", "-U1", ...base])).out;
	if (patch.length > max) patch = `${patch.slice(0, max)}\n[... the rest of the diff is cut]`;
	const untracked = st.files.filter((f) => f.untracked).map((f) => f.path);
	return { stat, patch, untracked, files: st.files.length };
}

export async function log(cwd: string, limit = 40) {
	const out = await ok(cwd, ["log", `-n${limit}`, "--format=%h%x09%an%x09%ct%x09%s"]).catch(() => "");
	return out
		.split("\n")
		.filter(Boolean)
		.map((l) => {
			const [hash, author, time, subject] = l.split("\t");
			return { hash, author, time: Number(time) * 1000, subject };
		});
}

export async function branches(cwd: string) {
	const out = await ok(cwd, ["branch", "-a", "--format=%(refname:short)%09%(HEAD)"]);
	return out
		.split("\n")
		.filter(Boolean)
		.map((l) => {
			const [name, head] = l.split("\t");
			return { name, current: head === "*", remote: name.startsWith("origin/") };
		})
		.filter((b) => b.name !== "origin/HEAD" && b.name !== "origin");
}

export async function checkout(cwd: string, branch: string, create: boolean) {
	const local = branch.replace(/^origin\//, "");
	if (create) await ok(cwd, ["checkout", "-q", "-b", local]);
	else await ok(cwd, ["checkout", "-q", local]);
}

/** Updates the remote branches (new ones appear, deleted ones go), without touching the working tree. */
export async function fetch(cwd: string) {
	const r = await git(cwd, ["fetch", "--prune", "origin"]);
	if (r.code !== 0) throw new Error((r.err || r.out).trim().split("\n").slice(-3).join("\n"));
}

export async function pull(cwd: string, log: (l: string) => void) {
	const r = await git(cwd, ["pull", "--ff-only"]);
	log((r.out + r.err).trim());
	if (r.code !== 0) throw new Error((r.err || r.out).trim().split("\n").slice(-3).join("\n"));
}

export async function push(cwd: string, log: (l: string) => void) {
	const branch = (await ok(cwd, ["branch", "--show-current"])).trim();
	await pushLfsObjects(cwd, log);
	const r = await git(cwd, ["push", "-u", "origin", `HEAD:${branch}`]);
	log((r.out + r.err).trim());
	if (r.code !== 0) throw new Error((r.err || r.out).trim().split("\n").slice(-3).join("\n"));
}

/**
 * A project that uses Git LFS keeps big files as small pointers in its commits and the files themselves on the LFS
 * server. LFS uploads them from a `pre-push` hook, and the host runs git with hooks off (SAFE_GIT_FLAGS), so that hook
 * never runs: the remote would get pointers whose files are nowhere. Upload them here, before the push, the way the
 * hook would. `git lfs push` runs no hook and no program from the project's settings (lfs.extension.*, a custom
 * transfer agent and filters other than git-lfs's own are refused by assertRepoConfigSafe).
 */
async function pushLfsObjects(cwd: string, log: (l: string) => void) {
	// The filter is what `git lfs install` leaves in the repository's settings (or in the user's global ones).
	const uses = (await git(cwd, ["config", "--get", "filter.lfs.clean"])).code === 0;
	if (!uses) return;
	const r = await git(cwd, ["lfs", "push", "origin", "HEAD"]);
	log((r.out + r.err).trim());
	if (r.code !== 0) {
		const why = (r.err || r.out).trim().split("\n").slice(-3).join("\n");
		throw new Error(`This project uses Git LFS, and its large files could not be uploaded, so nothing was pushed.\n${why}`);
	}
}

export function githubSlug(remote: string | null) {
	return remote?.match(/github\.com[:/]([^/]+\/[^/]+?)(?:\.git)?\/?$/)?.[1] ?? null;
}
