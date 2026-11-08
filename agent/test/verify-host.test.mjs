// Self-verification in the real host, on the mock router (Fitur 2 kriteria a-d): a coding task that changed files ends
// with evidence from a test run of this session; a failing test sends the agent back to fix it, round by round, and
// it then has to report the failure; a project without tests says so plainly; nothing is verified when nothing
// changed or the switch is off; the test command goes through the same approvals as any command; and a "fix" made by
// changing the tests is not taken as a pass.
import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { host } from "./router-host.mjs";

/** A project whose test passes only when ok.txt says "ok". */
function project(ws, { tests = true } = {}) {
	const dir = join(ws, "proj");
	mkdirSync(join(dir, "test"), { recursive: true });
	writeFileSync(join(dir, "ok.txt"), "ok\n");
	if (tests) {
		writeFileSync(join(dir, "package.json"), JSON.stringify({ name: "p", scripts: { test: "node test/check.test.js" } }));
		writeFileSync(
			join(dir, "test", "check.test.js"),
			'const s = require("fs").readFileSync(__dirname + "/../ok.txt", "utf8").trim();\nconsole.log("ok.txt says " + s);\nif (s !== "ok") { console.error("FAIL: expected ok"); process.exit(1); }\nconsole.log("1 passing");\n',
		);
	} else {
		writeFileSync(join(dir, "README.md"), "no tests here\n");
	}
	return dir;
}

const bash = (command) => JSON.stringify({ name: "bash", arguments: { command } });

/** Says yes to every approval card as it comes (the first check of a project folder is asked about). */
function approveAll(h, t, allow = () => true) {
	const answered = new Set();
	const timer = setInterval(() => {
		for (const r of h.records) {
			if (r.type !== "approval" || answered.has(r.approvalId)) continue;
			answered.add(r.approvalId);
			h.call("approval_reply", { approvalId: r.approvalId, allow: allow(r) }).catch(() => {});
		}
	}, 20);
	t.after(() => clearInterval(timer));
}

/** The evidence entries of the open chat, in order. */
async function evidence(h) {
	const messages = await h.call("messages");
	return messages.filter((m) => m.role === "custom" && m.customType === "griphub_verify").map((m) => m.details);
}

async function lastAfterEvidence(h) {
	const messages = await h.call("messages");
	const at = messages.findLastIndex((m) => m.role === "custom" && m.customType === "griphub_verify");
	return messages.slice(at + 1).find((m) => m.role === "assistant");
}

test("a change that keeps the tests green ends with passed evidence from this session, then the closing message", async (t) => {
	const h = await host(t, { MOCK_TOOL: bash("echo ok > ok.txt && echo extra > notes.txt") });
	approveAll(h, t);
	await h.call("new_session", { cwd: project(h.ws) });
	await h.turn("Tambahkan notes.txt");
	const ev = await evidence(h);
	assert.equal(ev.length, 1);
	assert.equal(ev[0].evidence.status, "passed");
	assert.equal(ev[0].evidence.command, "npm test");
	assert.equal(ev[0].evidence.source, "package.json");
	assert.match(ev[0].evidence.summary, /1 passing/);
	assert.ok(ev[0].evidence.durationMs > 0);
	assert.ok(ev[0].evidence.at >= Date.now() - 60_000, "run in this session, not an old result");
	assert.equal(ev[0].next, "close");
	// The closing message comes after the evidence and states it.
	assert.match(JSON.stringify((await lastAfterEvidence(h)).content), /Closing: verification PASSED/);
	// The whole output can be opened.
	const full = await h.call("verify_output", { outputId: ev[0].evidence.outputId });
	assert.match(full.output, /ok\.txt says ok/);
	// The app was told the check ran.
	assert.ok(h.records.some((r) => r.type === "verify" && r.phase === "running" && r.command === "npm test"));
});

test("a failing test sends the agent back to fix it; fixed, the next check passes", async (t) => {
	const h = await host(t, { MOCK_TOOL: bash("echo bad > ok.txt"), MOCK_FIX: bash("echo ok > ok.txt") });
	approveAll(h, t);
	await h.call("new_session", { cwd: project(h.ws) });
	await h.turn("Ubah ok.txt");
	const ev = (await evidence(h)).map((e) => [e.evidence.status, e.next, e.evidence.round]);
	assert.deepEqual(ev, [
		["failed", "fix", 0],
		["passed", "close", 1],
	]);
	assert.match(JSON.stringify((await lastAfterEvidence(h)).content), /PASSED/);
});

