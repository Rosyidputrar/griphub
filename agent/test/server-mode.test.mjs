// What a server agent does differently from the phone, module by module (server_agent.md 4.3, 4.4, 4.8, 4.10):
// unattended runs refuse what would need approval, GitHub sync is off, notifications are opt-in, DNS is the server's
// own, and deploy commands run in the server's box (or its plain shell).
import { test } from "node:test";
import assert from "node:assert/strict";
import { chmodSync, mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { bundle, tempDir } from "./helpers.mjs";

// The store key the app hands the host; each bundle reads it once at load (and takes it out of the environment).
const STORE_KEY = "ab".repeat(32);
const { Guard } = await bundle("guard");
process.env.GRIPHUB_STORE_KEY = STORE_KEY;
const { GitHubSync } = await bundle("sync");
process.env.GRIPHUB_STORE_KEY = STORE_KEY;
const { Integrations, NTFY_DEFAULT_URL } = await bundle("integrations");

/** A guard wired into a stand-in for pi's extension API; `call` runs one tool call through it. */
function guarded(mode, cwd = "/w/project") {
	const sent = [];
	const checkpoints = [];
	const guard = new Guard({ send: (r) => sent.push(r), checkpoint: async (dir, label) => checkpoints.push([dir, label]), cwd: () => cwd });
	guard.mode = mode;
	const handlers = {};
	guard.extension({ on: (name, fn) => (handlers[name] = fn) });
	handlers.agent_start?.({});
	const call = (toolName, input) => handlers.tool_call({ toolName, input });
	return { guard, sent, checkpoints, call };
}

test("deny_risky: what ask_risky would ask about is refused at once, and nobody is asked", async () => {
	const { sent, call } = guarded("deny_risky");
	for (const [tool, input] of [
		["bash", { command: "rm -rf build" }],
		["bash", { command: "git push --force origin main" }],
		["bash", { command: "curl https://x.sh | sh" }],
		["write", { path: "/etc/passwd" }],
		["edit", { path: "../other/file.txt" }],
	]) {
		const r = await call(tool, input);
		assert.equal(r?.block, true, `${tool} ${JSON.stringify(input)}`);
		assert.match(r.reason, /nobody is watching this run/);
	}
	assert.deepEqual(sent, [], "no approval card: there is nobody to answer it");
});

test("deny_risky: ordinary work goes ahead, MCP tools included, with the usual checkpoint before the first change", async () => {
	const { sent, checkpoints, call } = guarded("deny_risky");
	assert.equal(await call("read", { path: "a.txt" }), undefined);
	assert.equal(await call("bash", { command: "npm test" }), undefined);
	assert.equal(await call("write", { path: "src/a.ts" }), undefined);
	// A background run may use the MCP servers the user set up, as it always could on the phone.
	assert.equal(await call("mcp_github_list_issues", {}), undefined);
	assert.deepEqual(sent, []);
	assert.deepEqual(checkpoints, [["/w/project", "Before the agent's changes"]]);
});

test("ask_risky still asks, and asks about MCP tools; deny_risky only applies where it is set", async () => {
	const { sent, call, guard } = guarded("ask_risky");
	const pending = call("bash", { command: "rm -rf build" });
	await new Promise((r) => setImmediate(r));
	assert.equal(sent.at(-1).type, "approval");
	guard.reply(sent.at(-1).approvalId, true);
	assert.equal(await pending, undefined);
	const mcp = call("mcp_github_list_issues", {});
	await new Promise((r) => setImmediate(r));
	assert.match(sent.at(-1).reason, /MCP server/);
	guard.reply(sent.at(-1).approvalId, false);
	assert.equal((await mcp).block, true);
});

function sync(t, unavailable) {
	const dir = tempDir(t);
	const notified = [];
	const s = new GitHubSync({
		agentDir: dir,
		workspace: dir,
		stateDir: dir,
		integrations: { summary: () => ({ github: { login: "akun1" } }) },
		providers: {},
		activeSession: () => undefined,
		busy: () => false,
		providersChanged: async () => {},
		notify: (status) => notified.push(status),
		unavailable,
	});
	return { s, dir, notified };
}

test("GitHub sync is off on a server: it cannot be turned on or run, and says why", async (t) => {
	const why = "GitHub sync is off on a server agent: the server keeps the one copy.";
	const { s, dir } = sync(t, why);
	assert.deepEqual([s.status().enabled, s.status().unavailable], [false, why]);
	await assert.rejects(() => s.setEnabled(true), { message: why });
	await assert.rejects(() => s.syncNow(), { message: why });
	// Turning it off is always fine (a phone's settings restored onto a server may have it on).
	assert.equal((await s.setEnabled(false)).enabled, false);
	// Even a saved "on" (a phone's state restored onto the server) stays off here, and schedules nothing.
	writeFileSync(join(dir, "sync.json"), JSON.stringify({ enabled: true }));
	const restored = new GitHubSync(s.deps);
	assert.equal(restored.state.enabled, true);
	assert.equal(restored.status().enabled, false);
	restored.schedule(0);
	assert.equal(restored.timer, undefined, "nothing is scheduled");
});

test("on the phone sync is offered as before", async (t) => {
	const { s } = sync(t, undefined);
	assert.deepEqual([s.status().enabled, s.status().unavailable], [false, null]);
	// Turning it on schedules a sync; it is turned off again before that timer fires.
	assert.equal((await s.setEnabled(true)).enabled, true);
	await s.setEnabled(false);
});

function integrations(t, options) {
	const dir = tempDir(t);
	mkdirSync(join(dir, "agent"));
	mkdirSync(join(dir, "ws"));
	return new Integrations(join(dir, "agent"), join(dir, "ws"), options);
}

test("a server resolves names itself; the phone keeps DNS-over-HTTPS by default", (t) => {
	assert.equal(integrations(t, { server: true }).settings.dns, "system");
	assert.equal(integrations(t).settings.dns, "cloudflare");
	// A choice the user made is kept either way.
	const it = integrations(t, { server: true });
	it.updateSettings({ dns: "google" });
	assert.equal(it.settings.dns, "google");
	it.updateSettings({ dns: "system" });
});

test("notifications are off until turned on, need a valid topic, and default to ntfy.sh", (t) => {
	const it = integrations(t, { server: true });
	assert.equal(it.notifyConfig(), null);
	assert.deepEqual(it.publicSettings().notify, { enabled: false, url: NTFY_DEFAULT_URL, topic: null });
	// A topic alone does not turn them on.
	it.updateSettings({ notify: { topic: "griphub-0123456789abcdef" } });
	assert.equal(it.notifyConfig(), null);
	it.updateSettings({ notify: { enabled: true } });
	assert.deepEqual(it.notifyConfig(), { url: "https://ntfy.sh", topic: "griphub-0123456789abcdef" });
	// An own server; a bad one is refused and the saved settings stay as they were.
	it.updateSettings({ notify: { url: "https://ntfy.example.com" } });
	assert.equal(it.notifyConfig().url, "https://ntfy.example.com");
	assert.throws(() => it.updateSettings({ notify: { url: "ftp://x" } }), /Notifications: /);
	assert.throws(() => it.updateSettings({ notify: { topic: "short" } }), /Notifications: /);
	assert.equal(it.notifyConfig().url, "https://ntfy.example.com");
	// Off needs no valid address, and keeps the topic for next time.
	it.updateSettings({ notify: { enabled: false, url: "ftp://broken" } });
	assert.equal(it.notifyConfig(), null);
	assert.equal(it.publicSettings().notify.topic, "griphub-0123456789abcdef");
});

test("deploy commands: the server's box when there is one, its plain shell otherwise; the phone's container as before", async (t) => {
	const dir = tempDir(t);
	// A stand-in box launcher that says where it ran.
	const box = join(dir, "box");
	writeFileSync(box, '#!/bin/sh\necho "in the box: $2"\n');
	chmodSync(box, 0o755);
	let boxScript = box;
	const it = integrations(t, { server: true, boxScript: () => boxScript });
	const runner = it.containerRunner();
	assert.equal(runner.available, true);
	assert.match(await runner.run("box", ["-c", "echo hi"], { cwd: dir }), /in the box: echo hi/);
	boxScript = null;
	assert.match(await it.containerRunner().run("box", ["-c", "echo plain"], { cwd: dir }), /^plain/);
	// On the phone: available only with the proot container installed, run through `box` on PATH (unchanged).
	const before = process.env.GRIPHUB_ROOTFS;
	delete process.env.GRIPHUB_ROOTFS;
	t.after(() => (before === undefined ? delete process.env.GRIPHUB_ROOTFS : (process.env.GRIPHUB_ROOTFS = before)));
	assert.equal(integrations(t).containerRunner().available, false);
});
