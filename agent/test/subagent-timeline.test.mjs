// What the subagent's detail view shows, kept in its record (subagent.ts): the thinking, the text between tool calls,
// where each call came, and what the person sent it, in order; the whole command or file being written; the pictures a
// tool returned. Before, only a one-line summary of each call and its output were kept, and thinking, text and sent
// messages were dropped.
import { test } from "node:test";
import assert from "node:assert/strict";
import { bundle } from "./helpers.mjs";

const { SubagentManager, capInput, keepImages, appendMessage, pushTimeline, TIMELINE_CAP, INPUT_STRING_CAP, IMAGE_MAX, IMAGES_TOTAL } =
	await bundle("subagent");

const tick = () => new Promise((r) => setTimeout(r, 0));
const parent = { sessionFile: "chat.jsonl", title: "t", cwd: "/tmp", modelId: "claude-opus-5.5" };

/** A session that, per prompt, emits the given events (message_end and tool events), then settles. */
function session(script) {
	let listener;
	let n = 0;
	const s = {
		model: { provider: "griphub", id: "claude-opus-5.5", name: "Claude Opus 5.5" },
		thinkingLevel: "high",
		isStreaming: false,
		subscribe(fn) {
			listener = fn;
			return () => {};
		},
		async prompt() {
			const events = script[n++] ?? [];
			s.isStreaming = true;
			listener({ type: "agent_start" });
			for (const e of events) {
				await tick();
				listener(e);
			}
			await tick();
			listener({ type: "agent_end" });
			s.isStreaming = false;
			listener({ type: "agent_settled", aborted: false });
		},
		getSessionStats: () => ({ tokens: { input: 1, output: 1, cacheRead: 0, cacheWrite: 0 } }),
		getLastAssistantText: () => "done",
		abort() {},
		dispose() {},
	};
	return s;
}

function manager(s) {
	const sent = [];
	const m = new SubagentManager({
		send: (r) => sent.push(r),
		wireEvent: (e) => e,
		createSession: async () => s,
		limits: () => ({ creditLimit: 0, minutesLimit: 0, approvalMode: "auto" }),
	});
	return { m, sent };
}

const assistant = (content) => ({ type: "message_end", message: { role: "assistant", model: "claude-opus-5.5", usage: { input: 1, output: 1 }, content } });
const longCommand = `npm run build -- ${"--flag ".repeat(60)}`;

test("the timeline keeps thinking, text, tool calls (in the message's order) and the whole command", async () => {
	const s = session([
		[
			assistant([
				{ type: "thinking", thinking: "First I look at the build script." },
				{ type: "text", text: "Running the build." },
				{ type: "toolCall", id: "t1", name: "bash", arguments: { command: longCommand } },
			]),
			{ type: "tool_execution_start", toolCallId: "t1", toolName: "bash", args: { command: longCommand } },
			{ type: "tool_execution_end", toolCallId: "t1", toolName: "bash", isError: false, result: { content: [{ type: "text", text: "ok" }] } },
			assistant([{ type: "text", text: "The build passed." }]),
		],
	]);
	const { m } = manager(s);
	const rec = m.start(parent, "Build it", "read");
	await m.waitFor(rec.id);
	assert.deepEqual(
		rec.timeline.map((t) => (t.kind === "tool" ? `tool:${t.id}` : `${t.kind}:${t.text}`)),
		["thinking:First I look at the build script.", "text:Running the build.", "tool:t1", "text:The build passed."],
	);
	const call = rec.toolCalls[0];
	assert.equal(call.input.command, longCommand, "the whole command, not the 200-character summary");
	assert.ok(call.args.length <= 200, "the one-line summary is still there for the card");
});

