/**
 * Project tools for the app: code search, SQLite browsing, test detection,
 * public tunnels for dev servers, token/cost usage, prompt templates and
 * backups (zip read/write without native tools).
 */

import { type ChildProcess, spawn } from "node:child_process";
import { existsSync, mkdirSync, readdirSync, readFileSync, statSync, unlinkSync, writeFileSync } from "node:fs";
import { basename, dirname, join, relative } from "node:path";
import { deflateRawSync, inflateRawSync } from "node:zlib";

// ---------------------------------------------------------------------------
// Search (ripgrep)

export interface SearchMatch {
	path: string;
	line: number;
	text: string;
}

export function search(cwd: string, query: string, opts: { regex?: boolean; caseSensitive?: boolean; glob?: string }) {
	return new Promise<{ matches: SearchMatch[]; truncated: boolean }>((resolve, reject) => {
		const args = ["--json", "--max-count", "50", "--max-columns", "300", "--hidden", "-g", "!.git"];
		if (!opts.regex) args.push("--fixed-strings");
		if (!opts.caseSensitive) args.push("--smart-case");
		if (opts.glob) args.push("-g", opts.glob);
		args.push("--", query, ".");
		const child = spawn("rg", args, { cwd, env: process.env });
		const matches: SearchMatch[] = [];
		let buf = "";
		let truncated = false;
		child.stdout.on("data", (chunk) => {
			buf += chunk;
			let nl: number;
			while ((nl = buf.indexOf("\n")) >= 0) {
				const line = buf.slice(0, nl);
				buf = buf.slice(nl + 1);
				try {
					const ev = JSON.parse(line);
					if (ev.type !== "match") continue;
					if (matches.length >= 500) {
						truncated = true;
						child.kill();
						return;
					}
					matches.push({
						path: String(ev.data.path.text ?? "").replace(/^\.\//, ""),
						line: ev.data.line_number,
						text: String(ev.data.lines.text ?? "").replace(/\n$/, ""),
					});
				} catch {}
			}
		});
		child.on("error", reject);
		child.on("close", () => resolve({ matches, truncated }));
	});
}

// ---------------------------------------------------------------------------
// Files by name (the composer's @ mentions)

/** Folders never offered as @ mentions wherever they are: dependencies, caches and build output. */
const SKIP_DIRS = new Set([".git", "node_modules", ".dart_tool", "build", "dist", ".next", ".venv", "venv", "__pycache__", ".gradle", "Pods", "target", ".cache"]);
const LIST_CAP = 20_000;

/** The project's files, briefly remembered: one list per few seconds of typing, not one per keystroke. */
let listed: { cwd: string; at: number; files: string[]; truncated: boolean } | null = null;

/**
 * The project's top `.gitignore`, as a test of a path from the project's top: what ripgrep leaves out, for the walk
 * that stands in for it where there is no ripgrep (some phones, some CI runners). Covers the common forms: a name
 * (`secret`, matched in any folder), a path (`/dist`, `docs/build`), a folder only (`tmp/`), and `*`, `?`, `**`
 * wildcards. A negation (`!keep.me`) isn't followed: a file it brings back stays out of the list, which costs an @
 * suggestion, never offers an ignored file.
 */
export function gitignoreTest(cwd: string): (rel: string, dir: boolean) => boolean {
	let text = "";
	try {
		text = readFileSync(join(cwd, ".gitignore"), "utf8");
	} catch {
		return () => false;
	}
	const rules: { re: RegExp; dirOnly: boolean; whole: boolean }[] = [];
	for (const raw of text.split(/\r?\n/)) {
		let line = raw.trim();
		if (!line || line.startsWith("#") || line.startsWith("!")) continue;
		const dirOnly = line.endsWith("/");
		if (dirOnly) line = line.replace(/\/+$/, "");
		const anchored = line.startsWith("/");
		if (anchored) line = line.replace(/^\/+/, "");
		if (!line) continue;
		const esc = (part: string) => part.replace(/[.+^${}()|[\]\\]/g, "\\$&").replace(/\*/g, "[^/]*").replace(/\?/g, "[^/]");
		// `**/` is any number of folders, none included; another `**` is anything.
		const glob = line
			.split("**/")
			.map((p) => p.split("**").map(esc).join(".*"))
			.join("(?:.*/)?");
		rules.push({ re: new RegExp(`^${glob}$`), dirOnly, whole: anchored || line.includes("/") });
	}
	return (rel, dir) =>
		rules.some((r) => (!r.dirOnly || dir) && (r.whole ? r.re.test(rel) : r.re.test(rel.slice(rel.lastIndexOf("/") + 1))));
}

function walk(cwd: string): { files: string[]; truncated: boolean } {
	const ignored = gitignoreTest(cwd);
	const files: string[] = [];
	const stack = [""];
	while (stack.length) {
		const rel = stack.pop()!;
		let names: import("node:fs").Dirent[];
		try {
			names = readdirSync(join(cwd, rel), { withFileTypes: true });
		} catch {
			continue;
		}
		for (const d of names) {
			const path = rel ? `${rel}/${d.name}` : d.name;
			if (d.isDirectory()) {
				if (!SKIP_DIRS.has(d.name) && !ignored(path, true)) stack.push(path);
			} else if (d.isFile() && !ignored(path, false)) {
				files.push(path);
				if (files.length >= LIST_CAP) return { files, truncated: true };
			}
		}
	}
	return { files, truncated: false };
}

/** All of the project's files: ripgrep's list (which keeps out what .gitignore does), or a plain walk without it. */
function projectFiles(cwd: string): Promise<{ files: string[]; truncated: boolean }> {
	if (listed && listed.cwd === cwd && Date.now() - listed.at < 5_000) return Promise.resolve(listed);
	return new Promise((resolve) => {
		const files: string[] = [];
		let buf = "";
		let truncated = false;
		let done = false;
		const finish = (r: { files: string[]; truncated: boolean }) => {
			if (done) return;
			done = true;
			listed = { cwd, at: Date.now(), ...r };
			resolve(r);
		};
		const args = ["--files", "--hidden", "--no-require-git", ...[...SKIP_DIRS].flatMap((d) => ["-g", `!${d}/`])];
		const child = spawn("rg", args, { cwd, env: process.env });
		child.stdout.on("data", (chunk) => {
			buf += chunk;
			let nl: number;
			while ((nl = buf.indexOf("\n")) >= 0) {
				const line = buf.slice(0, nl).replace(/^\.\//, "");
				buf = buf.slice(nl + 1);
				if (!line) continue;
				files.push(line);
				if (files.length >= LIST_CAP) {
					truncated = true;
					child.kill();
					return finish({ files, truncated });
				}
			}
		});
		child.on("error", () => finish(walk(cwd)));
		child.on("close", (code) => finish(code === 0 || code === 1 || truncated ? { files, truncated } : walk(cwd)));
	});
}

/**
 * How well [path] answers [query], higher is better, or -1 when it doesn't: the file's name containing it beats a
 * folder containing it, which beats its letters merely appearing in order ("chscr" for chat_screen); shorter paths
 * win ties.
 */
export function fileScore(path: string, query: string): number {
	const p = path.toLowerCase();
	const q = query.toLowerCase();
	if (!q) return 1000 - p.length;
	const name = p.slice(p.lastIndexOf("/") + 1);
	if (name.startsWith(q)) return 4000 - p.length;
	if (name.includes(q)) return 3000 - p.length;
	if (p.includes(q)) return 2000 - p.length;
	let i = 0;
	for (const c of p) if (c === q[i]) i++;
	return i === q.length ? 1000 - p.length : -1;
}

/** The project files best matching [query], for the composer's @ list. */
export async function findFiles(cwd: string, query: string, limit = 30): Promise<{ files: string[]; truncated: boolean }> {
	const { files, truncated } = await projectFiles(cwd);
	const scored: [string, number][] = [];
	for (const f of files) {
		const s = fileScore(f, query.trim());
		if (s >= 0) scored.push([f, s]);
	}
	scored.sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0]));
	return { files: scored.slice(0, Math.max(1, Math.min(limit, 100))).map(([f]) => f), truncated };
}

