// Follow-ups queued while the agent works: shown as waiting bubbles,
// delivered in order at the boundary, cancellable one at a time.
import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, rmSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { build } from "esbuild";

const here = dirname(fileURLToPath(import.meta.url));
mkdirSync(join(here, "..", "build"), { recursive: true });
const out = mkdtempSync(join(here, "..", "build", "queue-test-"));
const outfile = join(out, "promptqueue.mjs");
await build({ entryPoints: [join(here, "..", "src", "promptqueue.ts")], outfile, bundle: true, platform: "node", format: "esm", logLevel: "error" });
const { PromptQueue } = await import(pathToFileURL(outfile).href);

/** pi's queue, as far as PromptQueue sees it. */
function fakeSession() {
	const s = {
		isStreaming: true,
		queue: [],
		started: [],
		async prompt(text, opts = {}) {
			await Promise.resolve();
			if (opts.streamingBehavior === "followUp" && s.isStreaming) s.queue.push({ text, images: opts.images });
			else {
				s.started.push(text);
				s.isStreaming = true;
			}
		},
		clearQueue() {
			const followUp = s.queue.map((q) => q.text);
			s.queue = [];
			return { steering: [], followUp };
		},
		getFollowUpMessages: () => s.queue.map((q) => q.text),
		/** The turn reaches its boundary and takes the oldest one. */
		deliver() {
			return s.queue.shift();
		},
	};
	return s;
}

test("queued follow-ups are listed, delivered in order, and keep their images", async () => {
	const emitted = [];
	const q = new PromptQueue((items) => emitted.push(items.map((i) => i.text)));
	const s = fakeSession();
	const a = await q.add(s, "satu", "satu");
	const b = await q.add(s, "dua", "dua", [{ type: "image", data: "x" }]);
	assert.ok(a && b && a !== b);
	assert.deepEqual(q.list().map((i) => [i.text, i.images]), [["satu", 0], ["dua", 1]]);
	s.deliver();
	q.sync(s.queue.length);
	assert.deepEqual(q.list().map((i) => i.text), ["dua"], "the oldest was delivered");
	assert.deepEqual(emitted.at(-1), ["dua"]);
});

test("cancelling one clears pi's queue and queues the rest again in order, images kept", async () => {
	const q = new PromptQueue(() => {});
	const s = fakeSession();
	const ids = [];
	for (const t of ["a", "b", "c"]) ids.push(await q.add(s, t, t, t === "c" ? [{ type: "image" }] : undefined));
	const r = await q.remove(s, ids[1]);
	assert.deepEqual(s.queue.map((x) => x.text), ["a", "c"]);
	assert.deepEqual(s.queue[1].images, [{ type: "image" }]);
	assert.deepEqual(r.items, [ids[0], ids[2]]);
	assert.deepEqual(q.list().map((i) => i.id), [ids[0], ids[2]], "ids survive the rebuild");
	await assert.rejects(q.remove(s, ids[1]), /already sent/);
});

test("pi's own queue updates during a rebuild are ignored", async () => {
	const q = new PromptQueue(() => {});
	const s = fakeSession();
	const ids = [await q.add(s, "a", "a"), await q.add(s, "b", "b")];
	const realClear = s.clearQueue;
	s.clearQueue = () => {
		const r = realClear();
		q.sync(0); // pi emits queue_update(followUp: []) from clearQueue
		return r;
	};
	await q.remove(s, ids[0]);
	assert.deepEqual(q.list().map((i) => i.text), ["b"]);
});

test("if the turn ended meanwhile, the first remaining message starts the next turn", async () => {
	const q = new PromptQueue(() => {});
	const s = fakeSession();
	const ids = [await q.add(s, "a", "a"), await q.add(s, "b", "b"), await q.add(s, "c", "c")];
	s.isStreaming = false;
	await q.remove(s, ids[0], 200);
	assert.deepEqual(s.started, ["b"]);
	assert.deepEqual(s.queue.map((x) => x.text), ["c"]);
	assert.deepEqual(q.list().map((i) => i.text), ["c"]);
});

test("a boundary that consumed the message during the call leaves nothing waiting", async () => {
	const q = new PromptQueue(() => {});
	const s = fakeSession();
	const realPrompt = s.prompt;
	s.prompt = async (t, o) => {
		await realPrompt(t, o);
		s.deliver();
	};
	assert.equal(await q.add(s, "x", "x"), null);
	assert.deepEqual(q.list(), []);
});

test("closing the chat drops the queue; the bubble shows what the user typed", async () => {
	const emitted = [];
	const q = new PromptQueue((items) => emitted.push(items));
	const s = fakeSession();
	await q.add(s, "tolong cek\n\n[Plan mode] Investigate…", "tolong cek");
	assert.equal(q.list()[0].text, "tolong cek");
	q.clear();
	assert.deepEqual(emitted.at(-1), []);
});

test("cleanup", () => rmSync(out, { recursive: true, force: true }));
