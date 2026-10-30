/**
 * Automatic backups of a server agent, for the phone to keep (server_agent.md).
 *
 * Every hour the daemon checks whether anything changed since the last backup and, if so, writes a new one: the
 * agent's data (chats, skills, prompts, runs), its saved secrets (API keys, tokens, MCP servers), the whole workspace
 * with each project's .git, and the deploy SSH key. Dependencies are left out (node_modules, virtualenvs, caches):
 * they come back with an install. The newest few are kept; the app fetches the newest to the phone, and offers it
 * when the user switches back to the agent on the phone.
 *
 * A backup is one zip, encrypted as it is written (AES-256-GCM) with a key the phone made and gave the server: no
 * plaintext copy is ever on disk, and a copy that leaves the phone or the server is unreadable without that key. The
 * server needs the key to write backups, and it holds all of the data anyway; the key protects the copies.
 *
 *   file = "GHB1" | iv (12) | ciphertext of the zip | GCM tag (16)
 *
 * Secrets are stored encrypted at rest with each machine's own store key (secure.ts), which never leaves it; in a
 * backup they are under `secure/`, decrypted, inside the encrypted zip, and the phone encrypts them again with its key.
 */

import { createCipheriv, createDecipheriv, createHash, randomBytes } from "node:crypto";
import {
	closeSync,
	existsSync,
	fstatSync,
	lstatSync,
	mkdirSync,
	openSync,
	readdirSync,
	readSync,
	renameSync,
	rmSync,
	statSync,
	writeSync,
} from "node:fs";
import { readFile } from "node:fs/promises";
import { hostname } from "node:os";
import { join, relative, sep } from "node:path";
import { promisify } from "node:util";
import { deflateRaw, inflateRawSync } from "node:zlib";
import { readSecureJson, writeSecureJson } from "./secure.js";
import { crc32 } from "./workbench.js";

const deflate = promisify(deflateRaw);

const MAGIC = Buffer.from("GHB1");

/** Folders that are dependencies or caches, left out wherever they are: an install brings them back. */
export const DEPENDENCY_DIRS = new Set([
	"node_modules",
	"bower_components",
	".pnpm-store",
	".venv",
	"venv",
	"__pycache__",
	".pytest_cache",
	".mypy_cache",
	".tox",
	".gradle",
	".dart_tool",
	"Pods",
	".cache",
]);

/** Zip without zip64: no entry, and no archive, past 4 GB. Kept well under. */
const ZIP_LIMIT = 0xf000_0000;

/** A single file larger than this is left out (and named in the manifest): reading it would strain a small server. */
export const MAX_FILE_BYTES = 512 * 1024 * 1024;

export const BACKUP_INTERVAL_MS = 60 * 60_000;

export interface BackupInfo {
	name: string;
	path: string;
	at: number;
	size: number;
}

interface Config {
	/** The phone's key, 64 hex characters; none means automatic backups are off. */
	key?: string;
	lastFingerprint?: string;
	lastAt?: number;
	lastError?: string | null;
}

/** One file to back up: where it is, its name in the zip, and whether it is a secret file to decrypt. */
interface Item {
	abs: string;
	name: string;
	size: number;
	mtimeMs: number;
	secure: boolean;
}

export interface AutoBackupOptions {
	/** Where the backups go (~/.griphub/backups). */
	dir: string;
	/** Where the key and the last fingerprint are kept (encrypted with the server's store key). */
	configFile: string;
	agentDir: string;
	workspace: string;
	home: string;
	/** How many backups to keep. */
	keep?: number;
	intervalMs?: number;
	log?: (line: string) => void;
	now?: () => number;
}

export class AutoBackup {
	private config: Config;
	private timer?: NodeJS.Timeout;
	private making: Promise<BackupInfo | null> | null = null;

	constructor(private readonly o: AutoBackupOptions) {
		this.config = readSecureJson<Config>(o.configFile, {});
	}

