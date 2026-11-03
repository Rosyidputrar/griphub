/**
 * Automatic backups of a server agent, for the phone to keep (server_agent.md).
 *
 * Every hour the daemon checks whether anything changed since the last backup and, if so, writes a new one: the
 * agent's data (chats, skills, prompts, runs), its saved secrets (API keys, tokens, MCP servers), the whole workspace
 * with each project's .git, and the deploy SSH key. Dependencies are left out (node_modules, virtualenvs, caches):
 * they come back with an install. The newest few are kept; the app fetches the newest to the phone, and offers it
 * when the user switches back to the agent on the phone.
 *
 * Everything is encrypted as it is written (AES-256-GCM) with a key the phone made and gave the server: no plaintext
 * copy is ever on disk, and a copy that leaves the phone or the server is unreadable without that key. The server
 * needs the key to write backups, and it holds all of the data anyway; the key protects the copies.
 *
 * A server's backups are incremental ([AutoBackupOptions.incremental]), so the phone fetches only what changed: each
 * file is a blob of its own, named by a keyed hash of what is in it (the same content is stored once, however many
 * backups have it), and a backup is a small snapshot that lists its files and their blobs. A new backup writes only
 * the blobs that are new; the phone asks which blobs a snapshot needs and fetches the ones it lacks.
 *
 *   blob     = "GHO1" | iv (12) | ciphertext of (0 | data, or 1 | deflated data) | GCM tag (16)   blobs/<id>
 *   snapshot = "GHS1" | iv (12) | ciphertext of the deflated JSON list | GCM tag (16)               auto-<at>.ghs
 *   id       = hex HMAC-SHA256(key, "griphub-blob\0" | data): without the key it says nothing of the content
 *
 * The phone's own backups go to the Download folder to be copied off it, so they stay one file each, a zip:
 *
 *   file = "GHB1" | iv (12) | ciphertext of the zip | GCM tag (16)                                 auto-<at>.ghb
 *
 * Secrets are stored encrypted at rest with each machine's own store key (secure.ts), which never leaves it; in a
 * backup they are under `secure/`, decrypted, inside the encrypted zip, and the phone encrypts them again with its key.
 */

import { createCipheriv, createDecipheriv, createHash, createHmac, randomBytes } from "node:crypto";
import {
	closeSync,
	readFileSync,
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
import { readFile, writeFile } from "node:fs/promises";
import { hostname } from "node:os";
import { dirname, join, relative, sep } from "node:path";
import { promisify } from "node:util";
import { deflateRaw, inflateRawSync } from "node:zlib";
import { readSecureJson, readSecureJsonStrict, writeSecureJson } from "./secure.js";
import { isObject } from "./state.js";
import { crc32 } from "./workbench.js";

const deflate = promisify(deflateRaw);

const MAGIC = Buffer.from("GHB1");
const BLOB_MAGIC = Buffer.from("GHO1");
const SNAP_MAGIC = Buffer.from("GHS1");

/** A backup's file name: the time it was made, and .ghb for a whole zip or .ghs for a snapshot of blobs. */
const BACKUP_NAME = /^auto-(\d+)\.(ghb|ghs)$/;

/** A blob's name: 64 hex characters. */
export const BLOB_ID = /^[0-9a-f]{64}$/;

/** At most this many bytes of blobs in one answer to the phone (base64 makes it a third more on the wire). */
export const READ_MAX_BYTES = 4 * 1024 * 1024;

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

/**
 * Build output, left out of the workspace wherever it is: a build brings it back, and it can dwarf the project (a
 * Flutter test cache alone was 80 MB). Only the workspace: nothing the agent keeps for itself is named like this.
 */
export const BUILD_DIRS = new Set(["build", "target", "dist"]);

/** A `.tmp` that a backup left behind is removed once it has not been written to for this long. */
export const STALE_TMP_MS = 15 * 60_000;

/** What a store file keeps beside itself: its last good copy, a damaged file set aside, an unfinished write. */
const STORE_SIDECAR = /[\\/](integrations|custom-providers|mcp|auto-backup|runs|sync)\.json\.(bak|corrupt-\d+|tmp-\d+)$/;

/** Zip without zip64: no entry, and no archive, past 4 GB. Kept well under. */
const ZIP_LIMIT = 0xf000_0000;

/** A single file larger than this is left out (and named in the manifest): reading it would strain a small server. */
export const MAX_FILE_BYTES = 512 * 1024 * 1024;

export const BACKUP_INTERVAL_MS = 60 * 60_000;

export interface BackupInfo {
	name: string;
	path: string;
	at: number;
	/** What the whole backup takes: the zip, or the snapshot with every blob it needs. */
	size: number;
	/** Of [size], what this backup added: blobs no older backup had. Only for a snapshot. */
	added?: number;
}

/** One file in a snapshot. */
export interface SnapshotFile {
	name: string;
	id: string;
	size: number;
}

/** What a snapshot lists, decrypted. */
export interface Snapshot {
	version: 2;
	createdAt: number;
	host: string;
	agentDir: string;
	workspace: string;
	files: SnapshotFile[];
	skipped: { name: string; why: string }[];
}

/** What the phone needs to fetch a snapshot: its own bytes, and every blob it lists with that blob's stored size. */
export interface SnapshotNeeds {
	name: string;
	at: number;
	/** The snapshot file, base64: small, a few hundred bytes per thousand files. */
	snapshot: string;
	blobs: { id: string; size: number }[];
}

interface Config {
	/** The phone's key, 64 hex characters; none means automatic backups are off. */
	key?: string;
	lastFingerprint?: string;
	lastAt?: number;
	lastError?: string | null;
}

/**
 * For an incremental backup, the blob each file was last stored as, by its size and time: an unchanged file is not
 * read again. Kept beside the blobs (index.json): only names and ids, never content, and lost harmlessly.
 */
type BlobIndex = Record<string, { size: number; mtimeMs: number; id: string }>;

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
	/**
	 * Store each backup as a snapshot of blobs (a server's): a new backup writes only what changed, and the phone
	 * fetches only that. Without it each backup is one zip (the phone's own, made to be copied off the phone).
	 */
	incremental?: boolean;
	/**
	 * Leave the saved secrets (API keys, tokens, MCP servers) out of the backups. On the phone they stay out: its
	 * backups go to the shared Download folder, which other apps read, and the key that encrypts them lives in the
	 * same app the secrets do, so a backup with them in it protects nothing and risks them. A server's backups keep
	 * them (the phone holds that key).
	 */
	noSecrets?: boolean;
}