// ---------------------------------------------------------------------------
// SQLite

async function openDb(path: string) {
	const { DatabaseSync } = await import("node:sqlite");
	return new DatabaseSync(path, { readOnly: false } as any);
}

export async function dbTables(path: string) {
	const db = await openDb(path);
	try {
		const rows = db.prepare("SELECT name, type FROM sqlite_master WHERE type IN ('table','view') AND name NOT LIKE 'sqlite_%' ORDER BY name").all() as any[];
		return rows.map((r) => {
			let count: number | null = null;
			try {
				count = (db.prepare(`SELECT COUNT(*) AS n FROM "${String(r.name).replace(/"/g, '""')}"`).get() as any).n;
			} catch {}
			return { name: r.name, type: r.type, rows: count };
		});
	} finally {
		db.close();
	}
}

export async function dbQuery(path: string, sql: string, limit = 200) {
	const db = await openDb(path);
	try {
		const stmt = db.prepare(sql);
		if (/^\s*(select|pragma|with|explain)\b/i.test(sql)) {
			const rows = (stmt.all() as any[]).slice(0, limit);
			const columns = rows.length ? Object.keys(rows[0]) : [];
			return { columns, rows: rows.map((r) => columns.map((c) => r[c])), changes: null };
		}
		const info = stmt.run() as any;
		return { columns: [], rows: [], changes: Number(info.changes ?? 0) };
	} finally {
		db.close();
	}
}

