// Smart router in the real host, on the mock router (Fitur 1 kriteria a-d): a light question in an automatic chat runs
// on the cheapest fitting model with the reason logged; an attached image goes to a vision model; a failed turn makes
// the next one climb a class; a model picked by hand stops the automatic choice for that chat.
import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { cpSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { build } from "esbuild";

const here = dirname(fileURLToPath(import.meta.url));
mkdirSync(join(here, "..", "build"), { recursive: true });
const out = mkdtempSync(join(here, "..", "build", "smartrouter-host-"));
const hostFile = join(out, "host.mjs");
const mockRouter = pathToFileURL(join(here, "fixtures", "mock-router.mjs")).href;
const PNG = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=";

before(async () => {
	await build({
		entryPoints: [join(here, "..", "src", "host.ts")],
		outfile: hostFile,
		bundle: true,
		platform: "node",
		format: "esm",
		packages: "external",
		banner: { js: 'import { createRequire as __createRequire } from "node:module"; const require = __createRequire(import.meta.url);' },
		logLevel: "error",
	});
	cpSync(join(here, "..", "skills"), join(out, "skills"), { recursive: true });
});
after(() => rmSync(out, { recursive: true, force: true }));

/** Models as /v1/models describes them (only Chat Completions families: the mock router serves that endpoint). */
const MODELS = [
	{ id: "glm-5.3-flash", name: "GLM 5.3 Flash", contextWindow: 128_000, vision: false, tools: true },
	{ id: "deepseek-v4-pro", name: "DeepSeek V4 Pro", contextWindow: 128_000, vision: false, tools: true },
	{ id: "gemini-3.8-flash", name: "Gemini 3.8 Flash", contextWindow: 1_000_000, vision: true, input: ["text", "image"], tools: true },
	{ id: "kimi-k3", name: "Kimi K3", contextWindow: 256_000, vision: false, tools: true },
	{ id: "gemini-3.1-pro", name: "Gemini 3.1 Pro", contextWindow: 1_000_000, vision: true, input: ["text", "image"], tools: true, reasoning: true },
	{ id: "kimi-k3.1-pro", name: "Kimi K3.1 Pro", contextWindow: 256_000, vision: false, tools: true, reasoning: true },
];
/** The router's live rates (credits / 1M), as /api/user-usage serves them. */
const RATES = { "glm-5.3-flash": 0.5, "deepseek-v4-pro": 1, "gemini-3.8-flash": 1.5, "kimi-k3": 1.5, "gemini-3.1-pro": 2, "kimi-k3.1-pro": 2 };

async function host(t, mock = {}) {
	const dir = mkdtempSync(join(tmpdir(), "gh-sr-"));
	const ws = join(dir, "workspace");
	const agentDir = join(dir, ".pi", "agent");
	mkdirSync(ws);
	mkdirSync(join(agentDir, "griphub"), { recursive: true });
	// No automatic retries by pi: a failed request ends the turn, as the escalation test needs.
	writeFileSync(join(agentDir, "settings.json"), JSON.stringify({ retry: { enabled: false } }));
	// Live rates the router served earlier (router.ts cache).
	const rates = Object.fromEntries(Object.entries(RATES).map(([k, credits]) => [k, { credits }]));
	writeFileSync(join(agentDir, "griphub", "router-cache.json"), JSON.stringify({ version: 1, rates, ratesAt: Date.now(), floors: {}, requests: [], daily: {} }));
	const files = { MOCK_LOG: join(dir, "mock.log"), MOCK_REQUESTS: join(dir, "requests.log"), MOCK_RELEASE: join(dir, "release") };
	writeFileSync(files.MOCK_RELEASE, "");
	const child = spawn(process.execPath, ["--import", mockRouter, hostFile], {
		cwd: ws,
		env: {
			...process.env,
			HOME: dir,
			GRIPHUB_WORKSPACE: ws,
			GRIPHUB_DIR: join(dir, ".griphub"),
			GRIPHUB_STORE_KEY: "ab".repeat(32),
			PI_CODING_AGENT_DIR: agentDir,
			GRIPHUB_MODE: undefined,
			MOCK_TEXT: "Tokyo.",
			...files,
			...mock,
		},
		stdio: ["pipe", "pipe", "pipe"],
	});
	let stderr = "";
	child.stderr.on("data", (d) => (stderr += d));
	t.after(async () => {
		if (child.exitCode === null && child.signalCode === null) {
			await new Promise((done) => {
				child.once("exit", done);
				child.kill("SIGKILL");
			});
		}
		rmSync(dir, { recursive: true, force: true, maxRetries: 10, retryDelay: 100 });
	});
	const records = [];
	let rest = "";
	child.stdout.setEncoding("utf8");
	child.stdout.on("data", (chunk) => {
		rest += chunk;
		let nl;
		while ((nl = rest.indexOf("\n")) >= 0) {
			const line = rest.slice(0, nl);
			rest = rest.slice(nl + 1);
			if (line.trim()) records.push(JSON.parse(line));
		}
	});
	const until = async (check, ms = 30_000, what = "") => {
		const t0 = Date.now();
		for (;;) {
			const hit = records.find(check);
			if (hit) return hit;
			if (Date.now() - t0 > ms) throw new Error(`timed out ${what}; stderr: ${stderr.slice(-800)}`);
			await new Promise((r) => setTimeout(r, 10));
		}
	};
	let id = 0;
	const raw = async (type, args = {}) => {
		const n = ++id;
		child.stdin.write(`${JSON.stringify({ id: n, type, ...args })}\n`);
		return until((x) => x.type === "response" && x.id === n, 30_000, `for ${type}`);
	};
	const call = async (type, args = {}) => {
		const r = await raw(type, args);
		assert.equal(r.ok, true, `${type}: ${r.error}`);
		return r.data;
	};
	await until((r) => r.type === "ready", 60_000, "for ready");
	await call("custom_provider_save", { provider: { apiKey: "sk-test", models: MODELS } });
	await call("set_model", { provider: "griphub", model: "kimi-k3" });
	const requests = () =>
		existsSync(files.MOCK_REQUESTS) ? readFileSync(files.MOCK_REQUESTS, "utf8").split("\n").filter(Boolean).map((l) => JSON.parse(l)).filter((r) => !r.summary) : [];
	const turn = async (text, extra = {}) => {
		const before = requests().length;
		const done = records.length;
		await call("prompt", { text, ...extra });
		await until((r) => r.type === "agent_done" && records.indexOf(r) >= done && !r.retrying, 30_000, "for the turn");
		return requests().slice(before);
	};
	return { call, raw, turn, records, requests };
}

test("a light question in an automatic plain chat runs on the cheapest fitting model, and the reason is logged", async (t) => {
	const h = await host(t);
	await h.call("new_session", { chatMode: "chat" });
	const on = await h.call("smart_router_set", { on: true });
	assert.equal(on.smartRouter.auto, true);
	const sent = await h.turn("Ibu kota Jepang apa?");
	assert.deepEqual(sent.map((r) => r.model), ["glm-5.3-flash"]);
	const state = await h.call("state");
	assert.equal(state.model.id, "glm-5.3-flash", "the footer names the model really used");
	assert.equal(state.smartRouter.auto, true);
	const log = await h.call("routing_log");
	const route = log.log.find((d) => d.kind === "route");
	assert.equal(route.model, "glm-5.3-flash");
	assert.equal(route.band, 0);
	assert.equal(route.turn, 0);
	assert.match(route.reason, /light/);
	assert.deepEqual(route.why, ["plain-chat", "cheapest"]);
	assert.ok(route.estimate > 0, "an estimate in credits");
	// The decision also went to the app as it happened.
	assert.ok(h.records.some((r) => r.type === "routing" && r.decision.kind === "route"));
});

test("an attached image is routed to a model the metadata calls vision", async (t) => {
	const h = await host(t);
	await h.call("new_session", { chatMode: "chat" });
	await h.call("smart_router_set", { on: true });
	const sent = await h.turn("Apa isi gambar ini?", { images: [{ type: "image", data: PNG, mimeType: "image/png" }] });
	assert.deepEqual(sent.map((r) => r.model), ["gemini-3.8-flash"], "the cheapest vision model, never glm (non-vision)");
	const route = (await h.call("routing_log")).log.find((d) => d.kind === "route");
	assert.match(route.reason, /needs vision/);
	assert.ok(route.why.includes("vision"));
});

test("a failed turn makes the next one climb a class, and the escalation is logged", async (t) => {
	const h = await host(t, { MOCK_FAIL_CHAT: "1" });
	await h.call("new_session", { chatMode: "chat" });
	await h.call("smart_router_set", { on: true });
	const first = await h.turn("halo");
	assert.deepEqual(first.map((r) => r.model), ["glm-5.3-flash"]);
	const second = await h.turn("halo lagi");
	const log = (await h.call("routing_log")).log;
	const escalate = log.find((d) => d.kind === "escalate");
	assert.ok(escalate, JSON.stringify(log));
	assert.deepEqual(escalate.why, ["error"]);
	assert.equal(escalate.band, 1);
	const routes = log.filter((d) => d.kind === "route");
	assert.equal(routes.length, 2);
	assert.ok(routes[1].band >= 1, "one class above the failed turn's");
	assert.notEqual(second[0].model, "glm-5.3-flash");
});

test("a model picked by hand stops the automatic choice for that chat", async (t) => {
	const h = await host(t);
	await h.call("new_session", { chatMode: "chat" });
	await h.call("smart_router_set", { on: true });
	await h.turn("halo");
	const manual = await h.call("set_model", { provider: "griphub", model: "kimi-k3.1-pro" });
	assert.equal(manual.smartRouter.auto, false);
	const sent = await h.turn("Ibu kota Prancis?");
	assert.deepEqual(sent.map((r) => r.model), ["kimi-k3.1-pro"], "the hand-picked model, not the cheapest");
	const log = (await h.call("routing_log")).log;
	assert.equal(log.at(-1).kind, "manual");
	assert.equal(log.filter((d) => d.kind === "route").length, 1, "no routing after the manual pick");
});

test("nothing fits: the turn is not sent, the user is told, and the decision is logged", async (t) => {
	const h = await host(t);
	await h.call("new_session", { chatMode: "chat" });
	await h.call("smart_router_set", { on: true });
	// Every vision model blocked: an image has nowhere to go.
	await h.call("settings_set", { settings: { smartRouterBlocked: ["gemini-3.8-flash", "gemini-3.1-pro"] } });
	const before = h.requests().length;
	const r = await h.raw("prompt", { text: "Lihat ini", images: [{ type: "image", data: PNG, mimeType: "image/png" }] });
	assert.equal(r.ok, false);
	assert.match(r.error, /found no model that can do this message/);
	assert.equal(h.requests().length, before, "nothing was sent on a guess");
	const none = (await h.call("routing_log")).log.at(-1);
	assert.equal(none.kind, "none");
	assert.deepEqual(none.why, ["vision"]);
});

test("the switch in Settings turns the automatic choice off everywhere", async (t) => {
	const h = await host(t);
	await h.call("new_session", { chatMode: "chat" });
	await h.call("smart_router_set", { on: true });
	await h.call("settings_set", { settings: { smartRouter: false } });
	const state = await h.call("state");
	assert.equal(state.smartRouter.enabled, false);
	assert.equal(state.smartRouter.auto, false);
	const sent = await h.turn("halo");
	assert.deepEqual(sent.map((r) => r.model), ["kimi-k3"], "the chat's own model, untouched");
	const r = await h.raw("smart_router_set", { on: true });
	assert.equal(r.ok, false);
});