export class AutoBackup {
	private config: Config;
	private timer?: NodeJS.Timeout;
	private making: Promise<BackupInfo | null> | null = null;
	/** The unfinished file this process is writing right now, never cleaned away. */
	private writing: string | null = null;

	constructor(private readonly o: AutoBackupOptions) {
		this.config = readSecureJson<Config>(o.configFile, {}, isObject);
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
		if (key === null || key !== this.config.key) {
			// Off, or another key: backups under the old one are of no use to this phone.
			for (const b of this.list()) rmSync(b.path, { force: true });
			rmSync(this.blobsDir, { recursive: true, force: true });
			rmSync(this.indexFile, { force: true });
			this.snapshots.clear();
			this.config = key === null ? {} : { key };
		}
		this.save();
		return this.status();
	}

	status() {
		return {
			enabled: this.enabled,
			dir: this.o.dir,
			intervalMinutes: Math.round((this.o.intervalMs ?? BACKUP_INTERVAL_MS) / 60_000),
			running: this.making !== null,
			lastCheck: this.config.lastAt ?? null,
			lastError: this.config.lastError ?? null,
			backups: this.list().map(({ name, path, at, size, added }) => ({ name, path, at, size, ...(added === undefined ? {} : { added }) })),
		};
	}

	/**
	 * The key the backups are encrypted with, for the phone's own agent only: there the app and this host are one
	 * process tree in one app sandbox, and the app shows it once as a recovery code to write down (the point of a
	 * phone backup is surviving the phone, so the key must live outside it too). A server never tells its key: the
	 * phone made it and is the only place it belongs.
	 */
	recoveryKey(): string | null {
		return this.enabled ? (this.config.key ?? null) : null;
	}

	/** Where an incremental backup keeps its blobs. */
	get blobsDir() {
		return join(this.o.dir, "blobs");
	}

	private get indexFile() {
		return join(this.o.dir, "index.json");
	}

	/** Snapshots read so far, by name: they never change once written. */
	private readonly snapshots = new Map<string, Snapshot>();

