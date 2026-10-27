// Subagent run boundaries, against a fake session that behaves like pi's
// AgentSession: a run can emit agent_end more than once (auto-retry,
// compaction, queued follow-ups), the session stays busy until agent_settled,
// and prompt() while busy throws the same error pi throws. Regressions:
//   - a message queued while the subagent works made it fail with
//     "Agent is already processing ..." instead of being sent;
//   - a run pi was still retrying was finished (and its session disposed) at
//     the first agent_end, reported as failed.
import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, rmSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { build } from "esbuild";

const here = dirname(fileURLToPath(import.meta.url));
mkdirSync(join(here, "..", "build"), { recursive: true });
const out = mkdtempSync(join(here, "..", "build", "subagent-queue-test-"));
async function bundle(name) {
	const outfile = join(out, `${name}.mjs`);
	await build({ entryPoints: [join(here, "..", "src", `${name}.ts`)], outfile, bundle: true, platform: "node", format: "esm", packages: "external", logLevel: "error" });
	return import(pathToFileURL(outfile).href);
}
const { SubagentManager } = await bundle("subagent");

const tick = () => new Promise((r) => setTimeout(r, 0));

/**
 * [runs] is one script per prompt(): a list of "attempts", each a list of
 * assistant messages followed by agent_end. More than one attempt means pi
 * retried (agent_end with willRetry) inside the same run.
 */
function piLikeSession(runs, { onPrompt } = {}) {
	let listener;
	let streaming = false;
	let last = "";
	const prompts = [];
	const usage = { input: 10, output: 10, cacheRead: 0, cacheWrite: 0 };
	const session = {
		model: { provider: "griphub", id: "claude-opus-5.5", name: "Claude Opus 5.5" },
		thinkingLevel: "medium",
		get isStreaming() {
			return streaming;
		},
		subscribe(fn) {
			listener = fn;
			return () => {};
		},
		async prompt(text, options) {
			if (streaming && !options?.streamingBehavior) {
				throw new Error("Agent is already processing. Specify streamingBehavior ('steer' or 'followUp') to queue the message.");
			}
			prompts.push(text);
			onPrompt?.(text, prompts.length);
			const script = runs[prompts.length - 1] ?? [[{ text: `answer ${prompts.length}` }]];
			streaming = true;
			for (let a = 0; a < script.length; a++) {
				listener({ type: "agent_start" });
				for (const m of script[a]) {
					await tick();
					if (m.text) last = m.text;
					listener({
						type: "message_end",
						message: { role: "assistant", model: "claude-opus-5.5", usage, content: [{ type: "text", text: m.text ?? "" }], ...m },
					});
				}
				await tick();
				// The app's listener runs here, while pi still counts the run as active.
				listener({ type: "agent_end", willRetry: a < script.length - 1 });
			}
			await tick();
			streaming = false;
			listener({ type: "agent_settled", aborted: false });
		},
		getSessionStats: () => ({ tokens: { ...usage } }),
		getLastAssistantText: () => last,
		abort() {},
		dispose() {
			session.disposed = true;
			// pi still running the run: tearing it down here loses the rest of it.
			if (streaming) session.disposedWhileRunning = true;
		},
		prompts,
		disposed: false,
		disposedWhileRunning: false,
	};
	return session;
}

function manager(session) {
	const sent = [];
	const m = new SubagentManager({
		send: (r) => sent.push(r),
		wireEvent: (e) => e,
		createSession: async () => session,
		limits: () => ({ creditLimit: 0, minutesLimit: 0, approvalMode: "auto" }),
	});
	return { m, sent };
}

const parent = { sessionFile: "chat.jsonl", title: "t", cwd: "/tmp", modelId: "claude-opus-5.5" };

test("a message queued while the subagent works is sent as the next turn, not a failure", async () => {
	let m;
	let id;
	const session = piLikeSession([[[{ text: "first part" }]], [[{ text: "after the follow-up" }]]], {
		// The user queues a message while the first turn is running.
		onPrompt: (_text, n) => {
			if (n === 1) setTimeout(() => m.queueMessage(id, "also check the volume"), 0);
		},
	});
	({ m } = manager(session));
	id = m.start(parent, "Research IHSG", "read").id;
	const done = await m.waitFor(id);
	assert.equal(done.status, "done", `error: ${done.error}`);
	assert.equal(done.error, undefined);
	assert.equal(session.prompts.length, 2);
	assert.equal(session.prompts[1], "also check the volume");
	assert.equal(done.report, "after the follow-up");
	assert.deepEqual(done.queue, []);
});

test("several queued messages go out one per turn, in order", async () => {
	let m;
	let id;
	const session = piLikeSession([], {
		onPrompt: (_text, n) => {
			if (n === 1) {
				setTimeout(() => {
					m.queueMessage(id, "one");
					m.queueMessage(id, "two");
				}, 0);
			}
		},
	});
	({ m } = manager(session));
	id = m.start(parent, "Brief", "read").id;
	const done = await m.waitFor(id);
	assert.equal(done.status, "done", `error: ${done.error}`);
	assert.deepEqual(session.prompts.slice(1), ["one", "two"]);
});

test("a run pi retries is not finished at the first agent_end", async () => {
	const session = piLikeSession([
		[
			// First attempt: the connection drops.
			[{ stopReason: "error", errorMessage: "Connection error.", usage: { input: 5, output: 0 } }],
			// pi retries inside the same run and succeeds.
			[{ text: "full report" }],
		],
	]);
	const { m } = manager(session);
	const done = await m.waitFor(m.start(parent, "Brief", "read").id);
	assert.equal(done.status, "done", `error: ${done.error}`);
	assert.equal(done.report, "full report");
	assert.equal(done.requests, 2);
});

test("a run whose last attempt still fails is reported as failed with the model's error", async () => {
	const session = piLikeSession([[[{ stopReason: "error", errorMessage: "Connection error.", usage: { input: 5, output: 0 } }]]]);
	const { m } = manager(session);
	const done = await m.waitFor(m.start(parent, "Brief", "read").id);
	assert.equal(done.status, "failed");
	assert.equal(done.error, "Connection error.");
});

test("the session is disposed only after the run settles", async () => {
	// Two attempts in one run: the first agent_end must not tear the session down.
	const session = piLikeSession([[[{ text: "a" }], [{ text: "b" }]]]);
	const { m } = manager(session);
	const done = await m.waitFor(m.start(parent, "Brief", "read").id);
	assert.equal(session.disposedWhileRunning, false);
	assert.equal(session.disposed, true);
	assert.equal(done.status, "done");
	assert.equal(done.report, "b");
});

test("cleanup", () => rmSync(out, { recursive: true, force: true }));
