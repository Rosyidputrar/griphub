/**
 * Git on a project folder, run by the host (the git panel, the project list, commits, deleting a project).
 *
 * The agent works in these folders, and from inside the box it can write their `.git/config`, `.git/hooks`, and a
 * `.gitattributes`. Git runs programs named there: `core.fsmonitor` on a status, hooks on a commit, `core.sshCommand` on a
 * fetch, a `filter` or `diff` driver on an add or a diff. The host runs git as the service user, outside the box, with
 * the sign-in tokens in its environment, so a project that said "run this" made the host run it, with no approval. Every
 * one of those was reproduced with git 2.43 (agent/test/git-safe.test.mjs does it again).
 *
 * Three things close that, all in this file:
 *   - SAFE_GIT_FLAGS: `-c` settings that turn off every program git would take from the repository's config for the
 *     work the host does. `-c` wins over the repository's own file, includes too.
 *   - assertRepoConfigSafe: what a flag cannot turn off, because the name is the repository's to choose (`filter.<name>`,
 *     `diff.<name>`, `merge.<name>`, an include of another file), is looked for in the repository's config, and git is
 *     not run there while it is found.
 *   - gitEnv: git's own environment has no tokens or keys, and nothing to ask a person.
 *
 * Git run inside the box is not the host's business: it is contained there.
 */