test("a failure that is not fixed: each round is checked again, then the failure is reported, never 'done'", async (t) => {
	const h = await host(t, { MOCK_TOOL: bash("echo bad > ok.txt") });
	approveAll(h, t);
	await h.call("settings_set", { settings: { verifyRounds: 2 } });
	await h.call("new_session", { cwd: project(h.ws) });
	await h.turn("Ubah ok.txt");
	const ev = await evidence(h);
	assert.deepEqual(ev.map((e) => [e.evidence.status, e.next]), [
		["failed", "fix"],
		["failed", "fix"],
		["failed", "close"],
	]);
	const last = ev.at(-1).evidence;
	assert.match(last.summary, /FAIL: expected ok/, "the last evidence, as it was");
	// What the model was told for the last one: report the failure, do not say done.
	const messages = await h.call("messages");
	const lastEvidence = messages.findLast((m) => m.customType === "griphub_verify");
	assert.match(lastEvidence.content, /Do NOT say the task is done/);
	assert.match(JSON.stringify((await lastAfterEvidence(h)).content), /FAILED/);
});

test("fixing a failure by changing the tests is not taken as a pass", async (t) => {
	const h = await host(t, { MOCK_TOOL: bash("echo bad > ok.txt"), MOCK_FIX: bash("echo 'console.log(\"1 passing\")' > test/check.test.js") });
	approveAll(h, t);
	await h.call("settings_set", { settings: { verifyRounds: 1 } });
	await h.call("new_session", { cwd: project(h.ws) });
	await h.turn("Ubah ok.txt");
	const ev = await evidence(h);
	assert.equal(ev[0].evidence.status, "failed");
	assert.equal(ev[1].evidence.status, "tests-changed");
	assert.deepEqual(ev[1].evidence.testsTouched, ["test/check.test.js"]);
	assert.equal(ev[1].evidence.exitCode, 0, "the edited test 'passed'");
	assert.equal(ev[1].next, "close");
	assert.match(JSON.stringify((await lastAfterEvidence(h)).content), /NOT ACCEPTED/);
});

test("a project without tests: the evidence says so, plainly", async (t) => {
	const h = await host(t, { MOCK_TOOL: bash("echo more >> README.md") });
	await h.call("new_session", { cwd: project(h.ws, { tests: false }) });
	await h.turn("Tambah baris di README");
	const ev = await evidence(h);
	assert.equal(ev.length, 1);
	assert.equal(ev[0].evidence.status, "none");
	assert.equal(ev[0].evidence.command, null);
	assert.match(JSON.stringify((await lastAfterEvidence(h)).content), /NO TESTS/);
});

test("nothing changed: nothing to verify; switched off: no evidence and no note to the model", async (t) => {
	const h = await host(t, { MOCK_TOOL: bash("cat ok.txt") });
	const dir = project(h.ws);
	await h.call("new_session", { cwd: dir });
	await h.turn("Baca ok.txt");
	assert.equal((await evidence(h)).length, 0);
	assert.match(h.requests().at(-1).system, /Verification in this app/, "the note is there while it is on");

	await h.call("settings_set", { settings: { verify: false } });
	writeFileSync(join(dir, "ok.txt"), "ok\n");
	await h.call("new_session", { cwd: dir });
	await h.turn("Baca ok.txt lagi");
	assert.equal((await evidence(h)).length, 0);
	assert.doesNotMatch(h.requests().at(-1).system, /Verification in this app/);
});

test("the project's own command from Settings wins, and it is asked about like any command", async (t) => {
	const h = await host(t, { MOCK_TOOL: bash("echo extra > notes.txt") });
	const dir = project(h.ws);
	await h.call("settings_set", { settings: { approvalMode: "ask_all", projectVerify: { [dir]: "node test/check.test.js && echo own-command" } } });
	await h.call("new_session", { cwd: dir });
	// Answer the approval cards as they come: the agent's own call yes, the verification command no.
	const answered = new Set();
	const timer = setInterval(() => {
		for (const r of h.records) {
			if (r.type !== "approval" || answered.has(r.approvalId)) continue;
			answered.add(r.approvalId);
			const allow = !r.summary.includes("own-command");
			h.call("approval_reply", { approvalId: r.approvalId, allow }).catch(() => {});
		}
	}, 20);
	t.after(() => clearInterval(timer));
	await h.turn("Tambah notes.txt");
	const asked = h.records.filter((r) => r.type === "approval").map((r) => r.summary);
	assert.ok(asked.some((s) => s.includes("own-command")), JSON.stringify(asked));
	const ev = await evidence(h);
	assert.equal(ev[0].evidence.status, "declined");
	assert.equal(ev[0].evidence.command, "node test/check.test.js && echo own-command");
	assert.equal(ev[0].evidence.source, "project setting");
	assert.match(JSON.stringify((await lastAfterEvidence(h)).content), /NOT RUN/);
	assert.equal(readFileSync(join(dir, "notes.txt"), "utf8").trim(), "extra");
});

