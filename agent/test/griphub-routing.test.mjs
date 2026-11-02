// Per-model routing inside GripHub Router: every model goes to the router with the same key, only the wire format
// follows the model family (Anthropic -> /v1/messages, GPT -> /v1/responses, the rest -> /v1/chat/completions).
import { test } from "node:test";
import assert from "node:assert/strict";
import { randomBytes } from "node:crypto";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { bundle, tempDir } from "./helpers.mjs";

// secure.ts reads the store key once, at import.
process.env.GRIPHUB_STORE_KEY = randomBytes(32).toString("hex");
const { CustomProviders, griphubApiFor, vendorThinking, GRIPHUB_ORIGIN, GRIPHUB_BASE_URL } = await bundle("providers");

test("the model family picks the router endpoint", () => {
	assert.equal(griphubApiFor("claude-sonnet-5.5"), "anthropic-messages");
	assert.equal(griphubApiFor("claude-opus-4.8"), "anthropic-messages");
	assert.equal(griphubApiFor("Claude-Haiku-5.5"), "anthropic-messages");
	assert.equal(griphubApiFor("gpt-6.1-sol"), "openai-responses");
	assert.equal(griphubApiFor("gpt-5.6-luna"), "openai-responses");
	assert.equal(griphubApiFor("o3-mini"), "openai-responses");
	for (const id of ["gemini-3.1-pro", "glm-5.3", "kimi-k3", "deepseek-v4-pro", "grok-4.7", "muse-wonder-1.0", "hy4"]) {
		assert.equal(griphubApiFor(id), "openai-completions", id);
	}
});

test("thinking settings come from pi's catalog of the same vendor model, when it has one", () => {
	assert.deepEqual(vendorThinking("claude-opus-4.5", "anthropic-messages"), {}, "older Anthropic model: budget thinking, pi's default");
	assert.equal(vendorThinking("claude-opus-5", "anthropic-messages").compat.forceAdaptiveThinking, true);
	assert.deepEqual(vendorThinking("claude-someday-9", "anthropic-messages"), {}, "unknown model: defaults");
	assert.deepEqual(vendorThinking("glm-5.3", "openai-completions"), {});
});

test("models.json routes each GripHub model through the router, never straight to OpenAI or Anthropic", (t) => {
	const d = tempDir(t);
	const modelsFile = join(d, "models.json");
	const p = new CustomProviders(join(d, "store.json"), modelsFile);
	p.save(
		{
			apiKey: "sk-router",
			models: [
				{ id: "claude-sonnet-5.5", reasoning: true, maxTokens: 64000, contextWindow: 200000 },
				{ id: "gpt-6.1-sol", reasoning: true, canDisableThinking: true },
				{ id: "glm-5.3" },
			],
		},
		new Set(),
	);
	const provider = JSON.parse(readFileSync(modelsFile, "utf8")).providers.griphub;
	assert.equal(provider.api, "openai-completions", "provider default unchanged");
	assert.equal(provider.baseUrl, GRIPHUB_BASE_URL);
	assert.equal(provider.apiKey, "$GRIPHUB_PROVIDER_KEY_GRIPHUB", "the key stays out of the file");
	const byId = Object.fromEntries(provider.models.map((m) => [m.id, m]));

	const anthropic = byId["claude-sonnet-5.5"];
	assert.equal(anthropic.api, "anthropic-messages");
	assert.equal(anthropic.baseUrl, GRIPHUB_ORIGIN, "router origin: the SDK adds /v1/messages");
	assert.match(anthropic.baseUrl, /^https:\/\/griphubrouter\.web\.id$/);
	assert.equal(anthropic.headers.authorization, "Bearer $GRIPHUB_PROVIDER_KEY_GRIPHUB");
	// Thinking as pi asks it of the real Sonnet 5.5: adaptive, no temperature, its own effort ladder.
	assert.deepEqual(anthropic.compat, { forceAdaptiveThinking: true, supportsTemperature: false });
	assert.equal(anthropic.thinkingLevelMap.xhigh, "xhigh");
	assert.equal(anthropic.thinkingLevelMap.max, undefined, "the app stops at xhigh");

	const gpt = byId["gpt-6.1-sol"];
	assert.equal(gpt.api, "openai-responses");
	assert.equal(gpt.baseUrl, undefined, "inherits the router's /v1");
	assert.equal(gpt.thinkingLevelMap.off, null, "GPT-6.1 Sol always thinks (pi's catalog)");
	assert.equal(gpt.thinkingLevelMap.xhigh, "xhigh");
	assert.equal(gpt.compat, undefined, "no vendor-only features through the router");

	const glm = byId["glm-5.3"];
	assert.equal(glm.api, undefined, "chat completions, the provider default");
	assert.equal(glm.compat, undefined);
	assert.equal(glm.baseUrl, undefined);

	for (const m of provider.models) {
		const url = m.baseUrl ?? provider.baseUrl;
		assert.ok(url.startsWith("https://griphubrouter.web.id"), `${m.id} -> ${url}`);
	}
});