	/** The backups on disk, newest first: zips and snapshots (a server that was updated has both for a while). */
	list(): BackupInfo[] {
		if (!existsSync(this.o.dir)) return [];
		const found = readdirSync(this.o.dir)
			.map((name) => ({ name, m: BACKUP_NAME.exec(name) }))
			.filter((x): x is { name: string; m: RegExpExecArray } => x.m !== null)
			.map(({ name, m }) => {
				const path = join(this.o.dir, name);
				return { name, path, at: Number(m[1]), size: statSync(path).size, snapshot: m[2] === "ghs" };
			})
			.sort((a, b) => b.at - a.at);
		// A snapshot's size is its blobs' too, and what it added is what no older snapshot had.
		const seen = new Set<string>();
		const out: BackupInfo[] = [];
		for (const b of [...found].reverse()) {
			const { snapshot, ...info } = b;
			if (!snapshot) {
				out.push(info);
				continue;
			}
			let size = info.size;
			let added = info.size;
			try {
				for (const { id, size: n } of this.blobsOf(this.snapshot(info.name))) {
					size += n;
					if (!seen.has(id)) added += n;
					seen.add(id);
				}
			} catch {
				// Unreadable with this key (it cannot be: configure clears them), or damaged: listed by its own size.
			}
			out.push({ ...info, size, added });
		}
		return out.reverse();
	}

	/** A snapshot of this backup folder, decrypted (only with the key). */
	snapshot(name: string): Snapshot {
		const known = this.snapshots.get(name);
		if (known) return known;
		if (!BACKUP_NAME.test(name) || !name.endsWith(".ghs")) throw new Error(`Not a snapshot: ${name}`);
		const snap = readSnapshot(join(this.o.dir, name), this.config.key ?? "");
		this.snapshots.set(name, snap);
		return snap;
	}

	/** The blobs a snapshot needs, each once, with what each takes on disk. */
	private blobsOf(snap: Snapshot) {
		const out = new Map<string, number>();
		for (const f of snap.files) {
			if (out.has(f.id)) continue;
			let size = 0;
			try {
				size = statSync(join(this.blobsDir, f.id)).size;
			} catch {
				// missing: the phone is told, and a restore says so
			}
			out.set(f.id, size);
		}
		return [...out].map(([id, size]) => ({ id, size }));
	}

	/** What the phone fetches for the snapshot [name]: the snapshot itself, and its blobs (it skips those it has). */
	needs(name: string): SnapshotNeeds {
		const m = BACKUP_NAME.exec(name);
		if (!m || m[2] !== "ghs") throw new Error(`Not a snapshot: ${name}`);
		const snap = this.snapshot(name);
		return {
			name,
			at: Number(m[1]),
			snapshot: readFileSync(join(this.o.dir, name)).toString("base64"),
			blobs: this.blobsOf(snap),
		};
	}

	/**
	 * Bytes of blobs for the phone, from where each one's partial copy ends, up to [max] bytes in all: many small
	 * blobs in one answer, a large one over several. The answer says each blob's size, so the phone knows when it ends.
	 */
	read(items: { id: string; offset?: number }[], max = READ_MAX_BYTES) {
		const out: { id: string; offset: number; size: number; data: string }[] = [];
		let left = Math.max(1, Math.min(max, READ_MAX_BYTES));
		for (const item of items) {
			if (left <= 0) break;
			if (!BLOB_ID.test(String(item.id))) throw new Error(`Not a blob: ${String(item.id)}`);
			const path = join(this.blobsDir, item.id);
			const fd = openSync(path, "r");
			try {
				const size = fstatSync(fd).size;
				const offset = Math.max(0, Math.min(size, Math.floor(Number(item.offset) || 0)));
				const buf = Buffer.alloc(Math.min(left, size - offset));
				const n = buf.length ? readSync(fd, buf, 0, buf.length, offset) : 0;
				left -= n;
				out.push({ id: item.id, offset, size, data: buf.subarray(0, n).toString("base64") });
			} finally {
				closeSync(fd);
			}
		}
		return { chunks: out };
	}

	/** Checks every interval (the first time a minute after start, so a restart does not wait an hour). */
	start() {
		this.cleanTmp();
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
			const info = this.o.incremental ? await this.makeSnapshot(items) : await this.make(items);
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
		for (const b of this.list().slice(this.o.keep ?? 3)) {
			rmSync(b.path, { force: true });
			this.snapshots.delete(b.name);
		}
		this.pruneBlobs();
		this.cleanTmp();
	}

