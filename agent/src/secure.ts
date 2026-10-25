/**
 * At-rest encryption for the app's own secrets (GitHub/Vercel tokens, search
 * keys, MCP env/headers). The key is created and wrapped by the Android
 * Keystore on the Kotlin side and handed to the host as GRIPHUB_STORE_KEY.
 * Files written before encryption was enabled are read as plain JSON and
 * encrypted on the next save.
 */

import { createCipheriv, createDecipheriv, randomBytes } from "node:crypto";
import { existsSync, readFileSync, writeFileSync } from "node:fs";

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

export function readSecureJson<T>(file: string, fallback: T): T {
	if (!existsSync(file)) return fallback;
	const raw = readFileSync(file, "utf8");
	try {
		if (!raw.startsWith(PREFIX)) return JSON.parse(raw);
		const k = key();
		if (!k) return fallback;
		const buf = Buffer.from(raw.slice(PREFIX.length), "base64");
		const decipher = createDecipheriv("aes-256-gcm", k, buf.subarray(0, 12));
		decipher.setAuthTag(buf.subarray(12, 28));
		return JSON.parse(Buffer.concat([decipher.update(buf.subarray(28)), decipher.final()]).toString("utf8"));
	} catch {
		return fallback;
	}
}

export function writeSecureJson(file: string, value: unknown) {
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
	writeFileSync(file, PREFIX + Buffer.concat([iv, cipher.getAuthTag(), ct]).toString("base64"), { mode: 0o600 });
}
