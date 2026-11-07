// A phone-mode host on the mock router with GripHub models that say what they can do (vision, tools) and the
// router's live rates, for the smart router and vision translator tests. Built once per test file.
import { before, after } from "node:test";
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
export const PNG = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=";

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
export const MODELS = [
	{ id: "glm-5.3-flash", name: "GLM 5.3 Flash", contextWindow: 128_000, vision: false, tools: true },
	{ id: "deepseek-v4-pro", name: "DeepSeek V4 Pro", contextWindow: 128_000, vision: false, tools: true },
	{ id: "gemini-3.8-flash", name: "Gemini 3.8 Flash", contextWindow: 1_000_000, vision: true, input: ["text", "image"], tools: true },
	{ id: "kimi-k3", name: "Kimi K3", contextWindow: 256_000, vision: false, tools: true },
	{ id: "gemini-3.1-pro", name: "Gemini 3.1 Pro", contextWindow: 1_000_000, vision: true, input: ["text", "image"], tools: true, reasoning: true },
	{ id: "kimi-k3.1-pro", name: "Kimi K3.1 Pro", contextWindow: 256_000, vision: false, tools: true, reasoning: true },
];
/** The router's live rates (credits / 1M), as /api/user-usage serves them. */
export const RATES = { "glm-5.3-flash": 0.5, "deepseek-v4-pro": 1, "gemini-3.8-flash": 1.5, "kimi-k3": 1.5, "gemini-3.1-pro": 2, "kimi-k3.1-pro": 2 };

export async function host(t, mock = {}, opts = {}) {
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
	const files = { MOCK_LOG: join(dir, "mock.log"), MOCK_REQUESTS: join(dir, "requests.log"), MOCK_BODIES: join(dir, "bodies.log"), MOCK_RELEASE: join(dir, "release") };
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
		existsSync(files.MOCK_REQUESTS) ? readFileSync(files.MOCK_REQUESTS, "utf8").split("\n").filter(Boolean).map((l) => JSON.parse(l)).filter((r) => !r.summary && !r.vision) : [];
	const turn = async (text, extra = {}) => {
		const before = requests().length;
		const done = records.length;
		await call("prompt", { text, ...extra });
		await until((r) => r.type === "agent_done" && records.indexOf(r) >= done && !r.retrying, 30_000, "for the turn");
		return requests().slice(before);
	};
	/** What the mock router was asked to do, one word per request (chat, summary, vision, ...). */
	const log = () => (existsSync(files.MOCK_LOG) ? readFileSync(files.MOCK_LOG, "utf8").split("\n").filter(Boolean) : []);
	/** The last message of each request, as the router got it. */
	const bodies = () => (existsSync(files.MOCK_BODIES) ? readFileSync(files.MOCK_BODIES, "utf8").split("\n").filter(Boolean).map((l) => JSON.stringify(JSON.parse(l))) : []);
	return { call, raw, turn, records, requests, log, bodies, dir, agentDir };
}