// ---------------------------------------------------------------------------
// Tests: figure out how this project runs its tests.

export function detectTests(cwd: string): { command: string; framework: string } | null {
	const has = (f: string) => existsSync(join(cwd, f));
	if (has("package.json")) {
		try {
			const pkg = JSON.parse(readFileSync(join(cwd, "package.json"), "utf8"));
			if (pkg.scripts?.test && !/no test specified/.test(pkg.scripts.test)) return { command: "npm test --silent", framework: "npm" };
		} catch {}
	}
	if (has("pytest.ini") || has("pyproject.toml") || has("tests") || has("setup.cfg")) return { command: "python3 -m pytest -q", framework: "pytest" };
	if (has("go.mod")) return { command: "go test ./...", framework: "go" };
	if (has("Cargo.toml")) return { command: "cargo test", framework: "cargo" };
	if (has("pubspec.yaml")) return { command: "dart test", framework: "dart" };
	if (has("Makefile")) return { command: "make test", framework: "make" };
	return null;
}

// ---------------------------------------------------------------------------
// Tunnels: expose a local port through localhost.run over ssh (no binaries).

export class Tunnels {
	private open = new Map<number, { proc: ChildProcess; url: string | null }>();

	list() {
		return [...this.open.entries()].map(([port, t]) => ({ port, url: t.url }));
	}

	start(port: number, onUpdate: (u: { port: number; url: string | null; closed?: boolean; error?: string }) => void) {
		this.stop(port);
		const proc = spawn(
			"ssh",
			["-o", "StrictHostKeyChecking=accept-new", "-o", "ServerAliveInterval=30", "-o", "ExitOnForwardFailure=yes", "-R", `80:localhost:${port}`, "nokey@localhost.run", "--", "--output", "json"],
			{ env: process.env },
		);
		const entry = { proc, url: null as string | null };
		this.open.set(port, entry);
		return new Promise<string>((resolve, reject) => {
			let text = "";
			const feed = (chunk: Buffer) => {
				text += chunk.toString("utf8");
				const m = text.match(/https:\/\/[a-z0-9-]+\.(?:lhr\.life|localhost\.run)\b/);
				if (m && !entry.url) {
					entry.url = m[0];
					onUpdate({ port, url: entry.url });
					resolve(entry.url);
				}
			};
			proc.stdout.on("data", feed);
			proc.stderr.on("data", feed);
			proc.on("error", reject);
			proc.on("close", (code) => {
				// Only the current entry may clear the port: start() kills
				// the previous process first, and its late close event must
				// not wipe the replacement tunnel's entry.
				if (this.open.get(port) === entry) {
					this.open.delete(port);
					onUpdate({ port, url: null, closed: true });
				}
				if (!entry.url) reject(new Error(`Tunnel closed (${code}): ${text.trim().split("\n").slice(-2).join(" ")}`));
			});
			setTimeout(() => !entry.url && reject(new Error("Tunnel did not open within 30 seconds")), 30_000);
		});
	}