	/** Removes blobs no kept snapshot lists. Not while a snapshot cannot be read: its blobs would go with it. */
	private pruneBlobs() {
		if (!existsSync(this.blobsDir)) return;
		const live = new Set<string>();
		for (const b of this.list()) {
			if (!b.name.endsWith(".ghs")) continue;
			try {
				for (const f of this.snapshot(b.name).files) live.add(f.id);
			} catch {
				return;
			}
		}
		for (const id of readdirSync(this.blobsDir)) {
			if (BLOB_ID.test(id) && !live.has(id)) rmSync(join(this.blobsDir, id), { force: true });
		}
	}

	/**
	 * Removes what a backup that was cut short (the host stopped, the disk filled) left in the folder: nobody renames
	 * it, and one such file was 492 MB. Not the file this process is writing, and not one written to lately (another
	 * host process may still be making it); only a leftover that has been still for [STALE_TMP_MS].
	 */
	cleanTmp() {
		let names: string[];
		try {
			names = readdirSync(this.o.dir);
		} catch {
			return;
		}
		let blobs: string[] = [];
		try {
			blobs = readdirSync(this.blobsDir).map((n) => join("blobs", n));
		} catch {
			// no blobs
		}
		for (const name of [...names, ...blobs]) {
			if (!/^\.auto-\d+\.gh[bs]\.tmp$/.test(name) && !/^blobs[\\/]\.[0-9a-f]{64}\.tmp$/.test(name)) continue;
			const path = join(this.o.dir, name);
			if (path === this.writing) continue;
			try {
				if (this.now() - statSync(path).mtimeMs < STALE_TMP_MS) continue;
				rmSync(path, { force: true });
				this.o.log?.(`removed unfinished backup ${name}`);
			} catch {
				// gone already, or not ours to remove: leave it
			}
		}
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
			// The last good copy, a set-aside file and a half-written one that a store keeps beside itself (state.ts): the
			// copies are encrypted with the server's own key and are no use in a backup, and they would change it every save.
			if (STORE_SIDECAR.test(abs)) return;
			const secure = isSecureFile(abs);
			if (secure && this.o.noSecrets) return;
			out.push({ abs, name: `${secure ? "secure" : "agent"}/${rel}`, size: st.size, mtimeMs: st.mtimeMs, secure });
		});
		walk(
			this.o.workspace,
			wsSkip,
			(abs, st) => {
				out.push({ abs, name: `workspace/${relative(this.o.workspace, abs).split(sep).join("/")}`, size: st.size, mtimeMs: st.mtimeMs, secure: false });
			},
			true,
		);
		for (const f of ["id_ed25519", "id_ed25519.pub"]) {
			const abs = join(this.o.home, ".ssh", f);
			if (existsSync(abs)) {
				const st = statSync(abs);
				out.push({ abs, name: `home/.ssh/${f}`, size: st.size, mtimeMs: st.mtimeMs, secure: false });
			}
		}
		return out;
	}

	/**
	 * Writes one snapshot of [items]: a file unchanged since the last backup (same size and time, its blob still
	 * there) is not read again, a changed one is stored as a new blob unless its content is already stored, and the
	 * snapshot lists them all. Nothing is written but new blobs and the small snapshot.
	 */
	private async makeSnapshot(items: Item[]): Promise<BackupInfo> {
		const key = Buffer.from(this.config.key!, "hex");
		mkdirSync(this.blobsDir, { recursive: true, mode: 0o700 });
		const at = this.now();
		const name = `auto-${at}.ghs`;
		const final = join(this.o.dir, name);
		let index: BlobIndex = {};
		try {
			const read = JSON.parse(readFileSync(this.indexFile, "utf8"));
			if (isObject(read)) index = read as BlobIndex;
		} catch {
			// none yet, or damaged: every file is read once
		}
		const nextIndex: BlobIndex = {};
		const files: SnapshotFile[] = [];
		const skipped: { name: string; why: string }[] = [];
		for (const item of items) {
			if (item.size > MAX_FILE_BYTES) {
				skipped.push({ name: item.name, why: "larger than 512 MB" });
				continue;
			}
			const known = index[item.name];
			// Secrets are read every time: they are small, and their file's time says nothing of the decrypted content.
			if (!item.secure && known && known.size === item.size && known.mtimeMs === Math.floor(item.mtimeMs) && existsSync(join(this.blobsDir, known.id))) {
				files.push({ name: item.name, id: known.id, size: item.size });
				nextIndex[item.name] = known;
				continue;
			}
			let data: Buffer;
			try {
				data = item.secure ? Buffer.from(JSON.stringify(readSecureJsonStrict(item.abs))) : await readFile(item.abs);
			} catch (e) {
				if (item.secure && (e as NodeJS.ErrnoException).code !== "ENOENT") skipped.push({ name: item.name, why: "could not be read (damaged, or saved with a key this host lacks)" });
				continue;
			}
			const id = blobId(data, key);
			const path = join(this.blobsDir, id);
			if (!existsSync(path)) {
				const tmp = join(this.blobsDir, `.${id}.tmp`);
				this.writing = tmp;
				try {
					await writeFile(tmp, await sealBlob(data, key), { mode: 0o600 });
					renameSync(tmp, path);
				} finally {
					rmSync(tmp, { force: true });
					this.writing = null;
				}
			}
			files.push({ name: item.name, id, size: data.length });
			// Whole milliseconds, as the fingerprint: a time set again from a Date (a copy, a restore) loses the rest.
			if (!item.secure) nextIndex[item.name] = { size: item.size, mtimeMs: Math.floor(item.mtimeMs), id };
		}
		const snap: Snapshot = {
			version: 2,
			createdAt: at,
			host: hostname(),
			agentDir: this.o.agentDir,
			workspace: this.o.workspace,
			files,
			skipped,
		};
		const tmp = join(this.o.dir, `.${name}.tmp`);
		this.writing = tmp;
		try {
			const body = await deflate(Buffer.from(JSON.stringify(snap)));
			await writeFile(tmp, seal(SNAP_MAGIC, body, key), { mode: 0o600 });
			renameSync(tmp, final);
		} finally {
			rmSync(tmp, { force: true });
			this.writing = null;
		}
		this.snapshots.set(name, snap);
		await writeFile(this.indexFile, JSON.stringify(nextIndex), { mode: 0o600 });
		return this.list().find((b) => b.name === name) ?? { name, path: final, at, size: statSync(final).size };
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
		this.writing = tmp;
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
					data = item.secure ? Buffer.from(JSON.stringify(readSecureJsonStrict(item.abs))) : await readFile(item.abs);
				} catch (e) {
					// A store that cannot be read used to be saved as `null`, and restoring that wiped the real one. Leave it out and say so.
					if (item.secure && (e as NodeJS.ErrnoException).code !== "ENOENT") skipped.push({ name: item.name, why: "could not be read (damaged, or saved with a key this host lacks)" });
					continue; // otherwise: gone since it was listed
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
			this.writing = null;
			throw e;
		}
		closeSync(fd);
		renameSync(tmp, final);
		this.writing = null;
		return { name, path: final, at, size: statSync(final).size };
	}
}

