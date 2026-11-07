// Preloaded into a test host (node --import): answers GripHub Router's chat completions with a scripted stream, so
// the real host can run a model turn offline. The provider lock is untouched: the host still talks to the one
// canonical URL, only fetch underneath it is replaced. Other requests to the router get a 404; everything else
// goes out as usual.
//
// Each reply streams MOCK_TEXT, then holds the stream open until the file MOCK_RELEASE exists (or the request is
// aborted), then ends the turn. Every chat request is counted in MOCK_LOG, one line each, and its last message is
// written to MOCK_BODIES.
//
// With MOCK_TOOL set (JSON: {"name":"bash","arguments":{...}}) the first reply calls that tool instead, and the reply
// after the tool's result repeats the result ("Tool said: ..."), so a test can see what the host did with the call.
// A background job's result coming back to the chat (a message of its own, not a tool result) is answered with
// "Job said: ..." instead of calling the tool again.
import { appendFileSync, existsSync } from "node:fs";

const ROUTER = "https://griphubrouter.web.id/v1";
// A 1x1 PNG, for MOCK_IMAGES.
const PNG = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=";
let imageCount = 0;
let chatCount = 0;
let fixed = false;
const realFetch = globalThis.fetch;

function chunk(delta, finish = null, extra = {}) {
	return `data: ${JSON.stringify({ id: "mock", object: "chat.completion.chunk", created: 0, model: "mock-model", choices: [{ index: 0, delta, finish_reason: finish }], ...extra })}\n\n`;
}