	stop(port: number) {
		this.open.get(port)?.proc.kill();
		this.open.delete(port);
	}

	stopAll() {
		for (const port of [...this.open.keys()]) this.stop(port);
	}
}

// ---------------------------------------------------------------------------
// Usage: tokens and cost from session files.

export interface UsageRow {
	day: string;
	provider: string;
	model: string;
	input: number;
	output: number;
	cacheRead: number;
	cacheWrite: number;
	/** pi's own cost (other providers that report one). */
	cost: number;
	/** Estimated GripHub credits by the router's rule, summed per request; null when the price is unknown. */
	credits: number | null;
	requests: number;
}

/** Calendar day (YYYY-MM-DD) in Asia/Jakarta: the user's day, not UTC. */
export function wibDay(ts: number): string {
	return new Intl.DateTimeFormat("en-CA", {
		timeZone: "Asia/Jakarta",
		year: "numeric",
		month: "2-digit",
		day: "2-digit",
	}).format(new Date(ts));
}

/**
 * Usage per day and model from the chat files, for the chart and as the
 * offline fallback. Every billed request counts: assistant replies, and the
 * requests pi makes on its own (cache warming, compaction and branch
 * summaries), which used to be skipped. Each request is priced on its own,
 * so the router's per-request floor applies.
 */
export function usageSummary(
	sessionsDir: string,
	days = 30,
	estimate: (model: string, u: any) => number | null = () => null,
	/** Only requests at or after this instant (ms). */
	fromTs?: number,
) {
	const since = Math.max(Date.now() - days * 86400_000, fromTs ?? 0);
	const rows = new Map<string, UsageRow>();
	const add = (ts: number, provider: string, model: string, u: any) => {
		if (!u || ts < since) return;
		const day = wibDay(ts);
		const key = `${day}|${provider}|${model}`;
		const r = rows.get(key) ?? { day, provider, model, input: 0, output: 0, cacheRead: 0, cacheWrite: 0, cost: 0, credits: 0, requests: 0 };
		r.input += u.input ?? 0;
		r.output += u.output ?? 0;
		r.cacheRead += u.cacheRead ?? 0;
		r.cacheWrite += u.cacheWrite ?? 0;
		r.cost += u.cost?.total ?? 0;
		const c = estimate(model, u);
		r.credits = c === null || r.credits === null ? null : r.credits + c;
		r.requests += 1;
		rows.set(key, r);
	};
	const walk = (dir: string) => {
		if (!existsSync(dir)) return;
		for (const name of readdirSync(dir)) {
			const p = join(dir, name);
			const st = statSync(p);
			if (st.isDirectory()) walk(p);
			else if (name.endsWith(".jsonl") && st.mtimeMs >= since) {
				let last: { provider: string; model: string } | undefined;
				for (const line of readFileSync(p, "utf8").split("\n")) {
					if (!line.includes('"usage"')) continue;
					try {
						const e = JSON.parse(line);
						const ts = typeof e.message?.timestamp === "number" ? e.message.timestamp : Date.parse(e.timestamp);
						if (e.type === "message" && e.message?.role === "assistant" && e.message.usage) {
							const m = e.message;
							// Failed requests are not billed by the router.
							if (m.stopReason === "error" && !(m.usage.output > 0)) continue;
							last = { provider: m.provider, model: m.model };
							add(ts, m.provider, m.model, m.usage);
						} else if (e.type === "usage" && e.usage && e.model) {
							add(ts, e.provider, e.model, e.usage);
						} else if ((e.type === "compaction" || e.type === "branch_summary") && e.usage && last) {
							add(ts, last.provider, last.model, e.usage);
						}
					} catch {}
				}
			}
		}
	};
	walk(sessionsDir);
	return [...rows.values()].sort((a, b) => (a.day < b.day ? 1 : -1));
}

// ---------------------------------------------------------------------------
// Prompt templates (<agentDir>/prompts/*.md), expanded by pi as /name.

