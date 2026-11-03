// Chat mode (chatmode.ts): a plain conversation beside the coding agent. Which chats are chats, the prompt they get,
// the folder fence on `read`, the per-answer tool-call limit, and the guard leaving plan mode and checkpoints out.
import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdirSync, symlinkSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { bundle, tempDir } from "./helpers.mjs";

const { CHAT_DIR_NAME, CHAT_MAX_TOOL_CALLS, CHAT_TOOLS, chatCallProblem, chatDate, chatDir, chatModeExtension, chatSystemPrompt, isChatCwd, modeOf } =
	await bundle("chatmode");
const { Guard } = await bundle("guard");
const { webTools } = await bundle("web");

/** The handlers an extension registers, as pi would call them. */
function handlersOf(extension) {
	const handlers = {};
	extension({ on: (name, fn) => (handlers[name] = fn) });
	return handlers;
}

test("a chat is a chat by its folder: the workspace's .chats, nothing else", () => {
	const ws = "/data/workspace";
	assert.equal(CHAT_DIR_NAME, ".chats");
	assert.equal(chatDir(ws), "/data/workspace/.chats");
	assert.equal(isChatCwd("/data/workspace/.chats", ws), true);
	assert.equal(isChatCwd("/data/workspace/.chats/", ws), true, "a trailing slash is the same folder");
	assert.equal(isChatCwd("/data/workspace/./.chats", ws), true);
	assert.equal(modeOf("/data/workspace/.chats", ws), "chat");
	// Everything else is a coding chat, as every chat was before.
	for (const cwd of ["/data/workspace", "/data/workspace/shop", "/data/workspace/.chats/sub", "/data/workspace/.chats-old", "/other/.chats", "", undefined, null]) {
		assert.equal(modeOf(cwd, ws), "coding", String(cwd));
	}
});

test("the chat prompt is a conversation's: the date, when to search, sources, attachments, and no coding notes", () => {
	const prompt = chatSystemPrompt({ date: "Tuesday, 3 November 2026", pictures: false });
	assert.match(prompt, /regular chat, not a coding session/);
	assert.match(prompt, /Today is Tuesday, 3 November 2026\./);
	assert.match(prompt, /Use web_search only when/);
	assert.match(prompt, /name your sources/);
	assert.match(prompt, /Attached files:/, "attached files are read, as in a coding chat");
	assert.match(prompt, /start a Coding chat/);
	assert.doesNotMatch(prompt, /generate_image/, "no pictures tool, no word of it");
	for (const word of ["todo_write", "bash", "subagent", "workspace", "deploy", "GITHUB_TOKEN"]) {
		assert.ok(!prompt.includes(word), `nothing about ${word}`);
	}
	assert.match(chatSystemPrompt({ date: "x", pictures: true }), /Use generate_image only when the user asks for a picture\./);
});

test("the date is the user's: in the phone's time zone when the server knows it, and a bad zone falls back", () => {
	// 23:30 UTC on 2 November is already 3 November in Jakarta (UTC+7).
	const at = new Date("2026-11-02T23:30:00Z");
	assert.equal(chatDate(at, "UTC"), "Monday, 2 November 2026");
	assert.equal(chatDate(at, "Etc/GMT-7"), "Tuesday, 3 November 2026");
	assert.equal(chatDate(at, "Not/AZone"), chatDate(at), "the machine's own zone");
	assert.equal(chatDate(at, null), chatDate(at));
});

test("a chat has a conversation's tools only", () => {
	assert.deepEqual(CHAT_TOOLS, ["read", "web_search", "web_fetch"]);
	assert.ok(CHAT_MAX_TOOL_CALLS >= 3 && CHAT_MAX_TOOL_CALLS <= 10, "a few searches and a page, not a coding run");
});

test("read in a chat reaches what was attached and nothing outside the chat folder, links and all", (t) => {
	const ws = tempDir(t);
	const dir = join(ws, ".chats");
	mkdirSync(join(dir, ".attachments"), { recursive: true });
	writeFileSync(join(dir, ".attachments", "1_0_notes.pdf"), "pdf");
	writeFileSync(join(ws, "secret.txt"), "not yours");
	symlinkSync(join(ws, "secret.txt"), join(dir, ".attachments", "link.txt"));
	assert.equal(chatCallProblem("read", { path: join(dir, ".attachments", "1_0_notes.pdf") }, dir), null);
	assert.equal(chatCallProblem("read", { path: ".attachments/1_0_notes.pdf" }, dir), null, "relative to the chat folder");
	assert.equal(chatCallProblem("read", { path: `@${join(dir, ".attachments", "1_0_notes.pdf")}` }, dir), null, "pi drops a leading @");
	for (const path of [join(ws, "secret.txt"), "../secret.txt", ".attachments/../../secret.txt", join(dir, ".attachments", "link.txt"), "/etc/passwd", "~/.ssh/id_ed25519"]) {
		assert.match(chatCallProblem("read", { path }, dir) ?? "", /only read the files the user attached/, path);
	}
	// Other tools are not fenced here (web_* have their own checks; generate_image writes into the chat folder).
	assert.equal(chatCallProblem("web_fetch", { url: "https://example.com" }, dir), null);
	assert.equal(chatCallProblem("generate_image", { prompt: "a cat" }, dir), null);
});