globalThis.fetch = async (input, init) => {
	const url = typeof input === "string" ? input : input instanceof URL ? input.href : input.url;
	if (!url.startsWith(ROUTER)) return realFetch(input, init);
	// MOCK_IMAGES: the router's image models and picture endpoint. Each picture request is logged as "image <model>";
	// MOCK_IMAGE_FAIL=<n> refuses the n-th one (content policy, not billed).
	if (process.env.MOCK_IMAGES && url === `${ROUTER}/models`) {
		const data = [
			{ id: "mock-model", name: "Mock" },
			{ id: "gpt-image", name: "GPT Image", kind: "image" },
			{ id: "gemini-3.1-flash-image", name: "Gemini Flash Image", kind: "image" },
		];
		return new Response(JSON.stringify({ data }), { status: 200, headers: { "content-type": "application/json" } });
	}
	if (process.env.MOCK_IMAGES && url === `${ROUTER}/images/generations`) {
		const req = JSON.parse(init.body);
		if (process.env.MOCK_LOG) appendFileSync(process.env.MOCK_LOG, `image ${req.model} ${req.size}\n`);
		imageCount++;
		if (String(imageCount) === process.env.MOCK_IMAGE_FAIL) {
			return new Response('{"error":{"message":"Prompt refused by content policy"}}', { status: 400, headers: { "content-type": "application/json" } });
		}
		await new Promise((r) => setTimeout(r, 50 * imageCount));
		return new Response(JSON.stringify({ data: [{ b64_json: PNG }] }), { status: 200, headers: { "content-type": "application/json" } });
	}
	if (!url.startsWith(`${ROUTER}/chat/completions`)) return new Response('{"error":"not found"}', { status: 404 });
	if (process.env.MOCK_LOG) appendFileSync(process.env.MOCK_LOG, "chat\n");
	const signal = init?.signal ?? (input instanceof Request ? input.signal : undefined);
	const enc = new TextEncoder();
	const request = JSON.parse(typeof init?.body === "string" ? init.body : await new Response(init?.body ?? (input instanceof Request ? input.body : null)).text());
	const last = request.messages?.at(-1);
	// pi's summary of a long chat (compaction) asks with its own system prompt; MOCK_FAIL_SUMMARY makes the router
	// refuse it, as a router out of credit or a model that is down would. Each one is counted in MOCK_LOG as "summary".
// A summary says what it used (30k in, 1k out), so its cost can be told; chat replies say none, as before.
	const summary = JSON.stringify(request.messages?.[0] ?? "").includes("context summarization assistant");
	if (summary && process.env.MOCK_LOG) appendFileSync(process.env.MOCK_LOG, "summary\n");
	if (summary && process.env.MOCK_FAIL_SUMMARY) {
		return new Response('{"error":{"message":"Summary refused by the mock router"}}', { status: 400, headers: { "content-type": "application/json" } });
	}
	// MOCK_BODIES: what each request asked, one JSON line each (the last message), for tests that check the prompt.
	if (process.env.MOCK_BODIES) appendFileSync(process.env.MOCK_BODIES, `${JSON.stringify(last?.content ?? "")}\n`);
	// MOCK_REQUESTS: each chat request's system prompt and the tools it offered, one JSON line each, for tests that
	// check what a kind of chat gives the model (chat mode: its own prompt and a conversation's few tools).
	if (process.env.MOCK_REQUESTS) {
		const system = request.messages?.find((m) => m.role === "system" || m.role === "developer");
		const text = typeof system?.content === "string" ? system.content : JSON.stringify(system?.content ?? "");
		const tools = (request.tools ?? []).map((t) => t.function?.name ?? t.name);
		// images: picture parts anywhere in the request, so a test can tell a model was never sent one.
		const images = JSON.stringify(request.messages ?? []).split('"type":"image_url"').length - 1;
		const vision = /model lain/i.test(JSON.stringify(last?.content ?? ""));
		appendFileSync(process.env.MOCK_REQUESTS, `${JSON.stringify({ system: text, tools, summary, model: request.model, images, vision })}\n`);
	}
	// A vision translator's reading (visiontranslate.ts: its instruction speaks of "model lain"): MOCK_VISION_TEXT is
	// what it reads, MOCK_VISION_FAIL makes the router refuse it (500), MOCK_VISION_EMPTY makes it read nothing.
	// Counted in MOCK_LOG as "vision", and not as a chat request.
	if (!summary && /model lain/i.test(JSON.stringify(last?.content ?? ""))) {
		if (process.env.MOCK_LOG) appendFileSync(process.env.MOCK_LOG, "vision\n");
		if (process.env.MOCK_VISION_FAIL) {
			return new Response('{"error":{"message":"Vision upstream failed in the mock router"}}', { status: 500, headers: { "content-type": "application/json" } });
		}
		const read = process.env.MOCK_VISION_EMPTY ? "" : (process.env.MOCK_VISION_TEXT ?? "Sebuah gambar.");
		const usage = { usage: { prompt_tokens: 1_800, completion_tokens: 300 } };
		const parts = [...(read ? [chunk({ role: "assistant", content: read })] : [chunk({ role: "assistant", content: "" })]), chunk({}, "stop", usage)];
		return new Response(parts.join("") + "data: [DONE]\n\n", { status: 200, headers: { "content-type": "text/event-stream" } });
	}
	// MOCK_FAIL_CHAT: comma-separated numbers of the chat requests (not summaries) the router answers with a 500, as
	// an upstream outage would; for tests of what the host does after a failed turn.
	if (!summary) chatCount++; // (vision readings returned above, so they are not counted)
	if (!summary && (process.env.MOCK_FAIL_CHAT ?? "").split(",").includes(String(chatCount))) {
		return new Response('{"error":{"message":"Upstream failed in the mock router"}}', { status: 500, headers: { "content-type": "application/json" } });
	}
	// Self-verification's evidence (verify.ts) comes back as a user message: MOCK_FIX (a tool call, as MOCK_TOOL) is made
	// once on the first failed one; otherwise the reply is a closing message that names the status it was given.
	{
		const said = typeof last?.content === "string" ? last.content : JSON.stringify(last?.content ?? "");
		if (last?.role === "user" && said.includes("[Verification evidence")) {
			const status = /Status: (PASSED|FAILED|NOT ACCEPTED)/.exec(said)?.[1] ?? (said.includes("No test could be run") ? "NO TESTS" : said.includes("Not run:") ? "NOT RUN" : "?");
			if (process.env.MOCK_LOG) appendFileSync(process.env.MOCK_LOG, `evidence ${status}\n`);
			if (process.env.MOCK_FIX && status !== "PASSED" && !fixed) {
				fixed = true;
				const { name, arguments: args } = JSON.parse(process.env.MOCK_FIX);
				const call = { index: 0, id: "call_fix", type: "function", function: { name, arguments: JSON.stringify(args) } };
				return new Response([chunk({ role: "assistant", tool_calls: [call] }), chunk({}, "tool_calls")].join("") + "data: [DONE]\n\n", { status: 200, headers: { "content-type": "text/event-stream" } });
			}
			return new Response(chunk({ role: "assistant", content: `Closing: verification ${status}.` }, "stop") + "data: [DONE]\n\n", { status: 200, headers: { "content-type": "text/event-stream" } });
		}
	}
	if (process.env.MOCK_TOOL) {
		const said = typeof last?.content === "string" ? last.content : JSON.stringify(last?.content ?? "");
		const lines =
			last?.role === "tool"
				? [chunk({ role: "assistant", content: `Tool said: ${said}` }, "stop")]
				: said.includes("[Background job")
				? [chunk({ role: "assistant", content: `Job said: ${said}` }, "stop")]
				: (() => {
						const { name, arguments: args } = JSON.parse(process.env.MOCK_TOOL);
						const call = { index: 0, id: "call_1", type: "function", function: { name, arguments: JSON.stringify(args) } };
						return [chunk({ role: "assistant", tool_calls: [call] }), chunk({}, "tool_calls")];
					})();
		return new Response(lines.join("") + "data: [DONE]\n\n", { status: 200, headers: { "content-type": "text/event-stream" } });
	}
	const body = new ReadableStream({
		async start(controller) {
			controller.enqueue(enc.encode(chunk({ role: "assistant", content: process.env.MOCK_TEXT ?? "" })));
			while (!(process.env.MOCK_RELEASE && existsSync(process.env.MOCK_RELEASE))) {
				if (signal?.aborted) {
					controller.error(signal.reason ?? new Error("aborted"));
					return;
				}
				await new Promise((r) => setTimeout(r, 25));
			}
			const usage = summary ? { usage: { prompt_tokens: 30_000, completion_tokens: 1_000 } } : {};
			controller.enqueue(enc.encode(chunk({ content: " Selesai." }, "stop", usage)));
			controller.enqueue(enc.encode("data: [DONE]\n\n"));
			controller.close();
		},
	});
	return new Response(body, { status: 200, headers: { "content-type": "text/event-stream" } });
};