	private now() {
		return this.o.now?.() ?? Date.now();
	}

	get enabled() {
		return /^[0-9a-f]{64}$/i.test(this.config.key ?? "");
	}

	/** Turns automatic backups on with the phone's key, or off (null). Off deletes the backups that key made. */
	configure(key: string | null) {
		if (key !== null && !/^[0-9a-f]{64}$/i.test(key)) throw new Error("The backup key must be 64 hex characters");
		if (key === null) {
			for (const b of this.list()) rmSync(b.path, { force: true });
			this.config = {};
		} else if (key !== this.config.key) {
			// Backups under another key are of no use to this phone.
			for (const b of this.list()) rmSync(b.path, { force: true });
			this.config = { key };
		}
		this.save();
		return this.status();
	}

	status() {
		return {
			enabled: this.enabled,
			intervalMinutes: Math.round((this.o.intervalMs ?? BACKUP_INTERVAL_MS) / 60_000),
			running: this.making !== null,
			lastCheck: this.config.lastAt ?? null,
			lastError: this.config.lastError ?? null,
			backups: this.list().map(({ name, path, at, size }) => ({ name, path, at, size })),
		};
	}

	/** The backups on disk, newest first. */
	list(): BackupInfo[] {
		if (!existsSync(this.o.dir)) return [];
		return readdirSync(this.o.dir)
			.filter((n) => /^auto-\d+\.ghb$/.test(n))
			.map((name) => {
				const path = join(this.o.dir, name);
				const st = statSync(path);
				return { name, path, at: Number(name.slice(5, -4)), size: st.size };
			})
			.sort((a, b) => b.at - a.at);
	}

	/** Checks every interval (the first time a minute after start, so a restart does not wait an hour). */
	start() {
		const every = this.o.intervalMs ?? BACKUP_INTERVAL_MS;
		const first = setTimeout(() => void this.tick(), Math.min(60_000, every));
		first.unref();
		this.timer = setInterval(() => void this.tick(), every);
		this.timer.unref();
	}

	stop() {
		if (this.timer) clearInterval(this.timer);
	}

	/** Makes a backup when something changed since the last one, or always when [force]. Null when nothing was made. */
	tick(force = false): Promise<BackupInfo | null> {
		if (!this.enabled) return Promise.resolve(null);
		this.making ??= this.run(force).finally(() => {
			this.making = null;
		});
		return this.making;
	}

	private async run(force: boolean): Promise<BackupInfo | null> {
		try {
			const items = this.items();
			const fingerprint = fingerprintOf(items);
			if (!force && fingerprint === this.config.lastFingerprint && this.list().length) return null;
			const info = await this.make(items);
			this.config.lastFingerprint = fingerprint;
			this.config.lastAt = this.now();
			this.config.lastError = null;
			this.save();
			this.prune();
			this.o.log?.(`backup ${info.name} (${info.size} bytes)`);
			return info;
		} catch (e) {
			this.config.lastAt = this.now();
			this.config.lastError = (e as Error).message;
			this.save();
			this.o.log?.(`backup failed: ${(e as Error).message}`);
			throw e;
		}
	}

	private save() {
		mkdirSync(join(this.o.configFile, ".."), { recursive: true });
		writeSecureJson(this.o.configFile, this.config);
	}

	private prune() {
		for (const b of this.list().slice(this.o.keep ?? 3)) rmSync(b.path, { force: true });
	}

