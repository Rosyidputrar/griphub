// What a server agent's app needs after it was away: the approvals still waiting (chat and subagents, even when the
// replay buffer no longer holds them), whether subagents are still working (a restart must wait for them), and
// stopping them all on shutdown with their partial reports (server_agent.md 4.2 and 4.9).
import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, rmSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { build } from "esbuild";

const here = dirname(fileURLToPath(import.meta.url));
mkdirSync(join(here, "..", "build"), { recursive: true });
const out = mkdtempSync(join(here, "..", "build", "approvals-test-"));
async function bundle(name) {
	const outfile = join(out, `${name}.mjs`);
	await build({ entryPoints: [join(here, "..", "src", `${name}.ts`)], outfile, bundle: true, platform: "node", format: "esm", packages: "external", logLevel: "error" });
	return import(pathToFileURL(outfile).href);
}
const { Guard } = await bundle("guard");
const { SubagentManager } = await bundle("subagent");

const tick = () => new Promise((r) => setTimeout(r, 0));

test("the chat's guard keeps each waiting approval as the record it sent, until it is answered", async () => {
	const sent = [];
	const guard = new Guard({ send: (r) => sent.push(r), checkpoint: async () => {}, cwd: () => "/w" });
	const answer = guard.askApproval("issue_run", "Fix #12", "an issue asked for it");
	const a = sent.at(-1);
	assert.equal(a.type, "approval");
	assert.deepEqual(guard.pendingApprovals(), [a]);
	guard.askApproval("issue_run", "Fix #13", "again");
	assert.equal(guard.pendingApprovals().length, 2);
	guard.reply(a.approvalId, true);
	assert.equal(await answer, true);
	assert.deepEqual(
		guard.pendingApprovals().map((p) => p.summary),
		["Fix #13"],
	);
	guard.cancelAll();
	assert.deepEqual(guard.pendingApprovals(), []);
	assert.equal(sent.at(-1).type, "approval_dismiss");
});

/**
 * A fake pi session for one subagent: busy until settled, like pi. [script] runs on prompt with the session's options
 * (its guard included), and ends the run unless it returns a promise that stays open.
 */
function session(script) {
	let listener;
	let streaming = false;
	let last = "";
	let settle;
	const s = {
		model: { provider: "griphub", id: "deepseek-v4-flash", name: "DeepSeek V4 Flash" },
		thinkingLevel: "medium",
		get isStreaming() {
			return streaming;
		},
		subscribe(fn) {
			listener = fn;
			return () => {};
		},
		async prompt() {
			streaming = true;
			listener({ type: "agent_start" });
			const done = new Promise((r) => (settle = r));
			const finish = (text) => {
				if (!streaming) return;
				if (text) last = text;
				listener({ type: "agent_end" });
				streaming = false;
				listener({ type: "agent_settled", aborted: false });
				settle();
			};
			s.finish = finish;
			void Promise.resolve(script(s.opts, finish, (t) => (last = t))).then(() => {});
			await done;
		},
		getSessionStats: () => ({ tokens: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 } }),
		getLastAssistantText: () => last,
		abort() {
			s.aborted = true;
			s.finish?.();
		},
		dispose() {},
	};
	return s;
}

function manager(make) {
	const sent = [];
	const m = new SubagentManager({
		send: (r) => sent.push(r),
		wireEvent: (e) => e,
		createSession: async (opts) => {
			const s = make();
			s.opts = opts;
			return s;
		},
		limits: () => ({ creditLimit: 0, minutesLimit: 0, approvalMode: "ask_risky" }),
	});
	return { m, sent };
}

const parent = { sessionFile: "chat.jsonl", title: "t", cwd: "/w", modelId: "deepseek-v4-flash" };

