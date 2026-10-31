// A host stuck in one loop answers nobody and never exits, so a service manager has nothing to restart. The watchdog
// (watchdog.ts) runs in a thread of its own and kills the process when the main thread stops giving signs of life.
// Each case is a child process, so that a watchdog that does not fire ends as a failure and not a hung test run.
import { test } from "node:test";
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { build } from "esbuild";

const here = dirname(fileURLToPath(import.meta.url));
mkdirSync(join(here, "..", "build"), { recursive: true });
const dir = mkdtempSync(join(here, "..", "build", "wd-"));
process.on("exit", () => rmSync(dir, { recursive: true, force: true }));
await build({ entryPoints: [join(here, "..", "src", "watchdog.ts")], outfile: join(dir, "watchdog.mjs"), bundle: true, platform: "node", format: "esm", logLevel: "error" });

/** Runs [body] in a child that has started the watchdog with a 600 ms limit; resolves with how it ended. */
function child(body, ms = 20_000) {
	const file = join(dir, `c-${Math.random().toString(36).slice(2)}.mjs`);
	writeFileSync(file, `import { startWatchdog } from "./watchdog.mjs";\nconst stop = startWatchdog({ staleMs: 600 });\n${body}\n`);
	return new Promise((resolve) => {
		const p = spawn(process.execPath, [file], { stdio: ["ignore", "pipe", "pipe"] });
		let stderr = "";
		p.stderr.on("data", (d) => (stderr += d));
		const t0 = Date.now();
		const timer = setTimeout(() => p.kill("SIGKILL"), ms);
		p.on("exit", (code, signal) => {
			clearTimeout(timer);
			resolve({ code, signal, stderr, took: Date.now() - t0 });
		});
	});
}

test("a main thread stuck in a loop is killed, and says why", async () => {
	const r = await child(`await new Promise((r) => setTimeout(r, 100)); for (;;) {}`);
	assert.equal(r.signal, "SIGKILL");
	assert.match(r.stderr, /watchdog: the host did nothing for/);
	assert.ok(r.took < 8000, `${r.took} ms`);
});

test("a main thread that is busy for a while but comes back is left alone", async () => {
	// 300 ms stuck three times, with the event loop running in between: under the 600 ms limit each time.
	const r = await child(`
		for (let i = 0; i < 3; i++) {
			await new Promise((r) => setTimeout(r, 200));
			const t = Date.now(); while (Date.now() - t < 300) {}
		}
		stop();
		console.log("done");
	`);
	assert.equal(r.code, 0);
	assert.equal(r.signal, null);
});

test("a host that is idle (waiting on a socket or a timer) is not mistaken for a stuck one", async () => {
	const r = await child(`await new Promise((r) => setTimeout(r, 2500)); stop();`);
	assert.equal(r.code, 0);
});

test("the watchdog does not keep a finished process alive", async () => {
	const r = await child(`console.log("nothing left to do");`);
	assert.equal(r.code, 0);
	assert.ok(r.took < 5000, `${r.took} ms`);
});

test("the host starts it in server mode only, with a limit that can be set", () => {
	const host = readFileSync(join(here, "..", "src", "host.ts"), "utf8");
	assert.match(host, /if \(server\) startWatchdog\(\{ staleMs: Number\(process\.env\.GRIPHUB_WATCHDOG_MS\) \|\| 120_000 \}\)/);
});