	/** What goes in: the agent's data, the workspace, and the deploy key; never the backups themselves. */
	items(): Item[] {
		const out: Item[] = [];
		const skip = new Set([this.o.dir, join(this.o.agentDir, "bin"), join(this.o.agentDir, "griphub", "checkpoints"), this.o.configFile]);
		// Neither tree is walked twice when one sits inside the other.
		const agentSkip = new Set([...skip, this.o.workspace]);
		const wsSkip = new Set([...skip, this.o.agentDir]);
		walk(this.o.agentDir, agentSkip, (abs, st) => {
			const rel = relative(this.o.agentDir, abs).split(sep).join("/");
			const secure = isSecureFile(abs);
			out.push({ abs, name: `${secure ? "secure" : "agent"}/${rel}`, size: st.size, mtimeMs: st.mtimeMs, secure });
		});
		walk(this.o.workspace, wsSkip, (abs, st) => {
			out.push({ abs, name: `workspace/${relative(this.o.workspace, abs).split(sep).join("/")}`, size: st.size, mtimeMs: st.mtimeMs, secure: false });
		});
		for (const f of ["id_ed25519", "id_ed25519.pub"]) {
			const abs = join(this.o.home, ".ssh", f);
			if (existsSync(abs)) {
				const st = statSync(abs);
				out.push({ abs, name: `home/.ssh/${f}`, size: st.size, mtimeMs: st.mtimeMs, secure: false });
			}
		}
		return out;
	}

	/** Writes one encrypted backup of [items]; a file that went away meanwhile is skipped. */
	private async make(items: Item[]): Promise<BackupInfo> {
		const key = Buffer.from(this.config.key!, "hex");
		mkdirSync(this.o.dir, { recursive: true, mode: 0o700 });
		const at = this.now();
		const name = `auto-${at}.ghb`;
		const final = join(this.o.dir, name);
		const tmp = join(this.o.dir, `.${name}.tmp`);
		const fd = openSync(tmp, "w", 0o600);
		const skipped: { name: string; why: string }[] = [];
		try {
			const iv = randomBytes(12);
			const cipher = createCipheriv("aes-256-gcm", key, iv);
			writeSync(fd, MAGIC);
			writeSync(fd, iv);
			const zip = new ZipWriter((chunk) => {
				const c = cipher.update(chunk);
				if (c.length) writeSync(fd, c);
			});
			let files = 0;
			for (const item of items) {
				if (item.size > MAX_FILE_BYTES) {
					skipped.push({ name: item.name, why: "larger than 512 MB" });
					continue;
				}
				let data: Buffer;
				try {
					data = item.secure
						? Buffer.from(JSON.stringify(readSecureJson<unknown>(item.abs, null)))
						: await readFile(item.abs);
				} catch {
					continue; // gone since it was listed
				}
				if (!(await zip.add(item.name, data))) {
					skipped.push({ name: item.name, why: "the backup reached its 4 GB limit" });
					continue;
				}
				files++;
			}
			const manifest = {
				version: 1,
				createdAt: at,
				host: hostname(),
				agentDir: this.o.agentDir,
				workspace: this.o.workspace,
				files,
				skipped,
			};
			await zip.add("manifest.json", Buffer.from(JSON.stringify(manifest, null, 2)));
			zip.finish();
			const rest = cipher.final();
			if (rest.length) writeSync(fd, rest);
			writeSync(fd, cipher.getAuthTag());
		} catch (e) {
			closeSync(fd);
			rmSync(tmp, { force: true });
			throw e;
		}
		closeSync(fd);
		renameSync(tmp, final);
		return { name, path: final, at, size: statSync(final).size };
	}
}

/** Calls [fn] for every regular file under [dir], skipping dependency folders, [skip] paths and links. */
function walk(dir: string, skip: Set<string>, fn: (abs: string, st: { size: number; mtimeMs: number }) => void) {
	if (!existsSync(dir) || skip.has(dir)) return;
	let names: string[];
	try {
		names = readdirSync(dir);
	} catch {
		return;
	}
	for (const name of names) {
		if (DEPENDENCY_DIRS.has(name)) continue;
		const abs = join(dir, name);
		if (skip.has(abs)) continue;
		let st;
		try {
			st = lstatSync(abs);
		} catch {
			continue;
		}
		if (st.isDirectory()) walk(abs, skip, fn);
		else if (st.isFile()) fn(abs, st);
	}
}

