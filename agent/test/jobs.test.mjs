// Background jobs (src/jobs.ts) on their own, with real processes: how they end, what the chat is told, and that
// they never outlive their limit.
import { test } from "node:test";
import assert from "node:assert/strict";
import { bundle, tempDir, waitFor } from "./helpers.mjs";

const { Jobs, jobReport, jobWire, OUTPUT_CAP, REPORT_CAP, JOB_LIMIT_MINUTES, MAX_RUNNING_PER_CHAT, KEPT_PER_CHAT } =
	await bundle("jobs");

function jobsFor(t, extra = {}) {
	const records = [];
	const finished = [];
	const jobs = new Jobs({ send: (r) => records.push(r), shellPath: () => undefined, finished: (j) => finished.push(j), ...extra });
	t.after(() => jobs.stopAll());
	return { jobs, records, finished };
}

test("a job that fails says so with its exit code and the end of its output", async (t) => {
	const { jobs, records, finished } = jobsFor(t);
	const cwd = tempDir(t);
	const job = jobs.start({ sessionFile: "chat.jsonl", cwd, command: "echo compiling; echo 'error: boom' >&2; exit 3" });
	assert.equal(job.status, "running");
	assert.equal(job.label, "echo compiling; echo 'error: boom' >&2; exit 3", "the command's first line names it");
	assert.equal(jobs.busy(), true);
	await waitFor("the job to end", () => finished.length === 1, 10_000);
	assert.equal(job.status, "failed");
	assert.equal(job.exitCode, 3);
	assert.equal(jobs.busy(), false);
	assert.deepEqual(records.map((r) => r.job.status), ["running", "failed"]);
	const report = jobReport(job);
	assert.match(report, /failed after \d+s \(exit code 3\)/);
	assert.match(report, /compiling/);
	assert.match(report, /error: boom/, "stderr too");
	assert.match(report, /not from the user/, "the model knows who is speaking");
});

test("a job is stopped at its limit, and the chat is told", async (t) => {
	const { jobs, finished } = jobsFor(t, { minuteMs: 300 });
	const job = jobs.start({ sessionFile: "c", cwd: tempDir(t), command: "sleep 30", minutes: 1 });
	await waitFor("the job to end", () => finished.length === 1, 10_000);
	assert.equal(job.status, "timeout");
	assert.match(jobReport(job), /stopped at its 1-minute limit/);
});

test("the limit is never more than an hour, whatever is asked", async (t) => {
	const { jobs } = jobsFor(t);
	const job = jobs.start({ sessionFile: "c", cwd: tempDir(t), command: "true", minutes: 500 });
	assert.equal(job.limitMinutes, JOB_LIMIT_MINUTES);
	assert.equal(JOB_LIMIT_MINUTES, 60);
});

test("only the end of a long output is kept, and less of it goes back to the model", async (t) => {
	const { jobs, finished } = jobsFor(t);
	const job = jobs.start({ sessionFile: "c", cwd: tempDir(t), command: "seq 1 40000; echo LAST-LINE" });
	await waitFor("the job to end", () => finished.length === 1, 10_000);
	assert.equal(job.status, "done");
	assert.ok(job.tail.length <= OUTPUT_CAP);
	assert.equal(job.truncated, true);
	assert.match(job.tail, /LAST-LINE\n$/);
	const report = jobReport(job);
	assert.ok(report.length < REPORT_CAP + 1000);
	assert.match(report, /Last lines of its output/);
	assert.match(report, /LAST-LINE/);
});

test("the app gets how long a job ran by the host's clock", async (t) => {
	let now = 1_000;
	const { jobs } = jobsFor(t, { now: () => now });
	const job = jobs.start({ sessionFile: "c", cwd: tempDir(t), command: "true", label: "Tests" });
	now = 6_000;
	assert.equal(jobWire(job, now).elapsedMs, 5_000);
	assert.equal(job.label, "Tests");
});

test("an empty command is refused, and an unknown job cannot be stopped", async (t) => {
	const { jobs } = jobsFor(t);
	assert.throws(() => jobs.start({ sessionFile: "c", cwd: tempDir(t), command: "  " }), /needs a command/);
	assert.throws(() => jobs.stop("nope"), /Unknown job/);
});

test("one chat runs a few jobs at most; another chat is not held back by them", async (t) => {
	const { jobs } = jobsFor(t);
	const cwd = tempDir(t);
	for (let i = 0; i < MAX_RUNNING_PER_CHAT; i++) jobs.start({ sessionFile: "a", cwd, command: "sleep 30" });
	assert.throws(() => jobs.start({ sessionFile: "a", cwd, command: "sleep 30" }), /already runs \d+ background jobs/);
	const other = jobs.start({ sessionFile: "b", cwd, command: "true" });
	assert.equal(other.status, "running");
});

test("old finished records are dropped per chat, so job_list never grows with the host's age", async (t) => {
	const { jobs, finished } = jobsFor(t);
	const cwd = tempDir(t);
	const want = KEPT_PER_CHAT + 5;
	for (let i = 0; i < want; i++) {
		jobs.start({ sessionFile: "a", cwd, command: "true" });
		await waitFor("the job to end", () => finished.length === i + 1, 10_000);
	}
	jobs.start({ sessionFile: "b", cwd, command: "sleep 30" });
	assert.ok(jobs.list("a").length <= KEPT_PER_CHAT, `kept ${jobs.list("a").length} of chat a`);
	assert.equal(jobs.list("b").length, 1, "another chat's records are its own");
	assert.equal(jobs.list().length, jobs.list("a").length + 1);
});

test("a deleted chat's jobs are stopped and forgotten, with no callback", async (t) => {
	const { jobs, finished } = jobsFor(t);
	const cwd = tempDir(t);
	jobs.start({ sessionFile: "a", cwd, command: "sleep 30" });
	const ended = jobs.start({ sessionFile: "a", cwd, command: "true" });
	await waitFor("the quick job to end", () => ended.status !== "running", 10_000);
	const callbacks = finished.length;
	jobs.forgetSession("a");
	await waitFor("the running one to die", () => jobs.busy() === false, 10_000);
	assert.equal(jobs.list("a").length, 0, "no record outlives its chat");
	assert.equal(finished.length, callbacks, "nobody was called back for the forgotten chat");
});