/** One blob, encrypted: "GHO1" | iv | ciphertext of (flag | data) | tag, where flag 1 means deflated. */
async function sealBlob(data: Buffer, key: Buffer) {
	const deflated = await deflate(data);
	const body = deflated.length < data.length ? Buffer.concat([Buffer.from([1]), deflated]) : Buffer.concat([Buffer.from([0]), data]);
	return seal(BLOB_MAGIC, body, key);
}

function seal(magic: Buffer, body: Buffer, key: Buffer) {
	const iv = randomBytes(12);
	const cipher = createCipheriv("aes-256-gcm", key, iv);
	return Buffer.concat([magic, iv, cipher.update(body), cipher.final(), cipher.getAuthTag()]);
}

function open(magic: Buffer, raw: Buffer, keyHex: string, what: string) {
	if (!/^[0-9a-f]{64}$/i.test(keyHex)) throw new Error("The backup key is not valid");
	if (raw.length < 32 || !raw.subarray(0, 4).equals(magic)) throw new Error(`This is not a GripHub ${what}`);
	try {
		const decipher = createDecipheriv("aes-256-gcm", Buffer.from(keyHex, "hex"), raw.subarray(4, 16));
		decipher.setAuthTag(raw.subarray(raw.length - 16));
		return Buffer.concat([decipher.update(raw.subarray(16, raw.length - 16)), decipher.final()]);
	} catch {
		throw new Error("The backup is damaged, or it was made with another key");
	}
}

/** A blob's name: the key's hash of its content, so the same content is stored once and nothing is told of it. */
function blobId(data: Buffer, key: Buffer) {
	return createHmac("sha256", key).update("griphub-blob\0").update(data).digest("hex");
}