test("an answer in a chat may make a few tool calls; then it is told to answer, and a model that goes on is ended", () => {
	const stops = [];
	const h = handlersOf(chatModeExtension({ dir: "/w/.chats", maxCalls: 2, stopped: (r) => stops.push(r) }));
	const call = () => h.tool_call({ toolName: "web_search", input: { query: "berita" } });
	h.agent_start({});
	assert.equal(call(), undefined);
	assert.equal(call(), undefined);
	const told = call();
	assert.equal(told.block, true);
	assert.match(told.reason, /answer the user now/);
	assert.equal(told.terminate, undefined, "told first, not ended");
	call();
	call();
	const ended = call();
	assert.equal(ended.block, true);
	assert.equal(ended.terminate, true);
	call();
	assert.deepEqual(stops, ["Stopped after 2 tool calls in one answer."], "said once");
	// The next answer starts from nothing.
	h.agent_start({});
	assert.equal(call(), undefined);
});

test("the chat extension refuses a read outside the chat folder", () => {
	const h = handlersOf(chatModeExtension({ dir: "/w/.chats" }));
	h.agent_start({});
	const r = h.tool_call({ toolName: "read", input: { path: "/w/shop/.env" } });
	assert.equal(r.block, true);
	assert.match(r.reason, /only read the files the user attached/);
});

/** A guard over [cwd] whose open chat is a coding chat or not. */
function guardRig({ coding }) {
	const sent = [];
	const checkpoints = [];
	const guard = new Guard({
		send: (r) => sent.push(r),
		checkpoint: async (cwd, label) => void checkpoints.push(label),
		cwd: () => "/w/.chats",
		coding: () => coding,
	});
	guard.mode = "ask_risky";
	const h = handlersOf(guard.extension);
	h.agent_start({});
	return { guard, h, sent, checkpoints };
}

test("plan mode, one switch for the app, is left out of a chat: its pictures are made, nothing is snapshotted", async () => {
	const { guard, h, checkpoints } = guardRig({ coding: false });
	guard.planMode = true;
	assert.equal(await h.tool_call({ toolName: "generate_image", input: { prompt: "kucing" } }), undefined);
	assert.deepEqual(checkpoints, [], "a chat folder is not a project to undo");
});

test("in a coding chat plan mode still blocks changes, and the first change is snapshotted", async () => {
	const { guard, h, checkpoints } = guardRig({ coding: true });
	guard.planMode = true;
	const r = await h.tool_call({ toolName: "generate_image", input: { prompt: "kucing" } });
	assert.equal(r.block, true);
	assert.match(r.reason, /Plan mode is on/);
	guard.planMode = false;
	assert.equal(await h.tool_call({ toolName: "generate_image", input: { prompt: "kucing" } }), undefined);
	assert.deepEqual(checkpoints, ["Before the agent's changes"]);
});

test("a guard without the hook is a coding chat's, as before", async () => {
	const guard = new Guard({ send: () => {}, checkpoint: async () => {}, cwd: () => "/w" });
	guard.planMode = true;
	const h = handlersOf(guard.extension);
	h.agent_start({});
	assert.equal((await h.tool_call({ toolName: "write", input: { path: "/w/a.txt", content: "x" } })).block, true);
});

test("in a chat web_search is described for current information, not docs and error fixes", () => {
	const keys = () => ({});
	const [chatSearch] = webTools(keys, () => "/w/.chats", { chat: true });
	const [codingSearch] = webTools(keys, () => "/w");
	assert.match(chatSearch.description, /news, prices, weather/);
	assert.doesNotMatch(chatSearch.description, /install/);
	assert.deepEqual(chatSearch.promptGuidelines, []);
	assert.match(codingSearch.description, /install instructions/, "a coding chat's is as before");
	assert.equal(codingSearch.promptGuidelines.length, 1);
});
