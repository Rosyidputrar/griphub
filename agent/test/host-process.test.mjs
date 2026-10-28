// The real host as a process, both ways it runs: the phone's child process on stdin/stdout (unchanged: no hello,
// no seq) and the server daemon on a unix socket (hello_server, resume, kick, survives its clients, restarts and
// shuts down cleanly). server_agent.md, phase 1.
import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
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
	t.after(() => rmSync(dir, { recursive: true, force: true }));
	return dir;
}

function env(dir, extra = {}) {
	return {
		...process.env,
		HOME: dir,
		GRIPHUB_WORKSPACE: join(dir, "workspace"),
		GRIPHUB_DIR: join(dir, ".griphub"),
		GRIPHUB_STORE_KEY: "ab".repeat(32),
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
async function withModel(t) {
	const dir = home(t);
	const mock = { MOCK_LOG: join(dir, "mock.log"), MOCK_RELEASE: join(dir, "release"), MOCK_TEXT: "Separuh laporan: 3 dari 5 berkas diperiksa." };
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

	// With one (a stand-in launcher, and a stand-in podman whose image exists once IMAGE_MARK does).
	const launcher = join(dir, "box-launcher");
	writeFileSync(launcher, "#!/bin/sh\necho box-works\n");
	chmodSync(launcher, 0o755);
	const bin = join(dir, "fake-bin");
	const mark = join(dir, "image-built");
	mkdirSync(bin);
	writeFileSync(
		join(bin, "podman"),
		`#!/bin/sh\ncase "$1 $2" in\n"--version "*) echo "podman version 5.0.0" ;;\n"image exists") [ -f "${mark}" ] ;;\n"build "*) touch "${mark}" ;;\n*) exit 1 ;;\nesac\n`,
	);
	chmodSync(join(bin, "podman"), 0o755);
	const griphubDir = join(dir, ".griphub");
	mkdirSync(join(griphubDir, "box"), { recursive: true });
	writeFileSync(join(griphubDir, "box", "Containerfile"), "FROM scratch\n");
	const { c, agentDir } = await connected(t, dir, { GRIPHUB_BOX: launcher, PATH: `${bin}:/usr/bin:/bin` });
	const notes = () => readFileSync(join(agentDir, "AGENTS.md"), "utf8");

	// The image was never built (the setup script could not run podman): commands must not go to a box that fails them
	// all; they run on the server, and turning the box on says why it cannot be.
	assert.match(notes(), /directly on the server/);
	const s0b = (await c.call("container_status")).data;
	assert.deepEqual([s0b.available, s0b.installed, s0b.enabled], [true, false, false]);
	assert.match(s0b.problem, /image has not been built/);
	assert.match((await c.call("container_enable", { on: true })).error, /image has not been built yet/);

	// Rebuilding it from the app: from then on commands run in the container, and the notes say so.
	const built = await c.call("container_install", { distro: "" });
	assert.equal(built.ok, true, built.error);
	assert.deepEqual([built.data.installed, built.data.enabled], [true, true]);
	assert.match(notes(), /inside an Ubuntu container as root/);
	const s1 = (await c.call("container_status")).data;
	assert.deepEqual([s1.available, s1.enabled], [true, true]);
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

test("server mode: an image built by hand on the server is picked up the next time the box is looked at", async (t) => {
	const dir = home(t);
	const launcher = join(dir, "box-launcher");
	writeFileSync(launcher, "#!/bin/sh\necho box-works\n");
	chmodSync(launcher, 0o755);
	const bin = join(dir, "fake-bin");
	const mark = join(dir, "image-built");
	mkdirSync(bin);
	writeFileSync(join(bin, "podman"), `#!/bin/sh\ncase "$1 $2" in\n"--version "*) echo podman ;;\n"image exists") [ -f "${mark}" ] ;;\n*) exit 1 ;;\nesac\n`);
	chmodSync(join(bin, "podman"), 0o755);
	const { c, agentDir } = await connected(t, dir, { GRIPHUB_BOX: launcher, PATH: `${bin}:/usr/bin:/bin` });
	assert.equal((await c.call("container_status")).data.enabled, false);
	writeFileSync(mark, ""); // podman build ... on the server
	assert.equal((await c.call("container_status")).data.enabled, true);
	assert.match(readFileSync(join(agentDir, "AGENTS.md"), "utf8"), /inside an Ubuntu container/);
});
