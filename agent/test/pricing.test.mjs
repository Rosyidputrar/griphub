// The per-request estimate the chat totals per turn (and subagents use):
// router rule, floor flag, failed requests free, other providers never priced.
import { test, after } from "node:test";
import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, rmSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { build } from "esbuild";

const here = dirname(fileURLToPath(import.meta.url));
mkdirSync(join(here, "..", "build"), { recursive: true });
const out = mkdtempSync(join(here, "..", "build", "pricing-test-"));
after(() => rmSync(out, { recursive: true, force: true }));
const outfile = join(out, "pricing.mjs");
await build({ entryPoints: [join(here, "..", "src", "pricing.ts")], outfile, bundle: true, platform: "node", format: "esm", packages: "external", logLevel: "error" });
const { messageCost } = await import(pathToFileURL(outfile).href);

const msg = (over) => ({ role: "assistant", provider: "griphub", model: "claude-opus-5.5", stopReason: "stop", ...over });

test("a big cached request costs rate x all tokens (cache included)", () => {
	// 4 credits / 1M x 86101 tokens, as the router charged it.
	const c = messageCost(msg({ usage: { input: 800, output: 2788, cacheRead: 82472, cacheWrite: 41 } }));
	assert.ok(Math.abs(c.credits - 0.344404) < 1e-6, String(c.credits));
	assert.equal(c.floored, false);
});

test("a tiny request is raised to the model's minimum, and says so", () => {
	const c = messageCost(msg({ usage: { input: 100, output: 50 } }));
	assert.equal(c.credits, 0.1);
	assert.equal(c.floored, true);
});

test("a failed request with no output is free; with output it is billed", () => {
	assert.equal(messageCost(msg({ stopReason: "error", usage: { input: 500, output: 0 } })).credits, 0);
	assert.ok(messageCost(msg({ stopReason: "error", usage: { input: 500, output: 20 } })).credits > 0);
});

test("another provider is never priced at GripHub's rate, even for a model with a GripHub name", () => {
	assert.deepEqual(messageCost(msg({ provider: "my-proxy", usage: { input: 1e6, output: 0 } })), { credits: null, floored: false });
});

test("an unknown model has no price; non-assistant messages and messages without usage have no cost", () => {
	assert.equal(messageCost(msg({ model: "my-local-llm", usage: { input: 10, output: 10 } })).credits, null);
	assert.equal(messageCost({ role: "user", content: "hi" }), null);
	assert.equal(messageCost(msg({ usage: undefined })), null);
});
