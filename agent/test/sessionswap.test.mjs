// Replacing the open chat session (sessionswap.ts, used by host.ts openSession). The old code disposed the open session and
// then built the new one: a build that failed left the host holding a disposed session, and two switches at once each
// disposed "the current one" and built their own, leaving one of the two never disposed.
import { test } from "node:test";
import assert from "node:assert/strict";
import { bundle } from "./helpers.mjs";

const { swapSession, serialQueue } = await bundle("sessionswap");

/** A session that remembers what was done to it, and a host-like holder with the same four steps openSession has. */
function world() {
	const log = [];
	const w = {
		log,
		current: null,
		busy: false,
		sessions: [],
		make(name) {
			const s = { name, disposed: false, dispose() { this.disposed = true; log.push(`dispose ${name}`); } };
			w.sessions.push(s);
			return s;
		},
		swap(build) {
			return swapSession({
				assertIdle: () => {
					if (w.busy) throw new Error("busy");
				},
				build,
				retire: () => {
					log.push("retire");
					w.current?.dispose();
				},
				install: (next) => {
					w.current = next;
					log.push(`install ${next.name}`);
				},
			});
		},
	};
	return w;
}
const later = (ms) => new Promise((r) => setTimeout(r, ms));

test("the new session is built before the old one is let go of", async () => {
	const w = world();
	w.current = w.make("old");
	await w.swap(async () => {
		w.log.push("build start");
		await later(20);
		w.log.push("build done");
		assert.equal(w.current.disposed, false, "the old one is still alive while the new one is built");
		return w.make("new");
	});
	assert.deepEqual(w.log, ["build start", "build done", "retire", "dispose old", "install new"]);
	assert.equal(w.current.name, "new");
});

test("a build that fails leaves the open session as it was", async () => {
	const w = world();
	w.current = w.make("old");
	await assert.rejects(
		w.swap(async () => {
			throw new Error("chat file will not open");
		}),
		/chat file will not open/,
	);
	assert.equal(w.current.name, "old");
	assert.equal(w.current.disposed, false, "and it is not disposed");
	assert.deepEqual(w.log, []);
});

test("a turn that started while the new session was being built keeps its session; the new one is disposed", async () => {
	const w = world();
	w.current = w.make("old");
	await assert.rejects(
		w.swap(async () => {
			await later(10);
			w.busy = true; // the user sent a prompt meanwhile
			return w.make("new");
		}),
		/busy/,
	);
	assert.equal(w.current.name, "old");
	assert.equal(w.current.disposed, false);
	assert.equal(w.sessions.find((s) => s.name === "new").disposed, true, "nothing leaks");
});

test("switches run one at a time, in order, and every session that is replaced is disposed", async () => {
	const w = world();
	const once = serialQueue();
	w.current = w.make("s0");
	let building = 0;
	let overlapped = false;
	const open = (name, ms) =>
		once(() =>
			w.swap(async () => {
				if (++building > 1) overlapped = true;
				await later(ms);
				building--;
				return w.make(name);
			}),
		);
	await Promise.all([open("s1", 40), open("s2", 5), open("s3", 20)]);
	assert.equal(overlapped, false, "never two builds at once");
	assert.equal(w.current.name, "s3", "the last one asked for is open");
	assert.deepEqual(w.sessions.filter((s) => s !== w.current).map((s) => s.disposed), [true, true, true], "s0, s1 and s2 were all disposed");
});

test("a failed switch does not stop the ones after it", async () => {
	const w = world();
	const once = serialQueue();
	w.current = w.make("s0");
	const first = once(() => w.swap(async () => { throw new Error("no"); }));
	const second = once(() => w.swap(async () => w.make("s2")));
	await assert.rejects(first, /no/);
	await second;
	assert.equal(w.current.name, "s2");
});