test("a message the person queued stays in the timeline once it has been sent, and is announced", async () => {
	const s = session([[assistant([{ type: "text", text: "first" }])], [assistant([{ type: "text", text: "second" }])]]);
	const { m, sent } = manager(s);
	const rec = m.start(parent, "Do it", "read");
	m.queueMessage(rec.id, "Also check the tests");
	await m.waitFor(rec.id);
	assert.deepEqual(
		rec.timeline.map((t) => `${t.kind}:${t.text ?? t.id}`),
		["text:first", "user:Also check the tests", "text:second"],
	);
	assert.ok(sent.some((r) => r.type === "subagent_event" && r.event.type === "subagent_user_message" && r.event.text === "Also check the tests"));
	assert.deepEqual(rec.queue, []);
});

test("pictures a tool returns are kept (a few, small ones), text output beside them", async () => {
	const png = "iVBORw0KGgo".repeat(10);
	const s = session([
		[
			assistant([{ type: "toolCall", id: "r1", name: "read", arguments: { path: "shot.png" } }]),
			{ type: "tool_execution_start", toolCallId: "r1", toolName: "read", args: { path: "shot.png" } },
			{
				type: "tool_execution_end",
				toolCallId: "r1",
				toolName: "read",
				isError: false,
				result: { content: [{ type: "text", text: "Read image file [image/png]" }, { type: "image", data: png, mimeType: "image/png" }] },
			},
		],
	]);
	const { m } = manager(s);
	const rec = m.start(parent, "Look", "read");
	await m.waitFor(rec.id);
	assert.deepEqual(rec.toolCalls[0].images, [{ mimeType: "image/png", data: png }]);
	assert.equal(rec.toolCalls[0].output, "Read image file [image/png]");
});

test("caps: long strings in the arguments, too-large or too-many pictures, a timeline that grows forever", () => {
	const capped = capInput({ path: "a.txt", content: "x".repeat(INPUT_STRING_CAP + 10), edits: [{ oldText: "y".repeat(INPUT_STRING_CAP + 5), newText: "z" }] });
	assert.equal(capped.path, "a.txt");
	assert.ok(capped.content.length < INPUT_STRING_CAP + 20 && capped.content.endsWith("(truncated)"));
	assert.ok(capped.edits[0].oldText.endsWith("(truncated)"));
	assert.equal(capInput("not an object"), undefined);

	const rec = { toolCalls: [], timeline: [] };
	assert.deepEqual(keepImages(rec, [{ type: "image", data: "x".repeat(IMAGE_MAX + 1), mimeType: "image/png" }]), [], "one too large is left out");
	const three = Array.from({ length: 3 }, () => ({ type: "image", data: "a", mimeType: "image/png" }));
	assert.equal(keepImages(rec, three).length, 2, "a few per call");
	// Together under the total: the oldest give way.
	const big = "b".repeat(IMAGE_MAX);
	for (let i = 0; i < 5; i++) rec.toolCalls.push({ id: `c${i}`, images: [{ mimeType: "image/png", data: big }] });
	const kept = keepImages(rec, [{ type: "image", data: big, mimeType: "image/png" }]);
	assert.equal(kept.length, 1);
	const total = rec.toolCalls.reduce((n, c) => n + (c.images ?? []).reduce((m, i) => m + i.data.length, 0), 0) + kept[0].data.length;
	assert.ok(total <= IMAGES_TOTAL, `${total} characters of pictures in all`);
	assert.equal(rec.toolCalls[0].images, undefined, "the oldest went first");

	for (let i = 0; i < TIMELINE_CAP + 50; i++) pushTimeline(rec, { kind: "text", text: `${i}`, at: i });
	assert.equal(rec.timeline.length, TIMELINE_CAP);
	assert.equal(rec.timeline.at(-1).text, `${TIMELINE_CAP + 49}`, "the newest are kept");

	const r2 = { timeline: [] };
	appendMessage(r2, { content: [{ type: "thinking", thinking: "   " }, { type: "text", text: "" }, { type: "text", text: "said" }] });
	assert.deepEqual(r2.timeline.map((t) => t.text), ["said"], "empty blocks leave nothing");
});
