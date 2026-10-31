// Shared by the tests: host modules bundled from src (they import each other with ".js" suffixes, which node cannot
// resolve to .ts on its own), and temporary folders that clean up after themselves.
import { mkdirSync, mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { build } from "esbuild";

const here = dirname(fileURLToPath(import.meta.url));
let out;

/** The module src/<name>.ts, bundled once per test file (packages stay external, as in build.mjs). */
export async function bundle(name) {
	if (!out) {
		mkdirSync(join(here, "..", "build"), { recursive: true });
		out = mkdtempSync(join(here, "..", "build", "test-"));
		process.on("exit", () => rmSync(out, { recursive: true, force: true }));
	}
	const outfile = join(out, `${name.replace(/\W/g, "_")}.mjs`);
	await build({ entryPoints: [join(here, "..", "src", `${name}.ts`)], outfile, bundle: true, platform: "node", format: "esm", packages: "external", logLevel: "error" });
	return import(pathToFileURL(outfile).href);
}

/** A fresh temporary directory that is removed when the test finishes. Short: unix socket paths are limited. */
export function tempDir(t, prefix = "gh-") {
	const dir = mkdtempSync(join(tmpdir(), prefix));
	// Retried: t.after hooks run in registration order, so this runs while the test's host process (killed by a
	// later hook) may still be writing its seed files - the first sweep then races a growing directory (ENOTEMPTY).
	t.after(() => rmSync(dir, { recursive: true, force: true, maxRetries: 10, retryDelay: 100 }));
	return dir;
}

/** Waits until [ok] holds, or fails saying what it waited for. */
export async function waitFor(what, ok, ms = 30_000) {
	const t0 = Date.now();
	while (!ok()) {
		if (Date.now() - t0 > ms) throw new Error(`timed out waiting for ${what}`);
		await new Promise((r) => setTimeout(r, 25));
	}
}

/** Connects to a daemon's socket and collects the records it sends. */
export async function dial(path) {
	const net = await import("node:net");
	const socket = net.connect(path);
	socket.setEncoding("utf8");
	const records = [];
	let rest = "";
	let ended = false;
	socket.on("data", (chunk) => {
		rest += chunk;
		let nl;
		while ((nl = rest.indexOf("\n")) >= 0) {
			const line = rest.slice(0, nl);
			rest = rest.slice(nl + 1);
			if (line.trim()) records.push(JSON.parse(line));
		}
	});
	socket.on("close", () => (ended = true));
	await new Promise((resolve, reject) => {
		socket.once("connect", resolve);
		socket.once("error", reject);
	});
	const send = (record) => socket.write(`${JSON.stringify(record)}\n`);
	const until = async (test, ms = 2000) => {
		const t0 = Date.now();
		while (!test()) {
			if (Date.now() - t0 > ms) throw new Error(`timed out; got ${JSON.stringify(records.map((r) => r.type))}`);
			await new Promise((r) => setTimeout(r, 5));
		}
	};
	return { socket, records, send, until, get ended() { return ended; } };
}