/** A snapshot file, decrypted and checked. */
export function readSnapshot(path: string, keyHex: string): Snapshot {
	const snap = JSON.parse(inflateRawSync(open(SNAP_MAGIC, readFileSync(path), keyHex, "server backup")).toString("utf8"));
	if (snap?.version !== 2 || !Array.isArray(snap.files)) throw new Error("This backup was made by a newer version of GripHub");
	for (const f of snap.files) {
		if (typeof f?.name !== "string" || !BLOB_ID.test(String(f.id))) throw new Error("The backup is damaged");
	}
	return snap;
}

/** A blob's content, from [dir]: decrypted, and checked to be what its name says. */
export function readBlob(dir: string, id: string, keyHex: string): Buffer {
	if (!BLOB_ID.test(id)) throw new Error("The backup is damaged");
	let raw: Buffer;
	try {
		raw = readFileSync(join(dir, id));
	} catch {
		throw new Error("A part of this backup is missing; fetch it again while connected to the server");
	}
	const body = open(BLOB_MAGIC, raw, keyHex, "backup part");
	const data = body[0] === 1 ? inflateRawSync(body.subarray(1)) : body.subarray(1);
	if (blobId(data, Buffer.from(keyHex, "hex")) !== id) throw new Error("The backup is damaged");
	return data;
}

/** Calls [fn] for every regular file under [dir], skipping dependency folders, [skip] paths and links. */
function walk(dir: string, skip: Set<string>, fn: (abs: string, st: { size: number; mtimeMs: number }) => void, workspace = false) {
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
		if (st.isDirectory()) {
			if (workspace && skipInWorkspace(name)) continue;
			walk(abs, skip, fn, workspace);
		} else if (st.isFile()) fn(abs, st);
	}
}

/**
 * Folders of the workspace that stay out: build output, and every folder whose name starts with a dot (a toolchain
 * the agent downloaded into ~/workspace/.toolchains was 590 MB of a 719 MB backup), except a project's `.git`. Dot
 * *files* stay in (a project's .env, .gitignore): they are small, and a restore without them loses real settings.
 */
function skipInWorkspace(name: string) {
	return BUILD_DIRS.has(name) || (name.startsWith(".") && name !== ".git");
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
	return restoreEntries(zipEntries(zipPath), readManifest(zipPath), to);
}

/**
 * Restores a snapshot with its blobs (beside it, in `blobs/`) as [restoreBackup] restores a zip. Every blob is
 * checked first, so a missing or damaged one stops the restore before anything is written.
 */
export function restoreSnapshot(snapPath: string, keyHex: string, to: RestoreTarget) {
	const snap = readSnapshot(snapPath, keyHex);
	const dir = join(dirname(snapPath), "blobs");
	for (const id of new Set(snap.files.map((f) => f.id))) readBlob(dir, id, keyHex);
	function* entries() {
		for (const f of snap.files) yield { name: f.name, data: readBlob(dir, f.id, keyHex) };
	}
	return restoreEntries(entries(), snap, to);
}

/** Whether [path] is a snapshot (else a zip backup), by its first bytes. */
export function isSnapshot(path: string) {
	try {
		const fd = openSync(path, "r");
		try {
			const head = Buffer.alloc(4);
			readSync(fd, head, 0, 4, 0);
			return head.equals(SNAP_MAGIC);
		} finally {
			closeSync(fd);
		}
	} catch {
		return false;
	}
}

function restoreEntries(
	entries: Iterable<{ name: string; data: Buffer }>,
	manifest: { createdAt?: number; workspace?: string; skipped?: unknown[] },
	to: RestoreTarget,
) {
	const fromWs = typeof manifest.workspace === "string" ? manifest.workspace : null;
	// A path of the server's workspace, as the same path in this phone's.
	const rebase = (text: string) => (fromWs && fromWs !== to.workspace ? text.split(fromWs).join(to.workspace) : text);
	let restored = 0;
	let skipped = 0;
	let keptSshKey = false;
	for (const e of entries) {
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
			// A backup made by an older version holds `null` for a store it could not read: writing that would wipe the real one.
			if (value === null || typeof value !== "object") continue;
			if (rel === "griphub/integrations.json" && value && typeof value === "object") {
				const mine = readSecureJson<{ settings?: Record<string, unknown> }>(file, {}, isObject);
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
