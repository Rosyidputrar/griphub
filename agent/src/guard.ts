/**
 * The app's inline pi extension: approvals before risky tool calls, plan
 * mode (read-only until the plan is approved), dev-server detection from
 * command output, and a checkpoint before the agent starts changing files.
 */

import { lstatSync, readlinkSync, realpathSync } from "node:fs";
import { readFile } from "node:fs/promises";
import { homedir } from "node:os";
import { basename, dirname, isAbsolute, join, relative, resolve, sep } from "node:path";
import { fileURLToPath } from "node:url";
import { generateUnifiedPatch, type ExtensionAPI } from "@earendil-works/pi-coding-agent";

/**
 * When the agent must ask before acting. `deny_risky` is for runs nobody is watching (a server's background tasks):
 * what `ask_risky` would ask about is refused outright instead, since there is nobody to answer.
 */
export type ApprovalMode = "ask_all" | "ask_risky" | "auto" | "deny_risky";

/** An approval card as the host sends it. */
export interface ApprovalRecord {
	type: "approval";
	approvalId: string;
	toolName: string;
	summary: string;
	reason: string;
	key: string;
	/** For `edit` and `write`: what the file would become, as a unified patch. Absent when it can't be worked out. */
	patch?: string;
}

export interface GuardHooks {
	send(record: object): void;
	/** Snapshot the working tree before the agent's first file change in a run. */
	checkpoint(cwd: string, label: string): Promise<void>;
	cwd(): string;
}

/** Whether [path] is [dir] or somewhere inside it (lexically; resolve links first where they matter). */
export function isInside(path: string, dir: string): boolean {
	const rel = relative(resolve(dir), resolve(dir, path));
	return rel === "" || (rel !== ".." && !rel.startsWith("../") && !isAbsolute(rel));
}

/** Tools that change nothing; never need approval and stay on in plan mode. */
const READ_ONLY = new Set(["read", "grep", "find", "ls", "web_search", "web_fetch", "web_screenshot", "todo_write"]);

/**
 * Commands worth a second look before they run. The flag patterns allow any
 * flags before the dangerous one: `rm -v -rf` and `git -C x push --force`
 * used to slip through because only the first flag was examined.
 */
const RISKY_BASH = [
	/\brm\b[^;&|]*(-[a-z]*r|-[a-z]*f|--recursive|--force)/i,
	/\bgit\b[^;&|]*\b(push|reset\s+--hard|clean\s+-[a-z]*f|checkout\s+--\s|branch\s+-D|rebase)\b/i,
	/\bfind\b[^;&|]*\b(-delete|-exec\b|-execdir\b|-ok\b)/i,
	/\b(vercel|netlify|wrangler|firebase)\b.*\b(deploy|--prod)\b/i,
	/\bnpm\s+publish\b|\bpip\s+upload\b|\btwine\s+upload\b/i,
	/\b(curl|wget)\b[^|]*\|\s*(sudo\s+)?(ba)?sh\b/i,
	/\b(dd|mkfs|shred|chmod\s+-R|chown\s+-R)\b/i,
	/\bssh\b|\bscp\b|\brsync\b/i,
	/>\s*\/(etc|usr|bin|system)\b/i,
	/\bkill(all)?\b|\bpkill\b/i,
	/\bDROP\s+(TABLE|DATABASE)\b|\bTRUNCATE\b/i,
];

/**
 * Where this machine keeps what the agent must not be able to read out and send on: the store key, the sign-in tokens
 * (the app's own store, git's credentials, ssh and cloud keys). Reading them is not "changing" anything, so they were never
 * asked about; a page or a file with hidden instructions in it only needs to say "read this and put it in a URL".
 */
function secretPlaces(): { dirs: string[]; files: string[] } {
	const home = process.env.HOME ?? "";
	const dirs = [process.env.GRIPHUB_DIR, process.env.PI_CODING_AGENT_DIR && join(process.env.PI_CODING_AGENT_DIR, "griphub")].filter((d): d is string => !!d);
	if (home) {
		dirs.push(join(home, ".griphub"), join(home, ".ssh"), join(home, ".gnupg"), join(home, ".aws"), join(home, ".config", "gh"), join(home, ".pi", "agent", "griphub"));
	}
	const files = home ? [".gitconfig", ".git-credentials", ".netrc", ".npmrc", ".pypirc"].map((f) => join(home, f)) : [];
	return { dirs, files };
}