/** A file secure.ts wrote encrypted with this machine's store key. */
function isSecureFile(abs: string) {
	if (!abs.endsWith(".json")) return false;
	try {
		const fd = openSync(abs, "r");
		const head = Buffer.alloc(5);
		readSync(fd, head, 0, 5, 0);
		closeSync(fd);
		return head.toString() === "enc1:";
	} catch {
		return false;
	}
}

/** Changes to what would be backed up: names, sizes and times of every file. */
function fingerprintOf(items: Item[]) {
	const h = createHash("sha256");
	for (const i of items) h.update(`${i.name}\0${i.size}\0${Math.floor(i.mtimeMs)}\n`);
	return h.digest("hex");
}

/** Writes a zip front to back to [out] (nothing is seeked back to), keeping only the central directory in memory. */
class ZipWriter {
	private offset = 0;
	private central: Buffer[] = [];
	private count = 0;

	constructor(private readonly out: (chunk: Buffer) => void) {}

	private write(b: Buffer) {
		this.out(b);
		this.offset += b.length;
	}

	/** False (and nothing written) when the entry would take the archive past the zip limit. */
	async add(entryName: string, data: Buffer): Promise<boolean> {
		const name = Buffer.from(entryName, "utf8");
		const deflated = await deflate(data);
		const useDeflate = deflated.length < data.length;
		const body = useDeflate ? deflated : data;
		if (this.offset + 30 + name.length + body.length > ZIP_LIMIT) return false;
		const crc = crc32(data);
		const local = Buffer.alloc(30);
		local.writeUInt32LE(0x04034b50, 0);
		local.writeUInt16LE(20, 4);
		local.writeUInt16LE(0x0800, 6); // UTF-8 names
		local.writeUInt16LE(useDeflate ? 8 : 0, 8);
		local.writeUInt32LE(crc, 14);
		local.writeUInt32LE(body.length, 18);
		local.writeUInt32LE(data.length, 22);
		local.writeUInt16LE(name.length, 26);
		const at = this.offset;
		this.write(local);
		this.write(name);
		this.write(body);
		const central = Buffer.alloc(46);
		central.writeUInt32LE(0x02014b50, 0);
		central.writeUInt16LE(20, 4);
		central.writeUInt16LE(20, 6);
		central.writeUInt16LE(0x0800, 8);
		central.writeUInt16LE(useDeflate ? 8 : 0, 10);
		central.writeUInt32LE(crc, 16);
		central.writeUInt32LE(body.length, 20);
		central.writeUInt32LE(data.length, 24);
		central.writeUInt16LE(name.length, 28);
		central.writeUInt32LE(at, 42);
		this.central.push(central, name);
		this.count++;
		return true;
	}

	finish() {
		const start = this.offset;
		for (const b of this.central) this.write(b);
		const end = Buffer.alloc(22);
		end.writeUInt32LE(0x06054b50, 0);
		// No zip64: past 65535 entries the counts read 0xffff, which readers then take from the central directory.
		end.writeUInt16LE(Math.min(this.count, 0xffff), 8);
		end.writeUInt16LE(Math.min(this.count, 0xffff), 10);
		end.writeUInt32LE(this.offset - start, 12);
		end.writeUInt32LE(start, 16);
		this.write(end);
	}
}

// ---------------------------------------------------------------------------
// Restoring (on the phone)

