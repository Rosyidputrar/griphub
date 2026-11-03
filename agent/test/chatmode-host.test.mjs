// Chat mode in the real host, on the mock router: a chat started as a chat works in the chat folder, offers the model
// a conversation's few tools and its own prompt (no AGENTS.md, no skills, no plan-mode text), keeps that through a
// rebuild, refuses a read outside its folder inside pi's real loop, and is listed as a chat. A coding chat beside it
// keeps everything it had.
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
const out = mkdtempSync(join(here, "..", "build", "chatmode-host-"));
const hostFile = join(out, "host.mjs");
const mockRouter = pathToFileURL(join(here, "fixtures", "mock-router.mjs")).href;

before(async () => {
	// Built like build.mjs builds it (and host-process.test.mjs): pi stays an external import.
	await build({
		entryPoints: [join(here, "..", "src", "host.ts")],
		outfile: hostFile,
		bundle: true,
		platform: "node",
		format: "esm",
		external: ["@earendil-works/pi-coding-agent"],
		packages: "external",
		banner: { js: 'import { createRequire as __createRequire } from "node:module"; const require = __createRequire(import.meta.url);' },
		logLevel: "error",
	});
	cpSync(join(here, "..", "skills"), join(out, "skills"), { recursive: true });
});
after(() => rmSync(out, { recursive: true, force: true }));