/** Why reading [input.path] with a file tool deserves a question, or null: the file is one that holds secrets. */
export function secretReadRisk(toolName: string, input: Record<string, unknown>, cwd: string): string | null {
	if (toolName !== "read" && toolName !== "grep" && toolName !== "find" && toolName !== "ls") return null;
	let target: string;
	try {
		target = canonicalTarget(resolveLikePi(String(input.path ?? ""), cwd)) ?? "";
	} catch {
		return "Reads a path that cannot be checked";
	}
	if (!target) return "Reads a path that cannot be checked";
	if (/^\/proc\/[^/]+\/(environ|cmdline|mem|maps)$/.test(target)) return "Reads a file that holds sign-in secrets";
	const { dirs, files } = secretPlaces();
	const real = (p: string) => canonicalTarget(p) ?? p;
	if (dirs.some((d) => isInside(target, real(d))) || files.some((f) => target === real(f))) return "Reads a file that holds sign-in secrets";
	return null;
}

/** Commands that name where the secrets are, or print the environment the tokens are in. A list, so a speed bump, not a wall. */
const SECRET_BASH = [
	/\.griphub\b|GRIPHUB_STORE_KEY|integrations\.json|custom-providers\.json/i,
	/\/proc\/[^\s]*\/(environ|cmdline|mem)\b/i,
	/\.git-credentials|\.netrc\b|\.gitconfig\b|\.config\/gh\b/i,
	/\$\{?(GITHUB_TOKEN|GH_TOKEN|VERCEL_TOKEN|CLOUDFLARE_API_TOKEN)\b/,
	/\bprintenv\b|\benv\s*(\||>)/,
];

/** Characters pi turns into a plain space before it looks at a path. */
const UNICODE_SPACES = /[\u00A0\u2000-\u200A\u202F\u205F\u3000]/g;

/**
 * The file a path names when pi's file tools open it: the same steps as pi's own `resolveToCwd` (unusual spaces become
 * spaces, one leading `@` is dropped, `~` is the home folder, `file://` is a path), done here because a check that reads
 * the path any other way approves one file and lets the tool write another (`@/home/x/.ssh/authorized_keys` was
 * "inside the project" to this check and the real file to pi). agent/test/guard-paths.test.mjs compares the two. Throws
 * for a `file://` address pi would refuse too.
 */
export function resolveLikePi(raw: string, cwd: string): string {
	let p = raw.replace(UNICODE_SPACES, " ");
	if (p.startsWith("@")) p = p.slice(1);
	if (p === "~") p = homedir();
	else if (p.startsWith("~/")) p = join(homedir(), p.slice(2));
	if (/^file:\/\//.test(p)) p = fileURLToPath(p);
	return isAbsolute(p) ? resolve(p) : resolve(cwd, p);
}

/**
 * Where a path really leads: links resolved as far as the path exists, then the rest of it as written. A link that
 * leads nowhere (yet) is followed too, since writing through it creates what it points at. Null when that cannot be
 * told (an unreadable folder, a loop of links): the caller then treats the path as outside.
 */
function canonicalTarget(path: string): string | null {
	let head = path;
	const tail: string[] = [];
	for (let steps = 0; steps < 256; steps++) {
		try {
			return join(realpathSync(head), ...tail);
		} catch (e) {
			const code = (e as NodeJS.ErrnoException).code;
			if (code !== "ENOENT" && code !== "ENOTDIR") return null;
		}
		try {
			if (lstatSync(head).isSymbolicLink()) {
				// A relative link is read from the folder it is in, as that folder really is: `..` from a folder reached
				// through a link is the real folder's parent, not the parent of the name it was reached by.
				head = resolve(realpathSync(dirname(head)), readlinkSync(head));
				continue;
			}
		} catch (e) {
			// Not there at all: look at its folder. A folder that cannot be read cannot be told.
			const code = (e as NodeJS.ErrnoException).code;
			if (code !== "ENOENT" && code !== "ENOTDIR") return null;
		}
		const parent = dirname(head);
		if (parent === head) return null;
		tail.unshift(basename(head));
		head = parent;
	}
	return null;
}

const OUTSIDE_PROJECT = "Writes outside the project folder";
const INSIDE_GIT = "Writes inside a .git folder: git runs what is written there";

/**
 * Why a file tool given [raw] needs a look: it would write outside [cwd], through links and all, or into a `.git` folder
 * (hooks, a config that names a program: see gitsafe.ts, which is what actually keeps those from running on the host; a
 * `bash` command can write there without passing here, so this is the common way in, not the only one). Null otherwise.
 */
function writeRisk(raw: string, cwd: string): string | null {
	let target: string;
	try {
		target = resolveLikePi(raw, cwd);
	} catch {
		return OUTSIDE_PROJECT;
	}
	const real = canonicalTarget(target);
	const root = canonicalTarget(resolve(cwd));
	if (real === null || root === null || !isInside(real, root)) return OUTSIDE_PROJECT;
	return relative(root, real).split(sep).includes(".git") ? INSIDE_GIT : null;
}

/**
 * Why a call deserves a second look, or null. `mcp` says whether tools from MCP servers count: a person is asked about
 * them, but an unattended run may use the servers the user set up (as background runs always could).
 */
export function riskOf(toolName: string, input: Record<string, unknown>, cwd: string, mcp = true): string | null {
	if (READ_ONLY.has(toolName)) return secretReadRisk(toolName, input, cwd);
	// A background job is a bash command that runs a while: the same second look.
	if (toolName === "bash" || toolName === "background_job") {
		const cmd = String(input.command ?? "");
		if (SECRET_BASH.some((re) => re.test(cmd))) return "This command can read sign-in secrets";
		const hit = RISKY_BASH.find((re) => re.test(cmd));
		return hit ? "This command can delete data, publish or reach other machines" : null;
	}
	if (toolName === "write" || toolName === "edit") {
		// Compared where the file really is (see resolveLikePi, canonicalTarget): /a/bc is not inside /a/b, and neither
		// is a file reached through a link that leads out of it.
		return writeRisk(String(input.path ?? ""), cwd);
	}
	// Unknown/custom tools (MCP and friends) are treated as risky.
	return mcp && toolName.startsWith("mcp_") ? "External tool from an MCP server" : null;
}

/** Files and patches bigger than this aren't previewed on the card: the path alone, as before. */
const PATCH_MAX_FILE = 512 * 1024;
const PATCH_MAX_CHARS = 64 * 1024;

/** A path as the file tools take it (see resolveLikePi). */
function toolPath(raw: string, cwd: string): string {
	return resolveLikePi(raw, cwd);
}

/** The replacements an `edit` call asks for, in each shape models send them (pi's edit tool takes the same ones). */
export function editsOf(input: Record<string, unknown>): { oldText: string; newText: string }[] | null {
	const isEdit = (e: unknown): e is { oldText: string; newText: string } =>
		!!e && typeof (e as any).oldText === "string" && typeof (e as any).newText === "string";
	let edits: unknown = input.edits;
	if (typeof edits === "string") {
		try {
			edits = JSON.parse(edits);
		} catch {
			return null;
		}
	}
	const out = Array.isArray(edits) ? [...edits] : isEdit(edits) ? [edits] : [];
	if (isEdit(input)) out.push({ oldText: input.oldText, newText: input.newText });
	return out.length > 0 && out.every(isEdit) ? out : null;
}

/**
 * What an `edit` or a `write` would do to its file, as a unified patch for the approval card, so the change is seen
 * before it is allowed. Undefined when it can't be told for certain (an edit's text is missing from the file or is
 * there twice, the file is unreadable or too big): the card then shows the path alone and the tool reports its own
 * error if it runs.
 */
export async function proposedPatch(toolName: string, input: Record<string, unknown>, cwd: string): Promise<string | undefined> {
	if ((toolName !== "edit" && toolName !== "write") || typeof input.path !== "string" || !input.path) return undefined;
	const file = toolPath(input.path, cwd);
	let before = "";
	try {
		const buf = await readFile(file);
		if (buf.length > PATCH_MAX_FILE || buf.includes(0)) return undefined;
		before = buf.toString("utf8");
	} catch (e) {
		// A new file: everything is added. An edit needs the file to exist.
		if ((e as NodeJS.ErrnoException).code !== "ENOENT" || toolName === "edit") return undefined;
	}
	const lf = (t: string) => t.replace(/\r\n/g, "\n");
	before = lf(before);
	let after: string;
	if (toolName === "write") {
		if (typeof input.content !== "string" || input.content.length > PATCH_MAX_FILE) return undefined;
		after = lf(input.content);
	} else {
		const edits = editsOf(input);
		if (!edits) return undefined;
		// Every edit is matched against the original, once, as pi's edit tool does; overlapping ones are refused there.
		const spots: { at: number; length: number; text: string }[] = [];
		for (const e of edits) {
			const old = lf(e.oldText);
			const at = old ? before.indexOf(old) : -1;
			if (at < 0 || before.indexOf(old, at + 1) >= 0) return undefined;
			spots.push({ at, length: old.length, text: lf(e.newText) });
		}
		spots.sort((a, b) => a.at - b.at);
		for (let i = 1; i < spots.length; i++) if (spots[i].at < spots[i - 1].at + spots[i - 1].length) return undefined;
		after = before;
		for (const s of [...spots].reverse()) after = after.slice(0, s.at) + s.text + after.slice(s.at + s.length);
	}
	if (after === before) return undefined;
	const patch = generateUnifiedPatch(input.path, before, after, 3);
	return patch.length > PATCH_MAX_CHARS ? undefined : patch;
}

/** Summary line for the approval card. */
function describe(toolName: string, input: Record<string, unknown>) {
	if (toolName === "bash" || toolName === "background_job") return String(input.command ?? "");
	if (typeof input.path === "string") return input.path;
	return JSON.stringify(input).slice(0, 400);
}

export class Guard {
	mode: ApprovalMode = "ask_risky";
	/** Plan mode: only read-only tools until the user approves the plan. */
	planMode = false;
	/** "Always allow" choices for this app run, keyed by the full command/pattern. */
	private allowed = new Set<string>();
	/** Waiting approvals with the record that asked, so an app that reconnects can show them again. */
	private pending = new Map<string, { resolve: (allow: boolean) => void; record: ApprovalRecord }>();
	/** Random per-process token: approval ids must never repeat across host restarts. */
	private readonly epoch = Math.random().toString(36).slice(2, 8);
	private next = 1;
	private changedThisRun = false;

	constructor(private readonly hooks: GuardHooks) {}

	reply(id: string, allow: boolean, always = false, key?: string) {
		const waiting = this.pending.get(id);
		this.pending.delete(id);
		if (allow && always && key) this.allowed.add(key);
		waiting?.resolve(allow);
	}

	/** Approval for something outside a tool call (e.g. an issue-triggered run). Reuses the same card and reply path; the empty key can never be "always"-allowed. */
	askApproval(toolName: string, summary: string, reason: string): Promise<boolean> {
		return this.request({ toolName, summary, reason, key: "" });
	}

	/**
	 * The approvals still waiting for an answer, as the records that asked for them. A server agent's app may have been
	 * away when they were sent (and the replay buffer may no longer hold them); it asks for these after reconnecting.
	 */
	pendingApprovals(): ApprovalRecord[] {
		return [...this.pending.values()].map((w) => w.record);
	}

	/** Deny everything still waiting (e.g. when the run is aborted). */
	cancelAll() {
		for (const [id, waiting] of this.pending) {
			this.hooks.send({ type: "approval_dismiss", approvalId: id });
			waiting.resolve(false);
		}
		this.pending.clear();
	}

	private async ask(toolName: string, input: Record<string, unknown>, reason: string, key: string) {
		const patch = await proposedPatch(toolName, input, this.hooks.cwd()).catch(() => undefined);
		return this.request({ toolName, summary: describe(toolName, input), reason, key, ...(patch ? { patch } : {}) });
	}

	private request(fields: Omit<ApprovalRecord, "type" | "approvalId">): Promise<boolean> {
		const record: ApprovalRecord = { type: "approval", approvalId: `a${this.epoch}-${this.next++}`, ...fields };
		this.hooks.send(record);
		return new Promise<boolean>((resolve) => this.pending.set(record.approvalId, { resolve, record }));
	}

	/** The pi extension factory. */
	extension = (pi: ExtensionAPI) => {
		pi.on("agent_start", () => {
			this.changedThisRun = false;
		});

		pi.on("tool_call", async (event) => {
			const input = event.input as Record<string, unknown>;
			const cwd = this.hooks.cwd();

			// The plan in plan mode is the numbered text the user approves; the checklist comes after.
			if (this.planMode && event.toolName === "todo_write") {
				return {
					block: true,
					reason:
						"Plan mode is on: write the plan as a numbered list for the user to approve. Call todo_write once it is approved.",
				};
			}

			if (this.planMode && !READ_ONLY.has(event.toolName)) {
				return {
					block: true,
					reason:
						"Plan mode is on: do not change anything yet. Finish the plan as a numbered list and ask the user to approve it.",
				};
			}

			// Reading a file of secrets is asked about in every mode but "bypass all", read-only as it is.
			const secret = this.mode === "auto" ? null : secretReadRisk(event.toolName, input, cwd);
			const byMode =
				this.mode === "ask_all"
					? READ_ONLY.has(event.toolName)
						? null
						: "Approval required for every change"
					: this.mode === "ask_risky"
						? riskOf(event.toolName, input, cwd)
						: this.mode === "deny_risky"
							? riskOf(event.toolName, input, cwd, false)
							: null;
			const risk = secret ?? byMode;
			if (risk && this.mode === "deny_risky") {
				return {
					block: true,
					reason: `Refused: nobody is watching this run, so actions that need approval are not allowed (${risk}). Do not look for a way around this; finish what you safely can and say what is left for the user.`,
				};
			}
			if (risk) {
				// "Always allow" stores the FULL pattern. Storing only the
				// first two words let `cd app && git push` also allow
				// `cd app && rm -rf ~`; storing only the tool name let one
				// write allow every write.
				const key =
					event.toolName === "bash" || event.toolName === "background_job"
						? `${event.toolName}:${String(input.command ?? "").trim().replace(/\s+/g, " ")}`
						: event.toolName === "write" || event.toolName === "edit"
							? `${event.toolName}:${String(input.path ?? "")}`
							: `${event.toolName}:${JSON.stringify(input).slice(0, 400)}`;
				if (!this.allowed.has(key)) {
					const ok = await this.ask(event.toolName, input, risk, key);
					if (!ok) return { block: true, reason: "The user declined this action. Ask what they would like instead." };
				}
			}

			// First change in this run: snapshot so the user can undo the whole run.
			if (!READ_ONLY.has(event.toolName) && !this.changedThisRun) {
				this.changedThisRun = true;
				await this.hooks.checkpoint(cwd, "Before the agent's changes").catch(() => {});
			}
			return undefined;
		});

		pi.on("tool_result", (event) => {
			if (event.toolName !== "bash") return;
			const text = event.content.map((c: any) => (c.type === "text" ? c.text : "")).join("\n");
			const found = new Set<number>();
			for (const m of text.matchAll(/(?:localhost|127\.0\.0\.1|0\.0\.0\.0|\[::\]):(\d{2,5})\b/g)) {
				const port = Number(m[1]);
				if (port >= 1024 && port <= 65535) found.add(port);
			}
			for (const port of found) this.hooks.send({ type: "dev_server", port, url: `http://localhost:${port}` });
		});
	};
}
