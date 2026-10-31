/**
 * How the host keeps its own state files (sign-ins, settings, MCP servers, runs, sync): written whole or not at all,
 * and never mistaken for empty.
 *
 * Two things used to go wrong. A save was `writeFileSync`, which empties the file and then fills it, so a host that
 * died in between (out of memory, a stop timeout, a swiped-away app, a full disk) left half a file. And a file that could
 * not be read was treated as one with nothing in it: the host started without its sign-ins and settings, said nothing,
 * and the first save wrote that emptiness over what was left.
 *
 * Now a save goes to a temporary file that is flushed and renamed into place, after the last good copy was kept as
 * `<file>.bak`. A file that cannot be read is moved aside (`<file>.corrupt-<time>`, never deleted), the last good copy
 * takes its place when there is one, and the person is told either way.
 */

import { closeSync, copyFileSync, existsSync, fsyncSync, openSync, readFileSync, readdirSync, renameSync, rmSync, writeSync } from "node:fs";
import { basename, dirname, join } from "node:path";

/** Written whole or not at all: [data] goes to a temporary file next to [file], is flushed, and is renamed over it. */
export function atomicWrite(file: string, data: string | Buffer, mode = 0o600): void {
	const tmp = `${file}.tmp-${process.pid}`;
	let fd = -1;
	try {
		fd = openSync(tmp, "w", mode);
		const bytes = typeof data === "string" ? Buffer.from(data, "utf8") : data;
		for (let at = 0; at < bytes.length; ) at += writeSync(fd, bytes, at);
		fsyncSync(fd);
		closeSync(fd);
		fd = -1;
		renameSync(tmp, file);
	} catch (e) {
		if (fd >= 0) closeSync(fd);
		rmSync(tmp, { force: true });
		throw e;
	}
	// The rename itself is flushed too; some file systems do not allow opening a folder, which is no reason to fail.
	try {
		const dir = openSync(dirname(file), "r");
		try {
			fsyncSync(dir);
		} finally {
			closeSync(dir);
		}
	} catch {}
}

/** The encrypted file cannot be read because this host has no key for it: the file itself may be fine. */
export class StoreLocked extends Error {
	constructor() {
		super("the store is encrypted and there is no store key");
		this.name = "StoreLocked";
	}
}

export interface StoreProblem {
	file: string;
	/** `recovered`: the last good copy took its place. `quarantined`: nothing to take its place, it starts empty. `locked`: left alone, not loaded. */
	kind: "recovered" | "quarantined" | "locked";
	/** Where the unreadable file was moved to. */
	moved?: string;
}

export function storeProblemMessage(p: StoreProblem): string {
	const name = basename(p.file);
	const kept = p.moved ? basename(p.moved) : "";
	if (p.kind === "locked") return `${name} is saved encrypted, but this host has no store key for it, so it was left untouched and not loaded. Restart the app; nothing was overwritten.`;
	if (p.kind === "recovered") return `${name} was damaged, so the last good copy was loaded instead (the damaged file was kept as ${kept}). Changes made since that copy may be missing.`;
	return `${name} could not be read (damaged, or saved with a different key), so it was set aside as ${kept} and started empty. Sign-ins or settings may be missing: restore from a backup, or put the key back and rename that file.`;
}

const problems: StoreProblem[] = [];
let listener: ((p: StoreProblem) => void) | null = null;

export function reportStoreProblem(p: StoreProblem): void {
	if (listener) listener(p);
	else problems.push(p);
}

/** [fn] hears of every problem from now on, and of those found before it asked. */
export function onStoreProblem(fn: ((p: StoreProblem) => void) | null): void {
	listener = fn;
	if (fn) for (const p of problems.splice(0)) fn(p);
}

const KEEP_CORRUPT = 3;

/** Moves an unreadable [file] aside as `<file>.corrupt-<time>` (the newest few are kept). Returns where it went, or null. */
export function quarantine(file: string): string | null {
	const moved = `${file}.corrupt-${Date.now()}`;
	try {
		renameSync(file, moved);
	} catch {
		return null;
	}
	try {
		const prefix = `${basename(file)}.corrupt-`;
		const old = readdirSync(dirname(file)).filter((f) => f.startsWith(prefix)).sort();
		for (const f of old.slice(0, Math.max(0, old.length - KEEP_CORRUPT))) rmSync(join(dirname(file), f), { force: true });
	} catch {}
	return moved;
}

export const backupOf = (file: string) => `${file}.bak`;

/** What [read] returns for [file] when it is readable and [valid]; otherwise null (it threw, or the shape is wrong). `locked` when the key is missing. */
function attempt(file: string, read: (file: string) => unknown, valid: (v: unknown) => boolean): { value: unknown } | "locked" | null {
	try {
		const value = read(file);
		return valid(value) ? { value } : null;
	} catch (e) {
		return e instanceof StoreLocked || (e as Error)?.name === "StoreLocked" ? "locked" : null;
	}
}

/**
 * The value stored in [file] through [read], or [fallback] when there is no file. A file that is there but cannot be
 * read is never taken for an empty one: it is moved aside, the last good copy is used when there is one, and the problem
 * is reported (reportStoreProblem). A file that only waits for a key is left exactly as it is.
 */
export function loadStore<T>(file: string, read: (file: string) => unknown, fallback: T, valid: (v: unknown) => boolean): T {
	if (!existsSync(file)) return fallback;
	const now = attempt(file, read, valid);
	if (now === "locked") {
		reportStoreProblem({ file, kind: "locked" });
		return fallback;
	}
	if (now) return now.value as T;
	const moved = quarantine(file) ?? undefined;
	const back = existsSync(backupOf(file)) ? attempt(backupOf(file), read, valid) : null;
	if (back && back !== "locked") {
		try {
			copyFileSync(backupOf(file), file);
		} catch {}
		reportStoreProblem({ file, kind: "recovered", moved });
		return back.value as T;
	}
	reportStoreProblem({ file, kind: "quarantined", moved });
	return fallback;
}

/** Keeps the file as the last good copy, `<file>.bak`, when it can be read: a damaged one never replaces a good copy. */
export function keepBackup(file: string, read: (file: string) => unknown, valid: (v: unknown) => boolean): void {
	if (!existsSync(file)) return;
	const now = attempt(file, read, valid);
	if (!now || now === "locked") return;
	try {
		copyFileSync(file, `${backupOf(file)}.tmp-${process.pid}`);
		renameSync(`${backupOf(file)}.tmp-${process.pid}`, backupOf(file));
	} catch {
		rmSync(`${backupOf(file)}.tmp-${process.pid}`, { force: true });
	}
}

export const isObject = (v: unknown): v is Record<string, unknown> => typeof v === "object" && v !== null && !Array.isArray(v);

/** The JSON in a plain (not encrypted) state file; throws when it cannot be read. */
export const readJsonFile = (file: string): unknown => JSON.parse(readFileSync(file, "utf8"));