const DEFAULT_TEMPLATES: Record<string, string> = {
	review: `---\ndescription: Review recent changes for bugs and risks\nargument-hint: "[focus]"\n---\nReview the changes in this project (git diff, or the files you changed in this chat). Focus on \${1:-correctness, security and edge cases}. List concrete problems with file and line, most severe first, then suggest fixes.\n`,
	test: `---\ndescription: Write and run tests\nargument-hint: "[what to test]"\n---\nWrite tests for \${1:-the code changed recently}. Use the project's existing test framework (or the standard one for its language), run them, and fix failures you introduced.\n`,
	explain: `---\ndescription: Explain code simply\nargument-hint: "[file or topic]"\n---\nExplain \${1:-this project} clearly: what it does, how the main pieces fit together, and anything surprising. Use short sections and examples.\n`,
	refactor: `---\ndescription: Refactor without changing behaviour\nargument-hint: "<target>"\n---\nRefactor $1 for readability and maintainability without changing behaviour. Keep the public interface stable and run the tests afterwards.\n`,
	fix: `---\ndescription: Find and fix a bug\nargument-hint: "<symptom>"\n---\nThere is a bug: $@\nReproduce it, find the root cause, fix it with the smallest correct change, and verify the fix.\n`,
	commit: `---\ndescription: Commit current changes with a good message\n---\nLook at git status and the diff, then stage and commit the changes with a concise, descriptive message. Do not push.\n`,
	docs: `---\ndescription: Write or update the README\n---\nWrite or update README.md for this project: what it is, how to install, run and test it, with examples.\n`,
};

export class Templates {
	readonly dir: string;
	constructor(agentDir: string) {
		this.dir = join(agentDir, "prompts");
	}

	seed(seededFile: string) {
		mkdirSync(this.dir, { recursive: true });
		const seeded: string[] = existsSync(seededFile) ? JSON.parse(readFileSync(seededFile, "utf8")) : [];
		for (const [name, body] of Object.entries(DEFAULT_TEMPLATES)) {
			if (seeded.includes(name)) continue;
			if (!existsSync(join(this.dir, `${name}.md`))) writeFileSync(join(this.dir, `${name}.md`), body);
			seeded.push(name);
		}
		mkdirSync(dirname(seededFile), { recursive: true });
		writeFileSync(seededFile, JSON.stringify(seeded));
	}