/** Decrypts a backup to a plain zip at [out]. Throws when the key does not match or the file was changed. */
export function decryptBackup(src: string, keyHex: string, out: string) {
	if (!/^[0-9a-f]{64}$/i.test(keyHex)) throw new Error("The backup key is not valid");
	const fd = openSync(src, "r");
	const size = fstatSync(fd).size;
	try {
		const head = Buffer.alloc(16);
		readSync(fd, head, 0, 16, 0);
		if (size < 32 || !head.subarray(0, 4).equals(MAGIC)) throw new Error("This is not a GripHub server backup");
		const tag = Buffer.alloc(16);
		readSync(fd, tag, 0, 16, size - 16);
		const decipher = createDecipheriv("aes-256-gcm", Buffer.from(keyHex, "hex"), head.subarray(4, 16));
		decipher.setAuthTag(tag);
		const ofd = openSync(out, "w", 0o600);
		try {
			const buf = Buffer.alloc(1024 * 1024);
			for (let pos = 16; pos < size - 16; ) {
				const n = readSync(fd, buf, 0, Math.min(buf.length, size - 16 - pos), pos);
				if (n <= 0) break;
				writeSync(ofd, decipher.update(buf.subarray(0, n)));
				pos += n;
			}
			try {
				writeSync(ofd, decipher.final());
			} catch {
				throw new Error("The backup is damaged, or it was made with another key");
			}
		} finally {
			closeSync(ofd);
		}
	} catch (e) {
		rmSync(out, { force: true });
		throw e;
	} finally {
		closeSync(fd);
	}
}

/** Reads a zip on disk entry by entry (only one entry in memory at a time), through its central directory. */
export function* zipEntries(path: string): Generator<{ name: string; data: Buffer }> {
	const fd = openSync(path, "r");
	try {
		const size = fstatSync(fd).size;
		const tailLen = Math.min(size, 22 + 0xffff);
		const tail = Buffer.alloc(tailLen);
		readSync(fd, tail, 0, tailLen, size - tailLen);
		const eocd = tail.lastIndexOf(Buffer.from([0x50, 0x4b, 0x05, 0x06]));
		if (eocd < 0) throw new Error("Not a zip file");
		const cdSize = tail.readUInt32LE(eocd + 12);
		const cdStart = tail.readUInt32LE(eocd + 16);
		const cd = Buffer.alloc(cdSize);
		readSync(fd, cd, 0, cdSize, cdStart);
		for (let p = 0; p + 46 <= cd.length && cd.readUInt32LE(p) === 0x02014b50; ) {
			const method = cd.readUInt16LE(p + 10);
			const compressed = cd.readUInt32LE(p + 20);
			const nameLen = cd.readUInt16LE(p + 28);
			const extra = cd.readUInt16LE(p + 30);
			const comment = cd.readUInt16LE(p + 32);
			const local = cd.readUInt32LE(p + 42);
			const name = cd.subarray(p + 46, p + 46 + nameLen).toString("utf8");
			p += 46 + nameLen + extra + comment;
			if (name.endsWith("/")) continue;
			const lh = Buffer.alloc(30);
			readSync(fd, lh, 0, 30, local);
			const raw = Buffer.alloc(compressed);
			readSync(fd, raw, 0, compressed, local + 30 + lh.readUInt16LE(26) + lh.readUInt16LE(28));
			yield { name, data: method === 8 ? inflateRawSync(raw) : raw };
		}
	} finally {
		closeSync(fd);
	}
}

/** The manifest of a decrypted backup. */
export function readManifest(zipPath: string): { createdAt?: number; workspace?: string; agentDir?: string; skipped?: unknown[] } {
	for (const e of zipEntries(zipPath)) if (e.name === "manifest.json") return JSON.parse(e.data.toString("utf8"));
	return {};
}

/** What of a server's agent data a phone takes over; the rest is the server's own (its shell, its caches). */
const RESTORE_AGENT = [
	(rel: string) => rel.startsWith("sessions/"),
	(rel: string) => rel.startsWith("skills/"),
	(rel: string) => rel.startsWith("prompts/"),
	(rel: string) => rel === "griphub/runs.json",
];

/** The secret files a phone takes over: providers and keys, accounts and tokens, MCP servers. */
const RESTORE_SECURE = new Set(["griphub/custom-providers.json", "griphub/integrations.json", "griphub/mcp.json"]);

