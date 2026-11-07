// Smart router in the real host, on the mock router (Fitur 1 kriteria a-d): a light question in an automatic chat runs
// on the cheapest fitting model with the reason logged; an attached image goes to a vision model; a failed turn makes
// the next one climb a class; a model picked by hand stops the automatic choice for that chat.
import { test } from "node:test";
import assert from "node:assert/strict";
import { host, MODELS, PNG } from "./router-host.mjs";

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

test("a plain chat has tools on offer (web search, remember), so a model that cannot call tools is never picked", async (t) => {
	// The cheapest model of all says it cannot call tools.
	const h = await host(t, {}, { models: [...MODELS, { id: "tiny-chat", name: "Tiny Chat", contextWindow: 128_000, vision: false, tools: false }], rates: { "tiny-chat": 0.1 } });
	await h.call("new_session", { chatMode: "chat" });
	await h.call("smart_router_set", { on: true });
	assert.ok((await h.call("hello")).tools.length > 0, "the plain chat offers tools");
	const sent = await h.turn("Ibu kota Jepang apa?");
	assert.deepEqual(sent.map((r) => r.model), ["glm-5.3-flash"], "the cheapest that can call tools");
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