	list() {
		if (!existsSync(this.dir)) return [];
		return readdirSync(this.dir)
			.filter((f) => f.endsWith(".md"))
			.map((f) => {
				const body = readFileSync(join(this.dir, f), "utf8");
				const fm = body.match(/^---\r?\n([\s\S]*?)\r?\n---\r?\n?/);
				const meta: Record<string, string> = {};
				for (const l of (fm?.[1] ?? "").split("\n")) {
					const m = l.match(/^([\w-]+):\s*(.*)$/);
					if (m) meta[m[1]] = m[2].replace(/^["']|["']$/g, "");
				}
				const text = fm ? body.slice(fm[0].length) : body;
				return {
					name: f.slice(0, -3),
					description: meta.description || text.trim().split("\n")[0].slice(0, 80),
					argumentHint: meta["argument-hint"] ?? null,
					body: text,
				};
			})
			.sort((a, b) => a.name.localeCompare(b.name));
	}

	save(name: string, description: string, body: string, argumentHint?: string) {
		const clean = name.toLowerCase().replace(/[^a-z0-9-]+/g, "-").replace(/^-|-$/g, "");
		if (!clean) throw new Error("Give the template a name");
		mkdirSync(this.dir, { recursive: true });
		const fm = [`description: ${description.replace(/\n/g, " ")}`, argumentHint ? `argument-hint: "${argumentHint}"` : null].filter(Boolean).join("\n");
		writeFileSync(join(this.dir, `${clean}.md`), `---\n${fm}\n---\n${body.trim()}\n`);
		return clean;
	}

	remove(name: string) {
		const p = join(this.dir, `${basename(name)}.md`);
		if (existsSync(p)) unlinkSync(p);
	}
}

// ---------------------------------------------------------------------------
// Zip (stored/deflated) for backups, without native tools.

const CRC_TABLE = (() => {
	const t = new Uint32Array(256);
	for (let n = 0; n < 256; n++) {
		let c = n;
		for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
		t[n] = c >>> 0;
	}
	return t;
})();

export function crc32(buf: Buffer) {
	let c = 0xffffffff;
	for (let i = 0; i < buf.length; i++) c = CRC_TABLE[(c ^ buf[i]) & 0xff] ^ (c >>> 8);
	return (c ^ 0xffffffff) >>> 0;
}

export function writeZip(entries: { name: string; data: Buffer }[]): Buffer {
	const locals: Buffer[] = [];
	const centrals: Buffer[] = [];
	let offset = 0;
	for (const e of entries) {
		const name = Buffer.from(e.name.replace(/\\/g, "/"), "utf8");
		const deflated = deflateRawSync(e.data);
		const useDeflate = deflated.length < e.data.length;
		const body = useDeflate ? deflated : e.data;
		const crc = crc32(e.data);
		const local = Buffer.alloc(30);
		local.writeUInt32LE(0x04034b50, 0);
		local.writeUInt16LE(20, 4);
		local.writeUInt16LE(0x0800, 6); // UTF-8 names
		local.writeUInt16LE(useDeflate ? 8 : 0, 8);
		local.writeUInt32LE(crc, 14);
		local.writeUInt32LE(body.length, 18);
		local.writeUInt32LE(e.data.length, 22);
		local.writeUInt16LE(name.length, 26);
		locals.push(local, name, body);
		const central = Buffer.alloc(46);
		central.writeUInt32LE(0x02014b50, 0);
		central.writeUInt16LE(20, 4);
		central.writeUInt16LE(20, 6);
		central.writeUInt16LE(0x0800, 8);
		central.writeUInt16LE(useDeflate ? 8 : 0, 10);
		central.writeUInt32LE(crc, 16);
		central.writeUInt32LE(body.length, 20);
		central.writeUInt32LE(e.data.length, 24);
		central.writeUInt16LE(name.length, 28);
		central.writeUInt32LE(offset, 42);
		centrals.push(central, name);
		offset += 30 + name.length + body.length;
	}
	const cd = Buffer.concat(centrals);
	const end = Buffer.alloc(22);
	end.writeUInt32LE(0x06054b50, 0);
	end.writeUInt16LE(entries.length, 8);
	end.writeUInt16LE(entries.length, 10);
	end.writeUInt32LE(cd.length, 12);
	end.writeUInt32LE(offset, 16);
	return Buffer.concat([...locals, cd, end]);
}

export function readZip(buf: Buffer): { name: string; data: Buffer }[] {
	const eocd = buf.lastIndexOf(Buffer.from([0x50, 0x4b, 0x05, 0x06]));
	if (eocd < 0) throw new Error("Not a zip file");
	const count = buf.readUInt16LE(eocd + 10);
	let p = buf.readUInt32LE(eocd + 16);
	const out: { name: string; data: Buffer }[] = [];
	for (let i = 0; i < count; i++) {
		const method = buf.readUInt16LE(p + 10);
		const size = buf.readUInt32LE(p + 20);
		const nameLen = buf.readUInt16LE(p + 28);
		const extra = buf.readUInt16LE(p + 30);
		const comment = buf.readUInt16LE(p + 32);
		const local = buf.readUInt32LE(p + 42);
		const name = buf.subarray(p + 46, p + 46 + nameLen).toString("utf8");
		const lNameLen = buf.readUInt16LE(local + 26);
		const lExtra = buf.readUInt16LE(local + 28);
		const start = local + 30 + lNameLen + lExtra;
		const raw = buf.subarray(start, start + size);
		if (!name.endsWith("/")) out.push({ name, data: method === 8 ? inflateRawSync(raw) : Buffer.from(raw) });
		p += 46 + nameLen + extra + comment;
	}
	return out;
}

/** Every file under `dir`, relative to `base`, skipping heavy/derived folders. */
export function collectFiles(dir: string, base: string, skip = new Set(["node_modules", ".git", "bin", ".cache"])) {
	const out: { name: string; data: Buffer }[] = [];
	const walk = (d: string) => {
		if (!existsSync(d)) return;
		for (const name of readdirSync(d)) {
			if (skip.has(name)) continue;
			const p = join(d, name);
			const st = statSync(p);
			if (st.isDirectory()) walk(p);
			else if (st.isFile() && st.size < 25 * 1024 * 1024) out.push({ name: relative(base, p), data: readFileSync(p) });
		}
	};
	walk(dir);
	return out;
}