/** Settings that belong to the machine, not the user: the phone keeps its own. */
const MACHINE_SETTINGS = ["dns", "dnsUrl", "containerShell", "timeZone", "notify"];

export interface RestoreTarget {
	agentDir: string;
	workspace: string;
	home: string;
}

/**
 * Puts a server backup's data on this phone: chats (moved to this phone's workspace), skills, prompts, runs, the
 * workspace with its .git, the secrets (encrypted again with this phone's key), and the deploy key when this phone
 * has none. Settings that belong to the machine stay the phone's own.
 */
export function restoreBackup(zipPath: string, to: RestoreTarget) {
	const manifest = readManifest(zipPath);
	const fromWs = typeof manifest.workspace === "string" ? manifest.workspace : null;
	// A path of the server's workspace, as the same path in this phone's.
	const rebase = (text: string) => (fromWs && fromWs !== to.workspace ? text.split(fromWs).join(to.workspace) : text);
	let restored = 0;
	let skipped = 0;
	let keptSshKey = false;
	for (const e of zipEntries(zipPath)) {
		if (e.name === "manifest.json") continue;
		const [root, ...rest] = e.name.split("/");
		const rel = rest.join("/");
		if (!rel || rel.split("/").some((s) => s === ".." || s === "") || rel.startsWith("/")) {
			skipped++;
			continue;
		}
		let target: string | null = null;
		let data = e.data;
		if (root === "agent" && RESTORE_AGENT.some((f) => f(rel))) {
			target = join(to.agentDir, rel);
			// Chats and runs name their folder; the server's workspace path becomes this phone's.
			if (rel.endsWith(".jsonl")) {
				const text = data.toString("utf8");
				const nl = text.indexOf("\n");
				data = Buffer.from(nl < 0 ? rebase(text) : rebase(text.slice(0, nl)) + text.slice(nl));
			} else if (rel === "griphub/runs.json") data = Buffer.from(rebase(data.toString("utf8")));
		} else if (root === "secure" && RESTORE_SECURE.has(rel)) {
			const file = join(to.agentDir, rel);
			let value = JSON.parse(data.toString("utf8"));
			if (rel === "griphub/integrations.json" && value && typeof value === "object") {
				const mine = readSecureJson<{ settings?: Record<string, unknown> }>(file, {});
				const settings = { ...(value.settings ?? {}) };
				for (const k of MACHINE_SETTINGS) {
					if (mine.settings && k in mine.settings) settings[k] = mine.settings[k];
					else delete settings[k];
				}
				if (settings.projectSearch) settings.projectSearch = JSON.parse(rebase(JSON.stringify(settings.projectSearch)));
				value = { ...value, settings };
			}
			mkdirSync(join(file, ".."), { recursive: true });
			writeSecureJson(file, value);
			restored++;
			continue;
		} else if (root === "workspace") {
			target = join(to.workspace, rel);
		} else if (root === "home" && (rel === ".ssh/id_ed25519" || rel === ".ssh/id_ed25519.pub")) {
			const file = join(to.home, rel);
			if (existsSync(file)) {
				keptSshKey = true;
				skipped++;
				continue;
			}
			target = file;
		}
		if (!target) {
			skipped++;
			continue;
		}
		mkdirSync(join(target, ".."), { recursive: true });
		const fd = openSync(target, "w", root === "home" ? 0o600 : 0o644);
		try {
			writeSync(fd, data);
		} finally {
			closeSync(fd);
		}
		restored++;
	}
	return { restored, skipped, keptSshKey, createdAt: manifest.createdAt ?? null, notBackedUp: manifest.skipped ?? [] };
}

/** For tests: a backup's files by name (decrypted to [tmp] first). */
export function backupFiles(src: string, keyHex: string, tmp: string): Map<string, Buffer> {
	decryptBackup(src, keyHex, tmp);
	try {
		return new Map([...zipEntries(tmp)].map((e) => [e.name, e.data]));
	} finally {
		rmSync(tmp, { force: true });
	}
}
