/**
 * At-rest encryption for the app's own secrets (GitHub/Vercel tokens, search
 * keys, MCP env/headers). The key is created and wrapped by the Android
 * Keystore on the Kotlin side and handed to the host as GRIPHUB_STORE_KEY.
 * Files written before encryption was enabled are read as plain JSON and
 * encrypted on the next save.
 *
 * A store is written whole or not at all, with the last good copy kept beside it, and one that cannot be read is
 * set aside and reported instead of being taken for an empty one (state.ts).
 */

import { createCipheriv, createDecipheriv, randomBytes } from "node:crypto";
import { readFileSync } from "node:fs";
import { StoreLocked, atomicWrite, keepBackup, loadStore } from "./state.js";

const PREFIX = "enc1:";

// Read once at import: the host process starts with the key in env (Kotlin
// side). Caching it here and deleting it from process.env keeps the master
// key out of every shell and MCP server the host spawns afterwards, while
// this module keeps working through the cached copy.
const CACHED_KEY: Buffer | null = (() => {
	const hex = process.env.GRIPHUB_STORE_KEY;
	delete process.env.GRIPHUB_STORE_KEY;
	return hex && /^[0-9a-f]{64}$/i.test(hex) ? Buffer.from(hex, "hex") : null;
})();

function key(): Buffer | null {
	return CACHED_KEY;
}

/** The JSON in [file], decrypted when it is encrypted. Throws when it cannot be read (StoreLocked when only the key is missing). */
function decode(file: string): unknown {
	const raw = readFileSync(file, "utf8");
	if (!raw.startsWith(PREFIX)) return JSON.parse(raw);
	const k = key();
	if (!k) throw new StoreLocked();
	const buf = Buffer.from(raw.slice(PREFIX.length), "base64");
	const decipher = createDecipheriv("aes-256-gcm", k, buf.subarray(0, 12));
	decipher.setAuthTag(buf.subarray(12, 28));
	return JSON.parse(Buffer.concat([decipher.update(buf.subarray(28)), decipher.final()]).toString("utf8"));
}

/** Every store holds an object or a list; `null` is what an unreadable one used to turn into. */
const present = (v: unknown) => v !== null && v !== undefined;

/**
 * The store in [file], or [fallback] when there is none. A store that is there but unreadable (cut short, saved with
 * another key) or of the wrong shape ([valid]) is not an empty one: it is moved aside, the last good copy is used if
 * there is one, and the host tells the person (see loadStore).
 */
export function readSecureJson<T>(file: string, fallback: T, valid: (v: unknown) => boolean = present): T {
	return loadStore(file, decode, fallback, (v) => present(v) && valid(v));
}

/** The JSON in [file] as it is, for a caller that must know whether it could be read: throws when it cannot. */
export function readSecureJsonStrict(file: string): unknown {
	return decode(file);
}

export function writeSecureJson(file: string, value: unknown) {
	if (value === null || value === undefined) throw new Error("Refusing to write an empty store.");
	const json = JSON.stringify(value, null, 2);
	const k = key();
	if (!k) {
		// Fail closed: writing secrets in plaintext because the Keystore key
		// is missing used to silently downgrade every stored token.
		throw new Error("No store key available: refusing to write secrets in plaintext. Restart the app (or reset saved keys) and try again.");
	}
	const iv = randomBytes(12);
	const cipher = createCipheriv("aes-256-gcm", k, iv);
	const ct = Buffer.concat([cipher.update(json, "utf8"), cipher.final()]);
	keepBackup(file, decode, present);
	atomicWrite(file, PREFIX + Buffer.concat([iv, cipher.getAuthTag(), ct]).toString("base64"));
}