test("the first check of a project folder is asked about once, saying it runs the project's own code", async (t) => {
	const h = await host(t, { MOCK_TOOL: bash("echo extra >> notes.txt") });
	const dir = project(h.ws);
	let no = true;
	approveAll(h, t, () => !(no && (no = false) === false));
	await h.call("new_session", { cwd: dir });
	await h.turn("Tambah notes.txt");
	let ev = await evidence(h);
	assert.equal(ev.at(-1).evidence.status, "declined", "a no: nothing ran");
	const asked = h.records.filter((r) => r.type === "approval");
	assert.equal(asked.length, 1);
	assert.match(asked[0].reason, /project's own test command/);
	await h.turn("Tambah lagi");
	ev = await evidence(h);
	assert.equal(ev.at(-1).evidence.status, "passed");
	assert.equal(h.records.filter((r) => r.type === "approval").length, 2, "asked again after the no, then yes");
	await h.turn("Sekali lagi");
	assert.equal((await evidence(h)).at(-1).evidence.status, "passed");
	assert.equal(h.records.filter((r) => r.type === "approval").length, 2, "the yes covers the folder");
});

test("what the test run writes itself is not the agent's change: one check, no extra rounds", async (t) => {
	const h = await host(t, { MOCK_TOOL: bash("echo extra > notes.txt") });
	approveAll(h, t);
	const dir = project(h.ws);
	// A test run that leaves a report behind (as lockfiles, caches and coverage do), different every time.
	writeFileSync(
		join(dir, "package.json"),
		JSON.stringify({ name: "p", scripts: { test: "node test/check.test.js && node -e \"require('fs').writeFileSync('report.txt', String(Date.now()))\"" } }),
	);
	await h.call("new_session", { cwd: dir });
	await h.turn("Tambah notes.txt");
	const ev = await evidence(h);
	assert.deepEqual(ev.map((e) => [e.evidence.status, e.next]), [["passed", "close"]]);
	assert.match(JSON.stringify((await lastAfterEvidence(h)).content), /PASSED/);
});

test("weakening the test script while fixing a failure is changing the tests", async (t) => {
	const weaken = "node -e \"const fs=require('fs');const p=JSON.parse(fs.readFileSync('package.json','utf8'));p.scripts.test='echo 1 passing';fs.writeFileSync('package.json',JSON.stringify(p))\"";
	const h = await host(t, { MOCK_TOOL: bash("echo bad > ok.txt"), MOCK_FIX: bash(weaken) });
	approveAll(h, t);
	await h.call("settings_set", { settings: { verifyRounds: 1 } });
	await h.call("new_session", { cwd: project(h.ws) });
	await h.turn("Ubah ok.txt");
	const ev = await evidence(h);
	assert.equal(ev[0].evidence.status, "failed");
	assert.equal(ev[1].evidence.status, "tests-changed");
	assert.deepEqual(ev[1].evidence.testsTouched, ["package.json (test)"]);
	assert.match(JSON.stringify((await lastAfterEvidence(h)).content), /NOT ACCEPTED/);
});

test("Try again after an error continues the same task: its changes are still verified", async (t) => {
	// The edit is made, then the next request fails; Try again's continuation makes the same edit (nothing new).
	const h = await host(t, { MOCK_TOOL: bash("echo extra > notes.txt"), MOCK_FAIL_CHAT: "2" });
	approveAll(h, t);
	await h.call("new_session", { cwd: project(h.ws) });
	await h.turn("Tambah notes.txt");
	assert.equal((await evidence(h)).length, 0, "the failed turn ended without evidence");
	const done = h.records.length;
	await h.call("retry");
	await h.until((r) => r.type === "agent_done" && h.records.indexOf(r) >= done && !r.retrying, 30_000, "the retry");
	const ev = await evidence(h);
	assert.equal(ev.length, 1, "measured from where the task began, so notes.txt counts");
	assert.equal(ev[0].evidence.status, "passed");
});

// --- Review findings: tests weakened by the task itself, setups that change, the folder that cannot be measured, the
// environment the check runs in.

test("tests weakened in the task itself (before any failure) are never a plain PASSED", async (t) => {
	// The task breaks ok.txt and rewrites the existing test to always pass, in one go.
	const h = await host(t, { MOCK_TOOL: bash("echo bad > ok.txt && echo 'console.log(\"1 passing\")' > test/check.test.js") });
	approveAll(h, t);
	await h.call("new_session", { cwd: project(h.ws) });
	await h.turn("Ubah ok.txt");
	const ev = await evidence(h);
	assert.equal(ev.length, 1);
	assert.equal(ev[0].evidence.status, "passed-tests-changed");
	assert.deepEqual(ev[0].evidence.testsTouched, ["test/check.test.js"]);
	const said = (await h.call("messages")).findLast((m) => m.customType === "griphub_verify").content;
	assert.match(said, /PASSED, BUT THIS TASK CHANGED EXISTING TESTS/);
	assert.match(said, /Do not present it as the original tests passing/);
});

test("a test script changed by the task is not run at all, and says why", async (t) => {
	const weaken = "node -e \"const fs=require('fs');const p=JSON.parse(fs.readFileSync('package.json','utf8'));p.scripts.test='echo 1 passing';fs.writeFileSync('package.json',JSON.stringify(p))\"";
	const h = await host(t, { MOCK_TOOL: bash(`echo bad > ok.txt && ${weaken}`) });
	approveAll(h, t);
	await h.call("new_session", { cwd: project(h.ws) });
	await h.turn("Ubah ok.txt");
	const ev = await evidence(h);
	assert.equal(ev[0].evidence.status, "setup-changed");
	assert.deepEqual(ev[0].evidence.testsTouched, ["package.json (test)"]);
	assert.equal(ev[0].evidence.exitCode, null);
	assert.ok(!h.records.some((r) => r.type === "verify" && r.phase === "running"), "nothing ran");
	assert.ok(!h.records.some((r) => r.type === "approval"), "nothing to approve: nothing runs");
});

test("tests in a folder that .gitignore names are still watched", async (t) => {
	const h = await host(t, { MOCK_TOOL: bash("echo bad > ok.txt && echo 'console.log(\"1 passing\")' > test/check.test.js") });
	approveAll(h, t);
	const dir = project(h.ws);
	writeFileSync(join(dir, ".gitignore"), "test/\n");
	await h.call("new_session", { cwd: dir });
	await h.turn("Ubah ok.txt");
	const ev = await evidence(h);
	assert.equal(ev[0].evidence.status, "passed-tests-changed");
	assert.deepEqual(ev[0].evidence.testsTouched, ["test/check.test.js"]);
});

test("a folder that cannot be measured is said, never a silent done", async (t) => {
	const h = await host(t, { MOCK_TOOL: bash("echo extra > notes.txt") });
	// The checkpoint store cannot be made: every measurement fails.
	writeFileSync(join(h.agentDir, "griphub", "checkpoints"), "not a folder");
	await h.call("new_session", { cwd: project(h.ws) });
	await h.turn("Tambah notes.txt");
	const ev = await evidence(h);
	assert.equal(ev.length, 1);
	assert.equal(ev[0].evidence.status, "unmeasured");
	assert.match(JSON.stringify((await lastAfterEvidence(h)).content), /verification/i);
});

test("the check runs without the host's secrets in its environment", async (t) => {
	const h = await host(t, { MOCK_TOOL: bash("echo extra > notes.txt"), SOME_API_TOKEN: "tok-should-not-leak" });
	approveAll(h, t);
	const dir = project(h.ws);
	writeFileSync(join(dir, "package.json"), JSON.stringify({ name: "p", scripts: { test: "env && node test/check.test.js" } }));
	await h.call("new_session", { cwd: dir });
	await h.turn("Tambah notes.txt");
	const ev = await evidence(h);
	assert.equal(ev[0].evidence.status, "passed");
	const full = (await h.call("verify_output", { outputId: ev[0].evidence.outputId })).output;
	assert.match(full, /^CI=1$/m, "the environment was printed");
	assert.doesNotMatch(full, /tok-should-not-leak/);
	assert.doesNotMatch(full, /abababab/, "nor the store key");
	assert.doesNotMatch(full, /GRIPHUB_STORE_KEY/);
});
