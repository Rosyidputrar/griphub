// The real host as a process, both ways it runs: the phone's child process on stdin/stdout (unchanged: no hello,
// no seq) and the server daemon on a unix socket (hello_server, resume, kick, survives its clients, restarts and
// shuts down cleanly). server_agent.md, phase 1.
import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import { execFileSync, spawn } from "node:child_process";
import { chmodSync, cpSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
import http from "node:http";
import net from "node:net";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { build } from "esbuild";

const here = dirname(fileURLToPath(import.meta.url));
mkdirSync(join(here, "..", "build"), { recursive: true });
const out = mkdtempSync(join(here, "..", "build", "host-process-"));
const hostFile = join(out, "host.mjs");

before(async () => {
	// Built like build.mjs builds it: pi stays an external import resolved from agent/node_modules.
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

/** A fresh phone-or-server home for one host. Short, because unix socket paths are limited to about 100 bytes. */
function home(t) {
	const dir = mkdtempSync(join(tmpdir(), "gh-"));
	mkdirSync(join(dir, "workspace"));
	t.after(() => rmSync(dir, { recursive: true, force: true, maxRetries: 10, retryDelay: 100 }));
	return dir;
}

function env(dir, extra = {}) {
	return {
		...process.env,
		HOME: dir,
		GRIPHUB_WORKSPACE: join(dir, "workspace"),
		GRIPHUB_DIR: join(dir, ".griphub"),
		GRIPHUB_STORE_KEY: "ab".repeat(32),
		// These tests run inside a GripHub agent too (the product tests itself); its session would otherwise leak in
		// here. The agent dir must stay under this test's HOME (pi reads PI_CODING_AGENT_DIR first), and an outer
		// GRIPHUB_MODE=server would turn a phone-mode host into a server one (server mode is chosen with --listen).
		PI_CODING_AGENT_DIR: join(dir, ".pi", "agent"),
		GRIPHUB_MODE: undefined,
		...extra,
	};
}

/** Parsed JSON lines from a stream, with a way to wait for one. */
function collect(stream) {
	const records = [];
	let rest = "";
	stream.setEncoding("utf8");
	stream.on("data", (chunk) => {
		rest += chunk;
		let nl;
		while ((nl = rest.indexOf("\n")) >= 0) {
			const line = rest.slice(0, nl);
			rest = rest.slice(nl + 1);
			if (line.trim()) records.push(JSON.parse(line));
		}
	});
	const until = async (check, ms = 60_000, what = "") => {
		const t0 = Date.now();
		for (;;) {
			const hit = records.find(check);
			if (hit) return hit;
			if (Date.now() - t0 > ms) throw new Error(`timed out ${what}; got ${JSON.stringify(records.map((r) => r.type))}`);
			await new Promise((r) => setTimeout(r, 10));
		}
	};
	return { records, until };
}

const exited = (child) => new Promise((resolve) => (child.exitCode !== null ? resolve(child.exitCode) : child.once("exit", (code) => resolve(code))));

async function waitFor(check, ms = 60_000) {
	const t0 = Date.now();
	while (!check()) {
		if (Date.now() - t0 > ms) throw new Error("timed out");
		await new Promise((r) => setTimeout(r, 20));
	}
}

// ---------------------------------------------------------------------------
// Phone: stdio, exactly as before

test("phone mode: ready, then commands; no hello_server and no seq; closing stdin ends it", async (t) => {
	const dir = home(t);
	const child = spawn(process.execPath, [hostFile], { cwd: join(dir, "workspace"), env: env(dir), stdio: ["pipe", "pipe", "pipe"] });
	t.after(() => child.kill("SIGKILL"));
	let stderr = "";
	child.stderr.on("data", (d) => (stderr += d));
	const { records, until } = collect(child.stdout);
	await until((r) => r.type === "ready", 60_000, `for ready (stderr: ${stderr.slice(-500)})`);
	const send = (cmd) => child.stdin.write(`${JSON.stringify(cmd)}\n`);
	send({ id: 1, type: "hello" });
	const hello = await until((r) => r.type === "response" && r.id === 1);
	assert.equal(hello.ok, true);
	assert.equal(hello.data.mode, "phone");
	assert.equal(hello.data.transport, "stdio");
	assert.equal(hello.data.protocol, 1);
	send({ id: 2, type: "approvals_pending" });
	assert.deepEqual((await until((r) => r.id === 2)).data, []);
	send({ id: 3, type: "host_restart" });
	const refused = await until((r) => r.id === 3);
	assert.equal(refused.ok, false);
	assert.match(refused.error, /only available when the host runs as a daemon/);
	send({ id: 4, type: "no_such_command" });
	assert.equal((await until((r) => r.id === 4)).ok, false);
	assert.ok(!records.some((r) => r.type === "hello_server"), "no daemon greeting on the phone");
	assert.ok(!records.some((r) => "seq" in r), "no seq numbers on the phone");
	assert.equal(records[0].type === "ready" || records.findIndex((r) => r.type === "ready") >= 0, true);
	// The app closes stdin: the host is done, well within the 1.5 s the app waits before killing it.
	const t0 = Date.now();
	child.stdin.end();
	assert.equal(await exited(child), 0);
	assert.ok(Date.now() - t0 < 1500, `exited in ${Date.now() - t0} ms`);
});

test("a new chat rebuilt for a setting stays in its folder, not wherever the host was started", async (t) => {
	const dir = home(t);
	// Started somewhere else than the workspace, as a server daemon is (systemd: / or home).
	const elsewhere = mkdtempSync(join(tmpdir(), "gh-started-in-"));
	t.after(() => rmSync(elsewhere, { recursive: true, force: true }));
	const child = spawn(process.execPath, [hostFile], { cwd: elsewhere, env: env(dir), stdio: ["pipe", "pipe", "pipe"] });
	t.after(() => child.kill("SIGKILL"));
	const { until } = collect(child.stdout);
	await until((r) => r.type === "ready", 60_000, "for ready");
	let id = 0;
	const call = async (type, args = {}) => {
		const n = ++id;
		child.stdin.write(`${JSON.stringify({ id: n, type, ...args })}\n`);
		return until((r) => r.type === "response" && r.id === n);
	};
	const ws = join(dir, "workspace");
	assert.equal((await call("state")).data.cwd, ws);
	// A shell change rebuilds the chat (so do MCP servers coming up after start); it has no message, so no file yet.
	const r = await call("container_enable", { on: false });
	assert.equal(r.ok, true, r.error);
	assert.equal((await call("state")).data.cwd, ws, "still the workspace");
});

test("opening a chat that has no file yet keeps the folder the app says it was in", async (t) => {
	const dir = home(t);
	const elsewhere = mkdtempSync(join(tmpdir(), "gh-started-in-"));
	t.after(() => rmSync(elsewhere, { recursive: true, force: true }));
	const project = join(dir, "workspace", "shop");
	mkdirSync(project, { recursive: true });
	const child = spawn(process.execPath, [hostFile], { cwd: elsewhere, env: env(dir), stdio: ["pipe", "pipe", "pipe"] });
	t.after(() => child.kill("SIGKILL"));
	const { until } = collect(child.stdout);
	await until((r) => r.type === "ready", 60_000, "for ready");
	let id = 0;
	const call = async (type, args = {}) => {
		const n = ++id;
		child.stdin.write(`${JSON.stringify({ id: n, type, ...args })}\n`);
		return until((r) => r.type === "response" && r.id === n);
	};
	// The app asks for a chat by its file: one that never got a message has none on disk (pi writes it on the first).
	const r = await call("open_session", { path: join(dir, "no-such-chat.jsonl"), cwd: project });
	assert.equal(r.ok, true, r.error);
	assert.equal((await call("state")).data.cwd, project, "not the folder the host was started in");
});

test("GitHub sign-in settings: the saved Client ID reaches the app, and a build without one says so", async (t) => {
	const dir = home(t);
	const child = spawn(process.execPath, [hostFile], { cwd: join(dir, "workspace"), env: env(dir), stdio: ["pipe", "pipe", "pipe"] });
	t.after(() => child.kill("SIGKILL"));
	const { until } = collect(child.stdout);
	await until((r) => r.type === "ready", 60_000, "for ready");
	let id = 0;
	const call = async (type, args = {}) => {
		const n = ++id;
		child.stdin.write(`${JSON.stringify({ id: n, type, ...args })}\n`);
		return until((r) => r.type === "response" && r.id === n);
	};
	const before = (await call("settings_get")).data;
	assert.equal(before.githubClientIdBuiltIn, false, "no build ships one unless built with it");
	assert.equal(before.githubClientId, "");
	const refused = await call("github_device_start");
	assert.equal(refused.ok, false);
	assert.match(refused.error, /needs a GitHub OAuth Client ID/);
	const saved = await call("settings_set", { settings: { githubClientId: " Iv1.abc123 " } });
	assert.equal(saved.data.githubClientId, "Iv1.abc123", "the app sees what it saved");
});

test("phone mode: files_find gives the composer's @ list from the chat's folder, best match first", async (t) => {
	const dir = home(t);
	const ws = join(dir, "workspace");
	mkdirSync(join(ws, "src", "ui"), { recursive: true });
	mkdirSync(join(ws, "node_modules", "app"), { recursive: true });
	for (const f of ["src/ui/app_bar.dart", "src/app.dart", "README.md", "node_modules/app/index.js"]) writeFileSync(join(ws, f), "");
	const child = spawn(process.execPath, [hostFile], { cwd: ws, env: env(dir), stdio: ["pipe", "pipe", "pipe"] });
	t.after(() => child.kill("SIGKILL"));
	const { until } = collect(child.stdout);
	await until((r) => r.type === "ready", 60_000, "for ready");
	child.stdin.write(`${JSON.stringify({ id: 1, type: "files_find", query: "app" })}\n`);
	const r = await until((m) => m.type === "response" && m.id === 1);
	assert.equal(r.ok, true, r.error);
	assert.deepEqual(r.data.files, ["src/app.dart", "src/ui/app_bar.dart"], "dependencies left out");
});

// ---------------------------------------------------------------------------
// Server: daemon on a unix socket

function daemon(t, dir, extra = {}, nodeArgs = []) {
	const sock = join(dir, ".griphub", "host.sock");
	// systemd gives a daemon /dev/null for stdin; its end must not stop the host.
	const child = spawn(process.execPath, [...nodeArgs, hostFile, "--listen", sock], {
		cwd: join(dir, "workspace"),
		env: env(dir, extra),
		stdio: ["ignore", "pipe", "pipe"],
	});
	let stderr = "";
	child.stderr.on("data", (d) => (stderr += d));
	t.after(() => child.kill("SIGKILL"));
	return { child, sock, stderr: () => stderr };
}

async function dial(path) {
	const socket = net.connect(path);
	const c = collect(socket);
	await new Promise((resolve, reject) => {
		socket.once("connect", resolve);
		socket.once("error", reject);
	});
	let next = 100;
	const call = async (type, args = {}) => {
		const id = next++;
		socket.write(`${JSON.stringify({ id, type, ...args })}\n`);
		return c.until((r) => r.type === "response" && r.id === id, 30_000, `for ${type}`);
	};
	let closed = false;
	socket.on("close", () => (closed = true));
	return { socket, ...c, call, get closed() { return closed; } };
}

/** Waits until the daemon accepts connections (a socket file alone may be the stale one a killed daemon left). */
async function started(d) {
	const t0 = Date.now();
	for (;;) {
		assert.equal(d.child.exitCode, null, `the daemon died: ${d.stderr().slice(-800)}`);
		if (d.stderr().includes("listening on") && (await canConnect(d.sock))) return;
		if (Date.now() - t0 > 60_000) throw new Error(`the daemon never listened: ${d.stderr().slice(-800)}`);
		await new Promise((r) => setTimeout(r, 50));
	}
}

function canConnect(path) {
	return new Promise((resolve) => {
		const probe = net.connect(path);
		probe.once("connect", () => {
			probe.destroy();
			resolve(true);
		});
		probe.once("error", () => resolve(false));
	});
}

test("server mode: a private socket, hello_server, resume, kick, and the daemon outlives its clients", async (t) => {
	const dir = home(t);
	const d = daemon(t, dir);
	await started(d);
	assert.equal(statSync(d.sock).mode & 0o777, 0o600);
	assert.equal(statSync(dirname(d.sock)).mode & 0o777, 0o700);
	assert.ok(existsSync(join(dir, ".griphub", "running")));

	const one = await dial(d.sock);
	const hello = await one.until((r) => r.type === "hello_server");
	assert.equal(hello.mode, "server");
	assert.equal(hello.protocol, 1);
	await one.until((r) => r.type === "ready");
	const r1 = await one.call("resume", { since: null });
	assert.equal(r1.data.gap, false);
	const info = await one.call("hello");
	assert.equal(info.data.mode, "server");
	assert.equal(info.data.transport, "daemon");
	assert.deepEqual((await one.call("approvals_pending")).data, []);

	// A second device takes over; the first is told so and closed.
	const two = await dial(d.sock);
	await two.until((r) => r.type === "hello_server");
	await one.until((r) => r.type === "kicked");
	await waitFor(() => one.closed);
	await two.call("resume", { since: hello.seq, epoch: hello.epoch });

	// Every client gone: the daemon keeps running, and a client can resume where it was.
	two.socket.destroy();
	await new Promise((r) => setTimeout(r, 300));
	assert.equal(d.child.exitCode, null, "still running with nobody connected");
	const three = await dial(d.sock);
	const h3 = await three.until((r) => r.type === "hello_server");
	assert.equal(h3.epoch, hello.epoch, "the same daemon");
	const r3 = await three.call("resume", { since: h3.seq, epoch: h3.epoch });
	assert.equal(r3.data.gap, false);

	// SIGTERM: a clean exit that removes the socket and the running marker.
	d.child.kill("SIGTERM");
	assert.equal(await exited(d.child), 0);
	assert.ok(!existsSync(d.sock));
	assert.ok(!existsSync(join(dir, ".griphub", "running")));
});

test("server mode: a daemon that was killed says so after it comes back", async (t) => {
	const dir = home(t);
	const first = daemon(t, dir);
	await started(first);
	first.child.kill("SIGKILL");
	await exited(first.child);
	assert.ok(existsSync(join(dir, ".griphub", "running")), "the marker stays behind");

	const second = daemon(t, dir);
	await started(second);
	const c = await dial(second.sock);
	await c.until((r) => r.type === "ready");
	// From the start of this daemon's buffer: the notice was sent before anyone connected.
	await c.call("resume", { since: 0 });
	// Other notices may come first (e.g. "No models available" on a fresh home); look for this one.
	const notice = await c.until((r) => r.type === "notice" && /restarted unexpectedly/.test(r.message), 10_000, "for the restart notice");
	assert.equal(typeof notice.seq, "number");
});

test("server mode: host_restart when idle ends the daemon (systemd starts a fresh one)", async (t) => {
	const dir = home(t);
	const d = daemon(t, dir);
	await started(d);
	const c = await dial(d.sock);
	await c.until((r) => r.type === "ready");
	await c.call("resume", { since: null });
	const r = await c.call("host_restart", { whenIdle: true });
	assert.deepEqual(r.data, { restarting: true });
	assert.equal(await exited(d.child), 0);
	assert.ok(!existsSync(join(dir, ".griphub", "running")), "a planned restart is a clean exit");
});

test("server mode: a second daemon on the same socket is refused", async (t) => {
	const dir = home(t);
	const d = daemon(t, dir);
	await started(d);
	const other = daemon(t, dir);
	const code = await exited(other.child);
	assert.notEqual(code, 0);
	assert.match(other.stderr(), /already listening/);
	assert.equal(d.child.exitCode, null, "the first one is untouched");
});

// ---------------------------------------------------------------------------
// Server: subagents keep a restart waiting, and a shutdown stops them with what they wrote

const mockRouter = pathToFileURL(join(here, "fixtures", "mock-router.mjs")).href;

/** A daemon on the mock router with a GripHub key and model, connected and resumed. */
async function withModel(t, extra = {}) {
	const dir = home(t);
	const mock = { MOCK_LOG: join(dir, "mock.log"), MOCK_RELEASE: join(dir, "release"), MOCK_TEXT: "Separuh laporan: 3 dari 5 berkas diperiksa.", ...extra };
	const d = daemon(t, dir, mock, ["--import", mockRouter]);
	await started(d);
	const c = await dial(d.sock);
	await c.until((r) => r.type === "ready");
	await c.call("resume", { since: null });
	const saved = await c.call("custom_provider_save", { provider: { apiKey: "sk-test", models: [{ id: "mock-model", name: "Mock" }] } });
	assert.equal(saved.ok, true, saved.error);
	const set = await c.call("set_model", { provider: "griphub", model: "mock-model" });
	assert.equal(set.ok, true, set.error);
	const requests = () => (existsSync(mock.MOCK_LOG) ? readFileSync(mock.MOCK_LOG, "utf8").split("\n").filter(Boolean).length : 0);
	return { dir, d, c, mock, requests };
}

async function startSubagent({ c, requests }) {
	const started = await c.call("subagent_start", { task: "Periksa lima berkas", profile: "read" });
	assert.equal(started.ok, true, started.error);
	// Working: its model request is open and has streamed the first part of the report.
	await waitFor(() => requests() >= 1);
	await c.until((r) => r.type === "subagent_status" && r.subagentId === started.data.id && r.status === "running");
	return started.data.id;
}

test("server mode: host_restart when idle waits for a working subagent, then restarts once it is done", async (t) => {
	const m = await withModel(t);
	const id = await startSubagent(m);
	const r = await m.c.call("host_restart", { whenIdle: true });
	assert.deepEqual(r.data, { restarting: false, pending: true });
	// Longer than the gate's 2 s poll: still running, the subagent untouched.
	await new Promise((res) => setTimeout(res, 2500));
	assert.equal(m.d.child.exitCode, null, "the restart waits for the subagent");
	assert.ok(!m.c.records.some((x) => x.type === "subagent_finished"));
	// The subagent finishes its turn; the daemon then goes on its own, cleanly.
	writeFileSync(m.mock.MOCK_RELEASE, "");
	const done = await m.c.until((x) => x.type === "subagent_finished" && x.subagent.id === id);
	assert.equal(done.subagent.status, "done");
	assert.equal(await exited(m.d.child), 0);
	assert.ok(!existsSync(join(m.dir, ".griphub", "running")));
});

test("server mode: health says which bundle the process runs and whether a copied update is waiting to restart it", async (t) => {
	writeFileSync(join(out, ".stamp"), "bundle-A\n");
	t.after(() => rmSync(join(out, ".stamp"), { force: true }));
	const m = await withModel(t);
	const id = await startSubagent(m);
	let h = (await m.c.call("health")).data;
	assert.equal(h.bundleStamp, "bundle-A");
	assert.equal(h.restartPending, false);
	// The app's update replaces the files while the process goes on running the old ones.
	writeFileSync(join(out, ".stamp"), "bundle-B\n");
	assert.deepEqual((await m.c.call("host_restart", { whenIdle: true })).data, { restarting: false, pending: true });
	h = (await m.c.call("health")).data;
	assert.equal(h.restartPending, true, "the app can say the update is waiting for the work to end");
	assert.equal(h.bundleStamp, "bundle-A", "what runs is still the old bundle, whatever the file on disk says");
	writeFileSync(m.mock.MOCK_RELEASE, "");
	await m.c.until((x) => x.type === "subagent_finished" && x.subagent.id === id);
	assert.equal(await exited(m.d.child), 0);
});

test("server mode: at start the host puts the launcher files of its bundle where the setup script put them", async (t) => {
	const dir = home(t);
	const gh = join(dir, ".griphub");
	for (const [name, target, mode] of [["box", "bin/box", 0o755], ["griphub-attach", "bin/griphub-attach", 0o755], ["Containerfile", "box/Containerfile", 0o644]]) {
		mkdirSync(join(out, "launcher"), { recursive: true });
		writeFileSync(join(out, "launcher", name), `#!/bin/sh\n# new ${name}\n`);
		mkdirSync(join(gh, target.split("/")[0]), { recursive: true });
		writeFileSync(join(gh, target), `#!/bin/sh\n# old ${name}\n`);
		chmodSync(join(gh, target), mode);
	}
	t.after(() => rmSync(join(out, "launcher"), { recursive: true, force: true }));
	const d = daemon(t, dir);
	await started(d);
	for (const [name, target] of [["box", "bin/box"], ["griphub-attach", "bin/griphub-attach"], ["Containerfile", "box/Containerfile"]]) {
		assert.equal(readFileSync(join(gh, target), "utf8"), `#!/bin/sh\n# new ${name}\n`, target);
	}
	assert.equal(statSync(join(gh, "bin", "box")).mode & 0o777, 0o755, "still executable");
	assert.match(d.stderr(), /launcher updated: .*bin\/box/);
});

test("server mode: SIGTERM stops a working subagent with its partial report before the daemon exits", async (t) => {
	const m = await withModel(t);
	const id = await startSubagent(m);
	m.d.child.kill("SIGTERM");
	const done = await m.c.until((x) => x.type === "subagent_finished" && x.subagent.id === id, 10_000, "for the stopped subagent");
	assert.equal(done.subagent.status, "stopped");
	assert.equal(done.subagent.stopCode, "force");
	assert.match(done.subagent.report ?? "", /Separuh laporan/, "the partial report survives");
	assert.equal(await exited(m.d.child), 0);
});

// ---------------------------------------------------------------------------
// Server mode, phase 2: what the server does differently (server_agent.md 4.3–4.8)

const PHONE_FIXTURE_WS = "/data/user/0/id.griphub.agent/files/workspace";

/** Starts a daemon, connects, and resumes; `hello` says where the agent's folder is. */
async function connected(t, dir, extra = {}, nodeArgs = []) {
	const d = daemon(t, dir, extra, nodeArgs);
	await started(d);
	const c = await dial(d.sock);
	await c.until((r) => r.type === "ready");
	await c.call("resume", { since: null });
	const hello = (await c.call("hello")).data;
	return { d, c, agentDir: hello.agentDir };
}

test("server mode: the server's notes, files over fs_*, a preview, health, and no GitHub sync", async (t) => {
	const dir = home(t);
	const { c, agentDir } = await connected(t, dir);
	const ws = join(dir, "workspace");

	const notes = readFileSync(join(agentDir, "AGENTS.md"), "utf8");
	assert.match(notes, /on a Linux server/);
	assert.match(notes, new RegExp(`The workspace directory is ${ws}\\.`));
	assert.match(notes, /directly on the server as an unprivileged user/, "no box on this server");

	// Files: write, list, read back; nothing outside the workspace and the skills.
	mkdirSync(join(ws, "site"));
	const wrote = await c.call("fs_write", { path: join(ws, "site", "index.html"), data: Buffer.from("<h1>Halo</h1>").toString("base64") });
	assert.equal(wrote.ok, true, wrote.error);
	const listed = await c.call("fs_list", { path: ws });
	assert.deepEqual(listed.data.map((e) => [e.name, e.type]), [["site", "dir"]]);
	const read = await c.call("fs_read", { path: join(ws, "site", "index.html") });
	assert.equal(Buffer.from(read.data.data, "base64").toString(), "<h1>Halo</h1>");
	const outside = await c.call("fs_read", { path: join(dir, ".griphub", "running") });
	assert.deepEqual([outside.ok, outside.code], [false, "outside_root"]);
	const skills = await c.call("fs_write", { path: join(agentDir, "skills", "x.md"), data: "" });
	assert.equal(skills.ok, false, "the skills folder is read-only");

	// A preview of the site, served on the loopback behind its token.
	const p = await c.call("preview_serve", { dir: join(ws, "site") });
	assert.equal(p.ok, true, p.error);
	const page = await fetch(`http://127.0.0.1:${p.data.port}/${p.data.token}/`);
	assert.equal(await page.text(), "<h1>Halo</h1>");
	assert.equal((await fetch(`http://127.0.0.1:${p.data.port}/wrong/`)).status, 404);
	assert.equal((await c.call("preview_serve", { dir: dir })).code, "outside_root");
	assert.deepEqual((await c.call("preview_stop", { port: p.data.port })).data, { stopped: true });

	// Health for the server screen.
	const h = (await c.call("health")).data;
	assert.equal(h.mode, "server");
	assert.equal(h.transport, "daemon");
	assert.ok(h.disk.freeBytes > 0 && ["ok", "low", "critical"].includes(h.disk.level));
	assert.ok(h.memory.rssBytes > 0);
	assert.deepEqual(h.box, { available: false, installed: false, enabled: false }, "no box on this server");
	assert.equal(h.subagents, false);

	// GitHub sync: off, with the reason, and it cannot be turned on.
	const status = (await c.call("sync_status")).data;
	assert.equal(status.enabled, false);
	assert.match(status.unavailable, /server agent/);
	assert.match((await c.call("sync_enable", { on: true })).error, /server agent/);

	// Notifications start off, with ntfy.sh as the server to use.
	const settings = (await c.call("settings_get")).data;
	assert.deepEqual(settings.notify, { enabled: false, url: "https://ntfy.sh", topic: null });
	assert.equal(settings.dns, "system");
});

test("server mode: the box is the agent's shell when the server has one, and the notes follow it", async (t) => {
	const dir = home(t);
	// Without a box: the status says so, and it cannot be turned on.
	const none = await connected(t, dir);
	const s0 = (await none.c.call("container_status")).data;
	assert.deepEqual([s0.kind, s0.available, s0.enabled], ["podman", false, false]);
	assert.match(s0.problem, /no box on this server/);
	assert.match((await none.c.call("container_enable", { on: true })).error, /no box on this server/);
	assert.match((await none.c.call("box_stop")).error, /no box on this server/);
	none.d.child.kill("SIGTERM");
	await exited(none.d.child);

	// With one (a stand-in launcher): on by default, and the notes say commands run in the container.
	const launcher = join(dir, "box-launcher");
	writeFileSync(launcher, "#!/bin/sh\necho box-works\n");
	chmodSync(launcher, 0o755);
	const { c, agentDir } = await connected(t, dir, { GRIPHUB_BOX: launcher, PATH: `${join(dir, "no-podman")}:/usr/bin:/bin` });
	const notes = () => readFileSync(join(agentDir, "AGENTS.md"), "utf8");
	assert.match(notes(), /inside an Ubuntu container as root/);
	const s1 = (await c.call("container_status")).data;
	assert.deepEqual([s1.available, s1.enabled], [true, true]);
	// The health card shows where commands run; with no podman here the image is not built (commands are refused).
	assert.deepEqual((await c.call("health")).data.box, { available: true, installed: false, enabled: true });
	assert.deepEqual((await c.call("box_check")).data, { ok: true, message: "The box works: a command ran inside it." });
	// Off: commands go straight to the server, and the agent is told.
	assert.equal((await c.call("container_enable", { on: false })).data.enabled, false);
	assert.match(notes(), /directly on the server/);
	assert.equal((await c.call("container_enable", { on: true })).data.enabled, true);
	assert.match(notes(), /inside an Ubuntu container/);
});

test("server mode: a background run nobody watches is refused a risky command, and says so", async (t) => {
	const dir = home(t);
	const ws = join(dir, "workspace");
	mkdirSync(join(ws, "build"));
	writeFileSync(join(ws, "build", "keep.txt"), "still here");
	const tool = JSON.stringify({ name: "bash", arguments: { command: "rm -rf build" } });
	const { c } = await connected(t, dir, { MOCK_TOOL: tool }, ["--import", mockRouter]);
	assert.equal((await c.call("custom_provider_save", { provider: { apiKey: "sk-test", models: [{ id: "mock-model", name: "Mock" }] } })).ok, true);
	assert.equal((await c.call("set_model", { provider: "griphub", model: "mock-model" })).ok, true);
	const queued = await c.call("run_enqueue", { prompt: "Bersihkan build", dir: ws });
	assert.equal(queued.ok, true, queued.error);
	const done = await c.until((r) => r.type === "run_finished", 30_000, "for the run");
	assert.equal(done.run.status, "done");
	assert.match(done.run.summary, /nobody is watching this run/);
	assert.equal(readFileSync(join(ws, "build", "keep.txt"), "utf8"), "still here");
	assert.ok(!c.records.some((r) => r.type === "approval"), "nobody was asked");
});

test("server mode: with nobody looking, a finished subagent is pushed to ntfy; with the app open it is not", async (t) => {
	// A stand-in ntfy server.
	const pushes = [];
	const ntfy = http.createServer((req, res) => {
		let body = "";
		req.on("data", (d) => (body += d));
		req.on("end", () => {
			pushes.push({ url: req.url, title: req.headers.title, body });
			res.end("{}");
		});
	});
	await new Promise((r) => ntfy.listen(0, "127.0.0.1", r));
	t.after(() => ntfy.close());

	const m = await withModel(t);
	const topic = "griphub-0123456789abcdef";
	const set = await m.c.call("settings_set", { settings: { notify: { enabled: true, url: `http://127.0.0.1:${ntfy.address().port}`, topic } } });
	assert.equal(set.ok, true, set.error);

	// The test button: goes out although the app is open.
	assert.deepEqual((await m.c.call("notify_test")).data, { ok: true });
	assert.deepEqual(pushes.map((p) => [p.url, p.title]), [[`/${topic}`, "Test notification"]]);
	pushes.length = 0;

	// The app is open: no push.
	const first = await startSubagent(m);
	writeFileSync(m.mock.MOCK_RELEASE, "");
	await m.c.until((x) => x.type === "subagent_finished" && x.subagent.id === first);
	await new Promise((r) => setTimeout(r, 300));
	assert.deepEqual(pushes, []);

	// The app goes away while a subagent works: its end is pushed, with nothing about the work in it.
	rmSync(m.mock.MOCK_RELEASE);
	await startSubagent(m);
	m.c.socket.destroy();
	await new Promise((r) => setTimeout(r, 200));
	writeFileSync(m.mock.MOCK_RELEASE, "");
	await waitFor(() => pushes.length > 0, 15_000);
	assert.equal(pushes[0].url, `/${topic}`);
	assert.equal(pushes[0].title, "Subagent finished");
	assert.equal(pushes[0].body, "Open GripHub to see.");
});

test("phone mode: the notes are exactly as before, sync is offered, and files work the same way", async (t) => {
	const dir = home(t);
	const ws = join(dir, "workspace");
	const child = spawn(process.execPath, [hostFile], { cwd: ws, env: env(dir), stdio: ["pipe", "pipe", "pipe"] });
	t.after(() => child.kill("SIGKILL"));
	const { until } = collect(child.stdout);
	await until((r) => r.type === "ready");
	let id = 1;
	const call = async (type, args = {}) => {
		const n = id++;
		child.stdin.write(`${JSON.stringify({ id: n, type, ...args })}\n`);
		return until((r) => r.type === "response" && r.id === n);
	};
	const { agentDir } = (await call("hello")).data;
	const before = readFileSync(join(here, "fixtures", "agents-phone.md"), "utf8").replaceAll(PHONE_FIXTURE_WS, ws);
	assert.equal(readFileSync(join(agentDir, "AGENTS.md"), "utf8"), before);
	assert.equal((await call("sync_status")).data.unavailable, null);
	assert.equal((await call("settings_get")).data.dns, "cloudflare");
	assert.notEqual((await call("container_status")).data.kind, "podman");
	assert.match((await call("box_check")).error ?? "", /./, "no box commands on the phone");
	assert.equal((await call("fs_list", { path: ws })).ok, true);
	assert.equal((await call("health")).data.mode, "phone");
	child.stdin.end();
	assert.equal(await exited(child), 0);
});

test("server mode: schedules run on the phone's clock: the app gives its offset, and it holds after a restart", async (t) => {
	const dir = home(t);
	const first = await connected(t, dir, { TZ: "UTC" });
	assert.equal((await first.c.call("health")).data.clock.offsetMinutes, 0, "a server on UTC");
	assert.deepEqual((await first.c.call("timezone_set", { offsetMinutes: 420 })).data, { timeZone: "Etc/GMT-7" });
	assert.equal((await first.c.call("health")).data.clock.offsetMinutes, 420, "WIB from now on");
	// An offset that is not whole hours has no fixed zone: the server keeps the one it has.
	assert.deepEqual((await first.c.call("timezone_set", { offsetMinutes: 330 })).data, { timeZone: "Etc/GMT-7" });
	assert.match((await first.c.call("timezone_set", { offsetMinutes: "x" })).error, /whole number/);
	first.d.child.kill("SIGTERM");
	await exited(first.d.child);

	const again = await connected(t, dir, { TZ: "UTC" });
	assert.equal((await again.c.call("health")).data.clock.offsetMinutes, 420);
});

// ---------------------------------------------------------------------------
// Background jobs call their chat back, as a turn of its own with no message from the user

test("a background job's result calls its chat back with no user message, and turns keep how long they took", async (t) => {
	const tool = { name: "background_job", arguments: { command: "sleep 1; echo build-ok", label: "Build" } };
	const m = await withModel(t, { MOCK_TOOL: JSON.stringify(tool) });
	const sent = await m.c.call("prompt", { text: "Bangun aplikasinya di latar" });
	assert.equal(sent.ok, true, sent.error);

	// The tool returns at once: the turn ends while the job still runs.
	const started = await m.c.until((r) => r.type === "job" && r.job.status === "running", 30_000, "for the job to start");
	assert.equal(started.job.label, "Build");
	assert.equal(started.job.command, "sleep 1; echo build-ok");
	assert.ok(started.job.toolCallId, "the job knows its tool call, for the card");
	const firstDone = await m.c.until((r) => r.type === "agent_done" && typeof r.turnMs === "number", 30_000, "for the first turn");
	assert.ok(firstDone.turnMs >= 0);

	// The job ends; its chat goes on by itself.
	const ended = await m.c.until((r) => r.type === "job" && r.job.status === "done", 30_000, "for the job to end");
	assert.equal(ended.job.exitCode, 0);
	assert.match(ended.job.tail, /build-ok/);
	assert.ok(ended.job.elapsedMs >= 900, "how long it ran, by the host's clock");
	const notice = await m.c.until(
		(r) => r.type === "event" && r.event.type === "message_start" && r.event.message.role === "custom",
		30_000,
		"for the job's message",
	);
	assert.equal(notice.event.message.customType, "griphub_job");
	assert.equal(notice.event.message.details.job.id, ended.job.id);
	const reply = await m.c.until(
		(r) => r.type === "event" && r.event.type === "message_end" && r.event.message.role === "assistant" && /Job said/.test(JSON.stringify(r.event.message.content)),
		30_000,
		"for the agent to answer the job",
	);
	assert.match(JSON.stringify(reply.event.message.content), /build-ok/, "the agent got the output");
	await m.c.until((r) => r.type === "agent_done" && typeof r.turnMs === "number" && r.seq > firstDone.seq, 30_000, "for the second turn");

	// In the chat: one user message (the user's), the job's own message, and each turn's time on its last reply.
	const history = (await m.c.call("messages")).data;
	assert.equal(history.filter((x) => x.role === "user").length, 1, "the callback is not a user message");
	assert.equal(history.filter((x) => x.role === "custom" && x.customType === "griphub_job").length, 1);
	assert.equal(history.filter((x) => x.role === "assistant" && typeof x.griphubTurnMs === "number").length, 2, "both turns kept their time");
	assert.deepEqual((await m.c.call("job_list")).data.map((j) => j.status), ["done"]);
});

test("a background job can be stopped, and stops what it started; its chat is told it was stopped", async (t) => {
	const tool = { name: "background_job", arguments: { command: "sleep 600 & sleep 600; wait" } };
	const m = await withModel(t, { MOCK_TOOL: JSON.stringify(tool) });
	await m.c.call("prompt", { text: "Jalankan" });
	const started = await m.c.until((r) => r.type === "job" && r.job.status === "running", 30_000, "for the job");
	await m.c.until((r) => r.type === "agent_done" && typeof r.turnMs === "number", 30_000, "for the turn");
	const stopped = await m.c.call("job_stop", { jobId: started.job.id });
	assert.equal(stopped.ok, true, stopped.error);
	const ended = await m.c.until((r) => r.type === "job" && r.job.status === "stopped", 10_000, "for the job to stop");
	assert.equal(ended.job.id, started.job.id);
	const notice = await m.c.until((r) => r.type === "event" && r.event.type === "message_start" && r.event.message.role === "custom", 30_000, "for the message");
	assert.match(JSON.stringify(notice.event.message.content), /stopped by the user/);
	// Nothing of it is left running (the job's own sleeps; no other test starts "sleep 600").
	await waitFor(() => !execFileSync("ps", ["-eo", "args"]).toString().split("\n").some((l) => l.trim() === "sleep 600"), 10_000);
});

// ---------------------------------------------------------------------------
// Automatic backups: made on the server with the phone's key, fetched over fs_*, never readable as files there

test("server mode: automatic backups are off until the phone gives its key, then made and readable over fs_*", async (t) => {
	const dir = home(t);
	const { c } = await connected(t, dir);
	const ws = join(dir, "workspace");
	mkdirSync(join(ws, "site", ".git"), { recursive: true });
	writeFileSync(join(ws, "site", "index.html"), "<h1>Halo</h1>");
	writeFileSync(join(ws, "site", ".git", "HEAD"), "ref: refs/heads/main\n");

	const off = await c.call("auto_backup_status");
	assert.equal(off.data.enabled, false);
	const bad = await c.call("auto_backup_configure", { key: "nope" });
	assert.equal(bad.ok, false);
	const on = await c.call("auto_backup_configure", { key: "cd".repeat(32) });
	assert.equal(on.ok, true, on.error);
	assert.equal(on.data.enabled, true);
	const now = await c.call("auto_backup_now");
	assert.equal(now.ok, true, now.error);
	const [latest] = now.data.backups;
	assert.match(latest.name, /^auto-\d+\.ghb$/);
	assert.ok(latest.size > 0);
	// The app fetches it like any file; it cannot be changed from there.
	const read = await c.call("fs_read", { path: latest.path });
	assert.equal(read.ok, true, read.error);
	assert.equal(Buffer.from(read.data.data, "base64").subarray(0, 4).toString(), "GHB1");
	const write = await c.call("fs_write", { path: latest.path, data: "" });
	assert.equal(write.ok, false, "the backups folder is read-only for the app");
	// Turning it off removes what that key made.
	const offAgain = await c.call("auto_backup_configure", { key: null });
	assert.deepEqual(offAgain.data.backups, []);
});

test("phone mode: a server's backup is restored on the phone's own agent with the key, and refused with another", async (t) => {
	// The server makes it.
	const srvDir = home(t);
	const { c } = await connected(t, srvDir);
	mkdirSync(join(srvDir, "workspace", "site", ".git"), { recursive: true });
	writeFileSync(join(srvDir, "workspace", "site", "index.html"), "<h1>Dari server</h1>");
	writeFileSync(join(srvDir, "workspace", "site", ".git", "HEAD"), "ref: refs/heads/main\n");
	// A chat whose first line names the server's workspace: the restore must move it to the phone's.
	mkdirSync(join(srvDir, ".pi", "agent", "sessions"), { recursive: true });
	writeFileSync(
		join(srvDir, ".pi", "agent", "sessions", "chat.jsonl"),
		`${JSON.stringify({ cwd: join(srvDir, "workspace", "site") })}\n`,
	);
	const key = "cd".repeat(32);
	await c.call("auto_backup_configure", { key });
	const made = (await c.call("auto_backup_now")).data.backups[0];

	// The phone restores it. A plain-text zip a dead host left behind is swept at start.
	const dir = home(t);
	mkdirSync(join(dir, ".pi", "agent", "griphub"), { recursive: true });
	writeFileSync(join(dir, ".pi", "agent", "griphub", "restore-123.zip"), "leftover");
	const child = spawn(process.execPath, [hostFile], { cwd: join(dir, "workspace"), env: env(dir), stdio: ["pipe", "pipe", "pipe"] });
	t.after(() => child.kill("SIGKILL"));
	const { until } = collect(child.stdout);
	await until((r) => r.type === "ready", 60_000, "for ready");
	const send = (cmd) => child.stdin.write(`${JSON.stringify(cmd)}\n`);
	send({ id: 1, type: "backup_restore_server", path: made.path, key: "ef".repeat(32) });
	const refused = await until((r) => r.type === "response" && r.id === 1);
	assert.equal(refused.ok, false);
	assert.match(refused.error, /another key/);
	assert.equal(existsSync(join(dir, "workspace", "site")), false, "nothing restored with a wrong key");
	send({ id: 2, type: "backup_restore_server", path: made.path, key });
	const restored = await until((r) => r.type === "response" && r.id === 2);
	assert.equal(restored.ok, true, restored.error);
	assert.ok(restored.data.restored >= 2);
	assert.equal(readFileSync(join(dir, "workspace", "site", "index.html"), "utf8"), "<h1>Dari server</h1>");
	assert.equal(readFileSync(join(dir, "workspace", "site", ".git", "HEAD"), "utf8"), "ref: refs/heads/main\n");
	// The server restore (autobackup.ts), not the plain local one: it reports when the backup was made, and it moves
	// the chat's folder from the server's workspace path to this phone's. A name clash once made host.ts restore with
	// its own one-argument function, which does neither.
	assert.ok(restored.data.createdAt, "a server restore reports when the backup was made");
	const chat = readFileSync(join(dir, ".pi", "agent", "sessions", "chat.jsonl"), "utf8");
	assert.equal(JSON.parse(chat.split("\n")[0]).cwd, join(dir, "workspace", "site"), "the chat's folder is this phone's");
	// No decrypted copy is left behind.
	const leftovers = execFileSync("find", [dir, "-name", "restore-*.zip"]).toString().trim();
	assert.equal(leftovers, "");
});

// ---------------------------------------------------------------------------
// The context limit: past it the chat is summarized, long before a large model's own limit

/**
 * A phone host on the mock router with a model of [contextWindow] tokens and the context limit set to [compactAt].
 * [extra]: more environment for the host; [model]: the model's id (one with a known price, for a test of costs).
 */
async function phoneWithModel(t, contextWindow, compactAt, extra = {}, model = "mock-model") {
	const dir = home(t);
	writeFileSync(join(dir, "release"), "");
	const child = spawn(process.execPath, ["--import", mockRouter, hostFile], {
		cwd: join(dir, "workspace"),
		env: env(dir, { MOCK_RELEASE: join(dir, "release"), MOCK_TEXT: "Oke.", ...extra }),
		stdio: ["pipe", "pipe", "pipe"],
	});
	t.after(() => child.kill("SIGKILL"));
	const { records, until } = collect(child.stdout);
	await until((r) => r.type === "ready", 60_000, "for ready");
	let id = 0;
	const call = async (type, args = {}) => {
		const n = ++id;
		child.stdin.write(`${JSON.stringify({ id: n, type, ...args })}\n`);
		return until((r) => r.type === "response" && r.id === n);
	};
	assert.equal((await call("custom_provider_save", { provider: { apiKey: "sk", models: [{ id: model, name: "Mock", contextWindow }] } })).ok, true);
	assert.equal((await call("set_model", { provider: "griphub", model })).ok, true);
	const before = (await call("settings_get")).data;
	assert.equal(before.compactAt, 300_000, "the default the app shows");
	const set = await call("settings_set", { settings: { compactAt } });
	assert.equal(set.ok, true, set.error);
	assert.equal(set.data.compactAt, compactAt, "the app sees what was saved, 0 included");
	// Each prompt is about 10k tokens.
	const say = async (i) => {
		const from = records.length;
		await call("prompt", { text: `Langkah ${i}: ${"kata ".repeat(8000)}` });
		await until((r, j) => j >= from && r.type === "agent_done" && typeof r.turnMs === "number");
	};
	return { records, until, call, say };
}

test("review before a commit: lines per file against the last commit, and a message the chat's model writes", async (t) => {
	const dir = home(t);
	const ws = join(dir, "workspace");
	const g = (...args) => execFileSync("git", ["-c", "user.name=T", "-c", "user.email=t@t", ...args], { cwd: ws });
	g("init", "-q");
	writeFileSync(join(ws, "login.js"), "const a = 1;\nconst b = 2;\n");
	writeFileSync(join(ws, "logo.png"), Buffer.from([137, 80, 0, 1]));
	g("add", "-A");
	g("commit", "-qm", "start");
	writeFileSync(join(ws, "login.js"), "const a = 1;\nconst b = 3;\nconst c = 4;\n");
	writeFileSync(join(ws, "logo.png"), Buffer.from([137, 80, 0, 2]));
	writeFileSync(join(ws, "notes.md"), "one\ntwo\nthree");
	writeFileSync(join(dir, "release"), "");
	const bodies = join(dir, "bodies.jsonl");
	const child = spawn(process.execPath, ["--import", mockRouter, hostFile], {
		cwd: ws,
		env: env(dir, { MOCK_RELEASE: join(dir, "release"), MOCK_TEXT: "Trim the email before signing in", MOCK_BODIES: bodies }),
		stdio: ["pipe", "pipe", "pipe"],
	});
	t.after(() => child.kill("SIGKILL"));
	const { until } = collect(child.stdout);
	await until((r) => r.type === "ready", 60_000, "for ready");
	let id = 0;
	const call = async (type, args = {}) => {
		const n = ++id;
		child.stdin.write(`${JSON.stringify({ id: n, type, ...args })}\n`);
		return until((r) => r.type === "response" && r.id === n);
	};
	const review = await call("git_review");
	assert.equal(review.ok, true, review.error);
	assert.deepEqual(review.data.stats["login.js"], { additions: 2, deletions: 1 });
	assert.deepEqual(review.data.stats["notes.md"], { additions: 3, deletions: 0 }, "an untracked file counts its lines");
	assert.equal(review.data.stats["logo.png"].binary, true);
	assert.deepEqual(review.data.files.map((f) => f.path).sort(), ["login.js", "logo.png", "notes.md"]);

	const noModel = await call("git_commit_message");
	assert.equal(noModel.ok, false, "no model chosen yet");
	assert.equal((await call("custom_provider_save", { provider: { apiKey: "sk", models: [{ id: "mock-model", name: "Mock", contextWindow: 200000 }] } })).ok, true);
	assert.equal((await call("set_model", { provider: "griphub", model: "mock-model" })).ok, true);
	const msg = await call("git_commit_message");
	assert.equal(msg.ok, true, msg.error);
	assert.match(msg.data.message, /^Trim the email before signing in/);
	const asked = readFileSync(bodies, "utf8").trim().split("\n").map((l) => JSON.stringify(JSON.parse(l))).join("\n");
	assert.match(asked, /commit message/);
	assert.match(asked, /login\.js/);
	assert.match(asked, /notes\.md/, "new files are named");
	assert.match(asked, /const c = 4/, "the diff itself");

	// Committed: nothing left, and no message for nothing.
	g("add", "-A");
	g("commit", "-qm", msg.data.message);
	const none = await call("git_commit_message");
	assert.equal(none.ok, false);
	assert.match(none.error, /nothing to commit/);
});

const compactions = (records) => records.filter((r) => r.type === "event" && r.event.type.startsWith("compaction")).map((r) => r.event);

test("past the context limit the chat is summarized, well before the model's own limit", async (t) => {
	const h = await phoneWithModel(t, 200_000, 25_000);
	for (let i = 0; i < 4; i++) await h.say(i);
	const end = await h.until((r) => r.type === "event" && r.event.type === "compaction_end", 30_000, "for the summary");
	const [start] = compactions(h.records);
	assert.equal(start.type, "compaction_start");
	assert.equal(start.reason, "limit", "the host's own, not pi's near the model's limit");
	assert.equal(start.limit, 25_000);
	assert.equal(end.event.reason, "limit");
	assert.equal(end.event.errorMessage, undefined);
	assert.ok(end.event.result.tokensBefore > 25_000);
	const history = (await h.call("messages")).data;
	assert.ok(history.some((m) => m.role === "compactionSummary"), "the older turns are a summary now");
	// A prompt sent right after goes through (it waits for a summary rather than being refused).
	await h.say(9);
});

test("a summary says what it cost, and the turns it replaced can still be read", async (t) => {
	const h = await phoneWithModel(t, 200_000, 25_000, {}, "claude-haiku-4.5");
	assert.deepEqual((await h.call("summarized_messages")).data, [], "nothing summarized yet");
	for (let i = 0; i < 4; i++) await h.say(i);
	const end = await h.until((r) => r.type === "event" && r.event.type === "compaction_end", 30_000, "for the summary");
	const cost = end.event.result.griphubCost;
	assert.ok(cost?.credits > 0, `a summary is a paid request: ${JSON.stringify(cost)}`);

	const history = (await h.call("messages")).data;
	const line = history.find((m) => m.role === "compactionSummary");
	assert.equal(line.griphubCost?.credits, cost.credits, "the chat opened again says the same");

	const gone = (await h.call("summarized_messages")).data;
	assert.ok(gone.length > 0);
	assert.ok(gone.every((m) => m.role !== "compactionSummary"), "the turns themselves, not a summary of them");
	const asked = (list) => list.filter((m) => m.role === "user").map((m) => m.content[0].text.split(":")[0]);
	assert.equal(asked(gone)[0], "Langkah 0", "from the start of the chat");
	assert.deepEqual([...asked(gone), ...asked(history)], ["Langkah 0", "Langkah 1", "Langkah 2", "Langkah 3"], "each turn once: replaced or kept");
	assert.ok(gone.some((m) => m.role === "assistant" && m.griphubCost), "replies with their cost, like messages");
});

test("a summary that fails is not bought again after every turn, and gives up after a few in a row", async (t) => {
	const dir = mkdtempSync(join(tmpdir(), "gh-fail-"));
	t.after(() => rmSync(dir, { recursive: true, force: true, maxRetries: 10, retryDelay: 100 }));
	const log = join(dir, "requests.log");
	const h = await phoneWithModel(t, 200_000, 25_000, { MOCK_FAIL_SUMMARY: "1", MOCK_LOG: log });
	const summaries = () => (existsSync(log) ? readFileSync(log, "utf8").split("\n").filter((l) => l === "summary").length : 0);
	// Ten turns of about 10k tokens each: past the limit from the third. Without a brake that is a paid summary after
	// each of the last eight; with it, a try only when the chat grew by a quarter, and none after three failures.
	for (let i = 0; i < 10; i++) await h.say(i);
	await new Promise((r) => setTimeout(r, 300));
	const tried = summaries();
	assert.ok(tried >= 1, "it did try once the chat passed the limit");
	assert.ok(tried <= 3, `tried ${tried} times over eight turns past the limit`);
});

test("a context limit of 0 leaves it to the model's own limit", async (t) => {
	const h = await phoneWithModel(t, 200_000, 0);
	for (let i = 0; i < 4; i++) await h.say(i);
	await new Promise((r) => setTimeout(r, 300));
	assert.deepEqual(compactions(h.records), []);
});
