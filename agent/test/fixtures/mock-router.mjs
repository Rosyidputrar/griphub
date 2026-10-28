// Preloaded into a test host (node --import): answers GripHub Router's chat completions with a scripted stream, so
// the real host can run a model turn offline. The provider lock is untouched: the host still talks to the one
// canonical URL, only fetch underneath it is replaced. Other requests to the router get a 404; everything else
// goes out as usual.
//
// Each reply streams MOCK_TEXT, then holds the stream open until the file MOCK_RELEASE exists (or the request is
// aborted), then ends the turn. Every chat request is counted in MOCK_LOG, one line each.
//
// With MOCK_TOOL set (JSON: {"name":"bash","arguments":{...}}) the first reply calls that tool instead, and the reply
// after the tool's result repeats the result ("Tool said: ..."), so a test can see what the host did with the call.
import { appendFileSync, existsSync } from "node:fs";

const ROUTER = "https://griphubrouter.web.id/v1";
const realFetch = globalThis.fetch;

function chunk(delta, finish = null) {
	return `data: ${JSON.stringify({ id: "mock", object: "chat.completion.chunk", created: 0, model: "mock-model", choices: [{ index: 0, delta, finish_reason: finish }] })}\n\n`;
}

globalThis.fetch = async (input, init) => {
	const url = typeof input === "string" ? input : input instanceof URL ? input.href : input.url;
	if (!url.startsWith(ROUTER)) return realFetch(input, init);
	if (!url.startsWith(`${ROUTER}/chat/completions`)) return new Response('{"error":"not found"}', { status: 404 });
	if (process.env.MOCK_LOG) appendFileSync(process.env.MOCK_LOG, "chat\n");
	const signal = init?.signal ?? (input instanceof Request ? input.signal : undefined);
	const enc = new TextEncoder();
	const request = JSON.parse(typeof init?.body === "string" ? init.body : await new Response(init?.body ?? (input instanceof Request ? input.body : null)).text());
	const last = request.messages?.at(-1);
	if (process.env.MOCK_TOOL) {
		const lines =
			last?.role === "tool"
				? [chunk({ role: "assistant", content: `Tool said: ${typeof last.content === "string" ? last.content : JSON.stringify(last.content)}` }, "stop")]
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
			controller.enqueue(enc.encode(chunk({ content: " Selesai." }, "stop")));
			controller.enqueue(enc.encode("data: [DONE]\n\n"));
			controller.close();
		},
	});
	return new Response(body, { status: 200, headers: { "content-type": "text/event-stream" } });
};
