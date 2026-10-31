/**
 * A host that is stuck in one piece of synchronous work (a regular expression gone wrong, a loop) answers nobody and
 * cannot be asked to stop: its own timers do not run. On a server, systemd restarts a host that exits, but one that
 * hangs never exits, so the app would wait on it forever.
 *
 * The main thread bumps a counter every [tickMs]. A worker thread, which keeps running while the main thread is stuck,
 * looks at the counter and, when it has not moved for [staleMs], kills the process. The service manager starts a
 * fresh one. The worker is not what keeps the process alive, and it only exists in server mode (a phone's host is
 * restarted by the app).
 */

import { Worker } from "node:worker_threads";

export interface WatchdogOptions {
	/** How long the main thread may go without bumping the counter before the process is killed. */
	staleMs: number;
	/** How often the counter is bumped (and looked at). Default: a quarter of [staleMs], at most 1 s. */
	tickMs?: number;
	/** The signal that kills the process (default SIGKILL: a stuck main thread would not act on a gentler one). */
	signal?: NodeJS.Signals;
}

const WORKER = `
const { workerData } = require("node:worker_threads");
const { writeSync } = require("node:fs");
const { counter, staleMs, tickMs, signal, pid } = workerData;
const view = new Int32Array(counter);
let seen = Atomics.load(view, 0);
let since = Date.now();
setInterval(() => {
	const now = Atomics.load(view, 0);
	if (now !== seen) {
		seen = now;
		since = Date.now();
	} else if (Date.now() - since >= staleMs) {
		// A worker's process.stderr goes through the main thread, which is the one that is stuck: write to the file itself.
		writeSync(2, "[host] watchdog: the host did nothing for " + Math.round((Date.now() - since) / 1000) + " s; killing it so the service restarts it\\n");
		process.kill(pid, signal);
	}
}, tickMs);
`;

/** Starts watching this process. Returns a function that stops the watch. */
export function startWatchdog(options: WatchdogOptions): () => void {
	const tickMs = options.tickMs ?? Math.max(50, Math.min(1000, Math.floor(options.staleMs / 4)));
	const counter = new SharedArrayBuffer(4);
	const view = new Int32Array(counter);
	const worker = new Worker(WORKER, {
		eval: true,
		workerData: { counter, staleMs: options.staleMs, tickMs, signal: options.signal ?? "SIGKILL", pid: process.pid },
	});
	worker.unref();
	worker.on("error", (e) => console.error("[host] watchdog stopped:", e));
	const beat = setInterval(() => Atomics.add(view, 0, 1), tickMs);
	beat.unref();
	return () => {
		clearInterval(beat);
		void worker.terminate();
	};
}
