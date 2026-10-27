// Subagent cost: credits move per model request (router rule: floor, cache
// tokens, failed requests free), and the record names the model and thinking
// level. Uses a scripted fake session; no network.
import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, rmSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { build } from "esbuild";

const here = dirname(fileURLToPath(import.meta.url));
mkdirSync(join(here, "..", "build"), { recursive: true });
const out = mkdtempSync(join(here, "..", "build", "subagent-test-"));
async function bundle(name) {
	const outfile = join(out, `${name}.mjs`);
	await build({ entryPoints: [join(here, "..", "src", `${name}.ts`)], outfile, bundle: true, platform: "node", format: "esm", packages: "external", logLevel: "error" });
	return import(pathToFileURL(outfile).href);
}
const { SubagentManager } = await bundle("subagent");

/** A session that replays [steps] (assistant messages) when prompted. */
function fakeSession(steps, model = { provider: "griphub", id: "claude-opus-5.5", name: "Claude Opus 5.5" }) {
	let listener;
	const totals = { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 };
	return {
		model,
		thinkingLevel: "high",
		subscribe(fn) {
			listener = fn;
			return () => {};
		},
		async prompt() {
			listener({ type: "agent_start" });
			for (const m of steps) {
				for (const k of Object.keys(totals)) totals[k] += m.usage[k] ?? 0;
				listener({ type: "message_end", message: { role: "assistant", model: model.id, ...m } });
			}
			listener({ type: "agent_end" });
		},
		getSessionStats: () => ({ tokens: { ...totals } }),
		getLastAssistantText: () => "Laporan",
		abort() {},
		dispose() {},
	};
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

test("credits add up per request with floor and cache; model and thinking level recorded", async () => {
	const session = fakeSession([
		// A tiny step: 0.0006 by tokens, billed at opus's 0.1 floor.
		{ usage: { input: 100, output: 50, cacheRead: 0, cacheWrite: 0 } },
		// A big cached step: 4/M × 86101 tokens = 0.344404 (matches a real router charge).
		{ usage: { input: 800, output: 2788, cacheRead: 82472, cacheWrite: 41 } },
		// A failed request is free.
		{ stopReason: "error", errorMessage: "upstream", usage: { input: 500, output: 0 } },
	]);
	const { m, sent } = manager(session);
	const rec = m.start(parent, "Tugas", "read");
	const done = await m.waitFor(rec.id);
	assert.equal(done.model, "claude-opus-5.5");
	assert.equal(done.modelName, "Claude Opus 5.5");
	assert.equal(done.thinkingLevel, "high");
	assert.equal(done.rate, 4);
	assert.equal(done.requests, 3);
	assert.equal(done.flooredRequests, 1);
	assert.ok(Math.abs(done.credits - (0.1 + 0.344404)) < 1e-6, `credits ${done.credits}`);
	assert.equal(done.cacheReadTokens, 82472);
	// The card saw the cost grow step by step, not only at the end.
	const live = sent.filter((r) => r.type === "subagent_status" && r.credits !== null).map((r) => r.credits);
	assert.ok(live.length >= 2 && live[0] < live.at(-1), `live credits ${live}`);
	assert.ok(sent.some((r) => r.type === "subagent_status" && r.thinkingLevel === "high" && r.model === "claude-opus-5.5"));
});

test("an unknown model keeps credits unknown instead of a made-up number", async () => {
	const session = fakeSession([{ usage: { input: 10, output: 10 } }], { provider: "custom", id: "my-local-llm", name: "Local" });
	const { m } = manager(session);
	const done = await m.waitFor(m.start({ ...parent, modelId: "my-local-llm" }, "Tugas", "read").id);
	assert.equal(done.credits, null);
	assert.equal(done.rate, null);
	assert.equal(done.requests, 1);
});

test("the cost limit sees the floor: tiny steps on opus stop at the limit", async () => {
	const steps = Array.from({ length: 30 }, () => ({ usage: { input: 50, output: 10 } }));
	const session = fakeSession(steps);
	const sent = [];
	const m = new SubagentManager({
		send: (r) => sent.push(r),
		wireEvent: (e) => e,
		createSession: async () => session,
		limits: () => ({ creditLimit: 1, minutesLimit: 0, approvalMode: "auto" }),
	});
	const done = await m.waitFor(m.start(parent, "Tugas", "read").id);
	// 30 floor-billed steps = 3 credits; the old estimate (tokens only) said 0.007.
	assert.ok(done.credits >= 1, `credits ${done.credits}`);
	assert.equal(done.status, "stopped");
	assert.equal(done.stopCode, "credit");
});

test("cleanup", () => rmSync(out, { recursive: true, force: true }));