test("a subagent's waiting approval is listed as the subagent_approval_request the app knows, until answered", async () => {
	let answered;
	const { m, sent } = manager(() =>
		session(async (opts, finish) => {
			const ok = await opts.guard.askApproval("bash", "rm -rf build", "deletes files");
			answered = ok;
			finish(ok ? "cleaned" : "left it");
		}),
	);
	const rec = m.start(parent, "Bersihkan build", "full");
	for (let i = 0; i < 5; i++) await tick();
	assert.equal(m.busy(), true);
	const pending = m.pendingApprovals();
	assert.equal(pending.length, 1);
	const p = pending[0];
	assert.equal(p.type, "subagent_approval_request");
	assert.equal(p.subagentId, rec.id);
	assert.equal(p.summary, "rm -rf build");
	// The same card the app got live (so answering it from the pending list is the same as answering the live one).
	const live = sent.find((r) => r.type === "subagent_approval_request");
	assert.equal(live.approvalId, p.approvalId);
	m.approvalReply(rec.id, p.approvalId, true, false);
	const done = await m.waitFor(rec.id);
	assert.equal(answered, true);
	assert.equal(done.status, "done");
	assert.deepEqual(m.pendingApprovals(), []);
	assert.equal(m.busy(), false);
});

test("busy() covers queued, running, waiting and stopping subagents; finished ones are not busy", async () => {
	let made = 0;
	const { m } = manager(() => {
		made++;
		return session(() => new Promise(() => {}));
	});
	assert.equal(m.busy(), false);
	// One more than can run at once: the last one waits in the queue.
	const recs = [0, 1, 2, 3].map((i) => m.start(parent, `Tugas ${i}`, "read"));
	for (let i = 0; i < 5; i++) await tick();
	assert.equal(recs[3].status, "queued");
	assert.equal(m.busy(), true);
	await m.stopAll(1000);
	assert.equal(m.busy(), false);
	// The queued one was never started: shutting down does not build a session only to throw it away.
	assert.equal(made, 3);
	assert.equal(m.get(recs[3].id).stopCode, "before_start");
});

test("stopAll force-stops every working subagent and keeps what each had written", async () => {
	const { m } = manager(() =>
		session((_opts, _finish, write) => {
			write("Separuh laporan: 3 dari 5 berkas diperiksa.");
			return new Promise(() => {}); // works until stopped
		}),
	);
	const a = m.start(parent, "Audit A", "read");
	const b = m.start(parent, "Audit B", "read");
	for (let i = 0; i < 5; i++) await tick();
	await m.stopAll(2000);
	for (const r of [m.get(a.id), m.get(b.id)]) {
		assert.equal(r.status, "stopped");
		assert.equal(r.stopCode, "force");
		assert.equal(r.report, "Separuh laporan: 3 dari 5 berkas diperiksa.");
	}
});

test("stopping a subagent while its session is still being made: it never gets the brief", async () => {
	let release;
	const prompted = [];
	const sent = [];
	const m = new SubagentManager({
		send: (r) => sent.push(r),
		wireEvent: (e) => e,
		// Making the session takes a while (loading tools, MCP, ...).
		createSession: (opts) =>
			new Promise((resolve) => {
				release = () => {
					const s = session(() => new Promise(() => {}));
					const original = s.prompt;
					s.prompt = (...a) => {
						prompted.push(a);
						return original(...a);
					};
					s.opts = opts;
					resolve(s);
				};
			}),
		limits: () => ({ creditLimit: 0, minutesLimit: 0, approvalMode: "auto" }),
	});
	for (const force of [true, false]) {
		const rec = m.start(parent, `Mulai lalu stop (${force})`, "read");
		await tick();
		m.stop(rec.id, force);
		release();
		const done = await m.waitFor(rec.id);
		assert.equal(done.status, "stopped");
		assert.equal(done.stopCode, force ? "force" : "user");
	}
	assert.equal(prompted.length, 0, "no session was prompted");
});

test("once shutting down, no new subagent starts", async () => {
	const { m } = manager(() => session(() => new Promise(() => {})));
	await m.stopAll(100);
	assert.throws(() => m.start(parent, "Terlambat", "read"), /shutting down/);
});

test("stopAll gives up after its timeout on a subagent that never settles", async () => {
	const stuck = () => {
		const s = session(() => new Promise(() => {}));
		s.abort = () => {}; // ignores the abort
		return s;
	};
	const { m } = manager(stuck);
	m.start(parent, "Macet", "read");
	for (let i = 0; i < 5; i++) await tick();
	const t0 = Date.now();
	await m.stopAll(150);
	assert.ok(Date.now() - t0 < 1000, "returned at its timeout");
});

test("cleanup", () => rmSync(out, { recursive: true, force: true }));