/** A phone-mode host on the mock router, in a home of its own, with a GripHub key and the mock model chosen. */
async function host(t, mock = {}) {
	const dir = mkdtempSync(join(tmpdir(), "gh-chat-"));
	const ws = join(dir, "workspace");
	mkdirSync(ws);
	const files = { MOCK_LOG: join(dir, "mock.log"), MOCK_REQUESTS: join(dir, "requests.log"), MOCK_BODIES: join(dir, "bodies.log"), MOCK_RELEASE: join(dir, "release") };
	// Replies end at once.
	writeFileSync(files.MOCK_RELEASE, "");
	const child = spawn(process.execPath, ["--import", mockRouter, hostFile], {
		cwd: ws,
		env: {
			...process.env,
			HOME: dir,
			GRIPHUB_WORKSPACE: ws,
			GRIPHUB_DIR: join(dir, ".griphub"),
			GRIPHUB_STORE_KEY: "ab".repeat(32),
			PI_CODING_AGENT_DIR: join(dir, ".pi", "agent"),
			GRIPHUB_MODE: undefined,
			MOCK_TEXT: "Halo!",
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
			if (Date.now() - t0 > ms) throw new Error(`timed out ${what}; got ${JSON.stringify(records.map((r) => r.type))}; stderr: ${stderr.slice(-800)}`);
			await new Promise((r) => setTimeout(r, 10));
		}
	};
	let id = 0;
	const call = async (type, args = {}) => {
		const n = ++id;
		child.stdin.write(`${JSON.stringify({ id: n, type, ...args })}\n`);
		const r = await until((x) => x.type === "response" && x.id === n, 30_000, `for ${type}`);
		assert.equal(r.ok, true, `${type}: ${r.error}`);
		return r.data;
	};
	await until((r) => r.type === "ready", 60_000, "for ready");
	await call("custom_provider_save", { provider: { apiKey: "sk-test", models: [{ id: "mock-model", name: "Mock" }] } });
	await call("set_model", { provider: "griphub", model: "mock-model" });
	const lines = (file) => (existsSync(file) ? readFileSync(file, "utf8").split("\n").filter(Boolean).map((l) => JSON.parse(l)) : []);
	/** The model requests so far (not the summaries pi may ask for). */
	const requests = () => lines(files.MOCK_REQUESTS).filter((r) => !r.summary);
	/** Sends [text] and waits for the turn to end; returns what the model was asked with. */
	const turn = async (text) => {
		const before = requests().length;
		const done = records.length;
		await call("prompt", { text });
		await until((r) => r.type === "agent_done" && records.indexOf(r) >= done && !r.retrying, 30_000, "for the turn");
		return requests().slice(before);
	};
	return { dir, ws, call, until, records, turn, requests, bodies: () => lines(files.MOCK_BODIES) };
}

const sorted = (a) => [...a].sort();
const CHAT_SET = ["generate_image", "read", "web_fetch", "web_search"];

test("a chat started as a chat: its folder, a conversation's tools and prompt, kept through a rebuild, listed as a chat", async (t) => {
	const h = await host(t);
	// The chat the host starts in is a coding chat, as before.
	const first = await h.call("hello");
	assert.equal(first.chatMode, "coding");
	assert.ok(first.tools.includes("bash") && first.tools.includes("todo_write"));

	// Plan mode is on for the app; a chat has nothing to plan.
	await h.call("plan_mode", { on: true });
	const state = await h.call("new_session", { chatMode: "chat", cwd: join(h.ws, "ignored") });
	assert.equal(state.chatMode, "chat");
	assert.equal(state.cwd, join(h.ws, ".chats"), "the chat folder, whatever folder came with it");
	assert.ok(existsSync(join(h.ws, ".chats")));
	assert.deepEqual(sorted((await h.call("hello")).tools), CHAT_SET);

	const [asked] = await h.turn("Berita apa hari ini?");
	assert.ok(asked, "the model was asked");
	assert.deepEqual(sorted(asked.tools), CHAT_SET, "only these reach the model");
	assert.match(asked.system, /regular chat, not a coding session/);
	assert.match(asked.system, /Today is /);
	assert.doesNotMatch(asked.system, /expert coding assistant/, "not pi's coding prompt");
	assert.doesNotMatch(asked.system, /# Environment|todo_write|mksh/, "not the AGENTS.md notes");
	assert.doesNotMatch(asked.system, /<skills>|available_skills/i, "no skills");
	const said = (body) => (typeof body === "string" ? body : body.map((c) => c.text ?? "").join(""));
	assert.equal(said(h.bodies().at(-1)), "Berita apa hari ini?", "no plan-mode text added to the message");

	// A setting that rebuilds the open chat (as MCP coming up does) keeps it a chat.
	await h.call("container_enable", { on: false });
	const rebuilt = await h.call("hello");
	assert.equal(rebuilt.chatMode, "chat");
	assert.deepEqual(sorted(rebuilt.tools), CHAT_SET);

	// The list says which chats are chats.
	const chatFile = rebuilt.sessionFile;
	const listed = (await h.call("sessions")).find((s) => s.path === chatFile);
	assert.equal(listed?.chatMode, "chat");

	// A coding chat next to it has everything, and its prompt is the coding agent's with the notes; plan mode (still on)
	// applies there.
	const coding = await h.call("new_session", {});
	assert.equal(coding.chatMode, "coding");
	assert.equal(coding.cwd, h.ws);
	const tools = (await h.call("hello")).tools;
	for (const name of ["bash", "edit", "write", "todo_write", "subagent", "background_job", "web_search"]) assert.ok(tools.includes(name), name);
	const [codingAsked] = await h.turn("Halo");
	assert.ok(codingAsked.tools.includes("bash"));
	assert.match(codingAsked.system, /# Environment/, "the AGENTS.md notes");
	assert.match(said(h.bodies().at(-1)), /^Halo\n\n\[Plan mode\]/);
	await h.call("plan_mode", { on: false });
	const all = await h.call("sessions");
	const codingFile = (await h.call("state")).sessionFile;
	assert.equal(all.find((s) => s.path === codingFile)?.chatMode, "coding");

	// Opening the chat again (it has a file now) brings it back as a chat.
	const reopened = await h.call("open_session", { path: chatFile });
	assert.equal(reopened.chatMode, "chat");
	assert.deepEqual(sorted((await h.call("hello")).tools), CHAT_SET);
});

test("in pi's real loop a chat's read stops at its folder, and a coding tool is not there at all", async (t) => {
	const h = await host(t, { MOCK_TOOL: JSON.stringify({ name: "read", arguments: { path: "/etc/hostname" } }) });
	await h.call("new_session", { chatMode: "chat" });
	await h.turn("Baca file ini");
	const reply = await h.until(
		(r) => r.type === "event" && r.event.type === "message_end" && r.event.message.role === "assistant" && /Tool said/.test(JSON.stringify(r.event.message.content)),
		30_000,
		"for the answer to the refused read",
	);
	assert.match(JSON.stringify(reply.event.message.content), /only read the files the user attached/);
});

test("a chat asked for a shell command has none to run", async (t) => {
	const h = await host(t, { MOCK_TOOL: JSON.stringify({ name: "bash", arguments: { command: "echo pwned > /tmp/x" } }) });
	await h.call("new_session", { chatMode: "chat" });
	await h.turn("Jalankan perintah");
	const result = await h.until((r) => r.type === "event" && r.event.type === "tool_execution_end" && r.event.toolName === "bash", 30_000, "for the bash call to end");
	assert.equal(result.event.isError, true, "pi has no such tool here");
	assert.ok(!(await h.call("hello")).tools.includes("bash"));
});