import { execFile } from "node:child_process";
import { createHash } from "node:crypto";
import { existsSync, readFileSync, realpathSync, statSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";

/** `-c` settings for every git the host runs in a project folder. Put before the subcommand. */
export const SAFE_GIT_FLAGS: string[] = [
	// Programs git would run on its own: on a status or diff, at a commit, over ssh, for a password or a signature.
	"-c", "core.fsmonitor=false",
	"-c", "core.hooksPath=/dev/null",
	"-c", "core.sshCommand=ssh",
	"-c", "core.pager=cat",
	"-c", "core.editor=true",
	"-c", "credential.helper=",
	"-c", "commit.gpgSign=false",
	"-c", "tag.gpgSign=false",
	// `ext::<command>` as a remote's address runs the command.
	"-c", "protocol.ext.allow=never",
	// A folder that looks like a bare repository (HEAD, objects, config) is not a repository unless git is told so.
	"-c", "safe.bareRepository=explicit",
];

/** Names of environment variables that hold a secret. */
const SECRET_NAME = /(TOKEN|SECRET|PASSWORD|PASSWD|API_?KEY|STORE_KEY|PRIVATE_KEY|CREDENTIAL)/i;

/**
 * The environment for git: [base] without secrets (git signs in with the header the app put in its global config, not
 * with the environment), nothing to prompt or page or edit with, no external diff program.
 */
export function gitEnv(base: NodeJS.ProcessEnv = process.env): NodeJS.ProcessEnv {
	const env: NodeJS.ProcessEnv = {};
	for (const [name, value] of Object.entries(base)) if (!SECRET_NAME.test(name)) env[name] = value;
	delete env.GIT_EXTERNAL_DIFF;
	env.GIT_TERMINAL_PROMPT = "0";
	// A repository's `core.askPass` is a program git runs when it wants a password; the environment variable comes first.
	env.GIT_ASKPASS = "true";
	env.GIT_EDITOR = "true";
	env.GIT_PAGER = "cat";
	return env;
}

/** The project's git settings would make git run a program the flags cannot turn off. */
export class UnsafeRepoConfig extends Error {
	constructor(
		readonly file: string,
		readonly key: string,
		why: string,
	) {
		super(
			`This project's git settings (${file}) ${why}: "${key}". The agent may have written it. Open that file, remove the entry, and try again.`,
		);
		this.name = "UnsafeRepoConfig";
	}
}

/** What git-lfs puts in a repository's config; the one program a project's own settings may name. */
const LFS_FILTER: Record<string, string> = {
	clean: "git-lfs clean -- %f",
	smudge: "git-lfs smudge -- %f",
	process: "git-lfs filter-process",
};

/** Why [key] (as `git config --list` writes it: section and name in lower case) is not allowed in a project's settings, or null. */
function whyUnsafe(key: string, value: string): string | null {
	if (key === "include.path" || /^includeif\..+\.path$/.test(key)) return "include another file, which could say anything";
	const filter = /^filter\.(.+)\.(clean|smudge|process)$/.exec(key);
	if (filter) return filter[1] === "lfs" && value === LFS_FILTER[filter[2]] ? null : "run a program on every file git adds or checks out";
	if (/^diff\..+\.(command|textconv)$/.test(key) || key === "diff.external") return "run a program to compare files";
	if (/^merge\..+\.(driver|recursive)$/.test(key)) return "run a program to merge files";
	if (/^credential\..+\.helper$/.test(key)) return "run a program to look up a password";
	if (key === "core.gitproxy") return "run a program to reach a git:// address";
	if (/^submodule\..+\.update$/.test(key) && value.startsWith("!")) return "run a program to update a submodule";
	return null;
}

/**
 * Where git would read repository settings, starting from [start] the way git looks for a repository: this folder and
 * every one above it. Git goes by where the folder really is, so a folder reached through a link is looked at as the
 * folder the link leads to, and the folders above that one.
 */
function configFilesFrom(start: string): string[] {
	const files: string[] = [];
	let dir: string;
	try {
		dir = realpathSync(start);
	} catch {
		dir = resolve(start); // not there: git will say so
	}
	for (;;) {
		const dotGit = join(dir, ".git");
		try {
			const st = statSync(dotGit);
			if (st.isDirectory()) {
				files.push(join(dotGit, "config"), join(dotGit, "config.worktree"));
			} else if (st.isFile()) {
				// A worktree or submodule: `.git` is a file naming the real folder, whose `commondir` names the shared one.
				const target = /^gitdir:\s*(.+)$/m.exec(readFileSync(dotGit, "utf8"))?.[1]?.trim();
				if (target) {
					const gitDir = resolve(dir, target);
					let common = gitDir;
					try {
						common = resolve(gitDir, readFileSync(join(gitDir, "commondir"), "utf8").trim());
					} catch {
						// Not a linked worktree: its own folder holds the settings.
					}
					files.push(join(common, "config"), join(gitDir, "config.worktree"));
				}
			}
		} catch {
			// No .git here.
		}
		// A folder that looks like a bare repository is read as one too (see safe.bareRepository in the flags).
		if (existsSync(join(dir, "HEAD")) && existsSync(join(dir, "objects"))) files.push(join(dir, "config"));
		const parent = dirname(dir);
		if (parent === dir) return files;
		dir = parent;
	}
}

const MAX_CONFIG_BYTES = 1024 * 1024;
const seen = new Map<string, [string, string][]>();

/** The key/value pairs in one config file, as git itself reads them (includes not followed); cached by the file's content. */
async function entriesOf(file: string): Promise<[string, string][]> {
	let text: Buffer;
	try {
		text = readFileSync(file);
	} catch {
		return [];
	}
	if (text.length > MAX_CONFIG_BYTES) throw new UnsafeRepoConfig(file, `${text.length} bytes`, "is far too large to be git's settings");
	const id = `${file}\0${createHash("sha256").update(text).digest("hex")}`;
	const known = seen.get(id);
	if (known) return known;
	const entries = await new Promise<[string, string][]>((done) => {
		// Reading a config file runs nothing in it. Run from a folder that is no repository.
		execFile(
			"git",
			["config", "--file", file, "--list", "-z", "--no-includes"],
			{ cwd: tmpdir(), env: gitEnv(), timeout: 10_000, maxBuffer: 4 * MAX_CONFIG_BYTES },
			(error, stdout) => {
				// A file git cannot read makes every git command fail too; nothing runs from it.
				if (error) return done([]);
				done(
					stdout
						.split("\0")
						.filter(Boolean)
						.map((item) => {
							const at = item.indexOf("\n");
							return (at < 0 ? [item, ""] : [item.slice(0, at), item.slice(at + 1)]) as [string, string];
						}),
				);
			},
		);
	});
	if (seen.size > 500) seen.clear();
	seen.set(id, entries);
	return entries;
}

/**
 * Throws [UnsafeRepoConfig] when the settings of the repository [cwd] is in name a program that SAFE_GIT_FLAGS cannot
 * turn off. Nothing is thrown for a folder that is no repository (git then fails by itself), or one whose settings are
 * ordinary.
 */
export async function assertRepoConfigSafe(cwd: string): Promise<void> {
	for (const file of configFilesFrom(cwd)) {
		for (const [key, value] of await entriesOf(file)) {
			const why = whyUnsafe(key, value);
			if (why) throw new UnsafeRepoConfig(file, key, `would ${why}`);
		}
	}
}
