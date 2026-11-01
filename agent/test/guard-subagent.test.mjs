// A subagent works on its own and spends credits and time (up to 50 credits and 30 minutes each, three at once, about
// Rp 45,000), but nothing in its call looks risky, so in the default mode it started without a word (UX-08). The first
// one of a chat is now asked about; the person's yes covers the rest of that chat.
import { test } from "node:test";
import assert from "node:assert/strict";
import { bundle } from "./helpers.mjs";

const { Guard, SUBAGENT_RISK } = await bundle("guard");

/** A guard whose current chat is [chat.name]; each call is answered by [answers] in turn (true: allow). */
function rig(mode, chat = { name: "chat-1.jsonl" }) {
	const sent = [];
	const guard = new Guard({ send: (r) => sent.push(r), checkpoint: async () => {}, cwd: () => "/work", chat: () => chat.name });
	guard.mode = mode;
	const handlers = {};
	guard.extension({ on: (name, fn) => (handlers[name] = fn) });
	handlers.agent_start?.({});
	/** Starts a subagent; [allow] answers the card if one is shown. Returns what the guard did. */
	const start = async (input, { allow = true, always = false } = {}) => {
		const before = sent.length;
		const call = handlers.tool_call({ toolName: "subagent", input });
		await new Promise((r) => setImmediate(r));
		const asked = sent.length > before ? sent.at(-1) : null;
		if (asked) guard.reply(asked.approvalId, allow, always, asked.key);
		return { result: await call, asked };
	};
	return { guard, sent, start };
}

const task = { task: "Compare the three frameworks and write a table of pros and cons." };

test("by default the first subagent of a chat asks, with the task on the card", async () => {
	const { start } = rig("ask_risky");
	const { result, asked } = await start(task);
	assert.ok(asked, "a card was shown");
	assert.equal(asked.toolName, "subagent");
	assert.equal(asked.reason, SUBAGENT_RISK);
	assert.equal(asked.summary, `read: ${task.task}`, "the task, not the JSON around it");
	assert.equal(result, undefined, "allowed, so it goes ahead");
});

test("the profile is on the card, so a subagent that may edit and run commands says so", async () => {
	const { start } = rig("ask_risky");
	const { asked } = await start({ ...task, profile: "full" });
	assert.match(asked.summary, /^full: /);
});

test("declining stops it, and the next one asks again", async () => {
	const { start } = rig("ask_risky");
	const no = await start(task, { allow: false });
	assert.equal(no.result.block, true);
	const again = await start(task);
	assert.ok(again.asked, "nothing was agreed to yet");
});

test("one yes covers the rest of that chat, and only that chat", async () => {
	const chat = { name: "chat-1.jsonl" };
	const { start } = rig("ask_risky", chat);
	assert.ok((await start(task)).asked);
	for (let i = 0; i < 3; i++) {
		const next = await start({ task: `another job ${i}` });
		assert.equal(next.asked, null, "no second question in the same chat");
		assert.equal(next.result, undefined);
	}
	chat.name = "chat-2.jsonl";
	assert.ok((await start(task)).asked, "another chat has not agreed");
});

test("Always means subagents in general, whatever the task says", async () => {
	const chat = { name: "chat-1.jsonl" };
	const { start } = rig("ask_all", chat);
	const first = await start(task, { always: true });
	assert.ok(first.asked);
	chat.name = "chat-2.jsonl";
	const other = await start({ task: "something else entirely" });
	assert.equal(other.asked, null, "allowed for the app run, in a chat that was never asked");
});

test("in Ask all every subagent asks, as every change does", async () => {
	const { start } = rig("ask_all");
	assert.ok((await start(task)).asked);
	assert.ok((await start({ task: "second" })).asked, "still asked: that mode asks about each change");
});

test("with every permission bypassed it is not asked, as before", async () => {
	const { start } = rig("auto");
	const { asked, result } = await start(task);
	assert.equal(asked, null);
	assert.equal(result, undefined);
});

test("other tools are as they were: a plain read in the default mode asks nothing", async () => {
	const { guard, sent } = rig("ask_risky");
	const handlers = {};
	guard.extension({ on: (name, fn) => (handlers[name] = fn) });
	assert.equal(await handlers.tool_call({ toolName: "read", input: { path: "src/a.ts" } }), undefined);
	assert.equal(sent.length, 0);
});
