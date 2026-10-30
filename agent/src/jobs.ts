/**
 * Background jobs: a long command the agent starts and does not wait for (a build, a test suite, a big install). The
 * agent goes on with other work, or ends its turn; when the command ends, its chat is called back with the result as a
 * turn of its own, with no message from the user (host.ts deliverJobs, a pi "custom" message).
 *
 * - A job runs in the agent's own shell (the Linux container on the phone, the box on a server), in the chat's folder.
 * - It belongs to the chat that started it and calls back only that chat: right away when that chat is open and idle,
 *   else once it is.
 * - It runs for at most JOB_LIMIT_MINUTES; then it is stopped and the chat is told so. The user can stop it sooner.
 * - Only the end of its output is kept (OUTPUT_CAP): enough for the agent to see what happened, never the whole log
 *   of a long build in memory or in the chat.
 */

import { spawn, type ChildProcess } from "node:child_process";
import { getShellConfig } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";

/** The longest a job may run. */
export const JOB_LIMIT_MINUTES = 60;

/** How much of a job's output is kept, from the end. */
export const OUTPUT_CAP = 32 * 1024;

/** How much of that the agent is given back. */
export const REPORT_CAP = 6 * 1024;

export type JobStatus = "running" | "done" | "failed" | "timeout" | "stopped";

export interface JobRecord {
	id: string;
	/** The chat that started it (its session file, or its id before it has one). */
	sessionFile: string;
	/** The agent's `background_job` call, so the app can draw the job's state on that card. */
	toolCallId?: string;
	command: string;
	label: string;
	cwd: string;
	status: JobStatus;
	exitCode: number | null;
	startedAt: number;
	finishedAt?: number;
	limitMinutes: number;
	/** The end of the output (stdout and stderr as they came). */
	tail: string;
	/** Output dropped from the front of [tail]. */
	truncated: boolean;
}

/** A job as the app gets it: how long it has run by the host's clock, so a phone with another clock still counts right. */
export function jobWire(job: JobRecord, now = Date.now()) {
	return { ...job, elapsedMs: (job.finishedAt ?? now) - job.startedAt };
}

export interface JobHooks {
	/** Sends a record to the app. */
	send(record: object): void;
	/** The agent's shell, as pi's bash tool would run it. */
	shellPath(): string | undefined;
	/** A job ended (any way): the host calls its chat back. */
	finished(job: JobRecord): void;
	now?: () => number;
	/** How long a minute of the limit is. Only tests shorten it. */
	minuteMs?: number;
}

interface Running {
	job: JobRecord;
	child: ChildProcess;
	timer: NodeJS.Timeout;
	stopReason?: "timeout" | "stopped";
}

export class Jobs {
	private readonly jobs = new Map<string, JobRecord>();
	private readonly running = new Map<string, Running>();
	private next = 1;
	/** Random per process: job ids never repeat across host restarts. */
	private readonly epoch = Math.random().toString(36).slice(2, 6);

	constructor(private readonly hooks: JobHooks) {}

	private now() {
		return this.hooks.now?.() ?? Date.now();
	}

	list(sessionFile?: string): JobRecord[] {
		return [...this.jobs.values()].filter((j) => sessionFile === undefined || j.sessionFile === sessionFile);
	}

	get(id: string): JobRecord | undefined {
		return this.jobs.get(id);
	}

	/** Whether any job is still running (a host restart would kill it). */
	busy(): boolean {
		return this.running.size > 0;
	}

	start(o: { sessionFile: string; command: string; cwd: string; label?: string; minutes?: number; toolCallId?: string }): JobRecord {
		const command = o.command.trim();
		if (!command) throw new Error("The job needs a command");
		const minutes = Math.min(JOB_LIMIT_MINUTES, Math.max(1, Math.round(o.minutes ?? JOB_LIMIT_MINUTES)));
		const job: JobRecord = {
			id: `j${this.epoch}-${this.next++}`,
			sessionFile: o.sessionFile,
			toolCallId: o.toolCallId,
			command,
			label: (o.label ?? "").trim() || firstLine(command),
			cwd: o.cwd,
			status: "running",
			exitCode: null,
			startedAt: this.now(),
			limitMinutes: minutes,
			tail: "",
			truncated: false,
		};
		const shell = getShellConfig(this.hooks.shellPath());
		// Its own process group, so stopping it stops what it started too (npm runs node, make runs the compiler).
		const child = spawn(shell.shell, [...shell.args, command], {
			cwd: o.cwd,
			detached: true,
			env: process.env,
			stdio: ["ignore", "pipe", "pipe"],
		});
		const add = (chunk: Buffer) => {
			job.tail += chunk.toString("utf8");
			if (job.tail.length > OUTPUT_CAP) {
				job.tail = job.tail.slice(job.tail.length - OUTPUT_CAP);
				job.truncated = true;
			}
		};
		child.stdout?.on("data", add);
		child.stderr?.on("data", add);
		const timer = setTimeout(() => this.kill(job.id, "timeout"), minutes * (this.hooks.minuteMs ?? 60_000));
		timer.unref();
		const run: Running = { job, child, timer };
		this.jobs.set(job.id, job);
		this.running.set(job.id, run);
		child.on("error", (e) => {
			add(Buffer.from(`\n${e.message}\n`));
			this.end(run, null);
		});
		child.on("close", (code) => this.end(run, code));
		this.hooks.send({ type: "job", job: jobWire(job, this.now()) });
		return job;
	}

	/** Stops a running job (the user's Stop). Its chat is still called back, told it was stopped. */
	stop(id: string): JobRecord {
		const job = this.jobs.get(id);
		if (!job) throw new Error("Unknown job");
		if (job.status === "running") this.kill(id, "stopped");
		return job;
	}

	/** Stops every job without calling anyone back (the host is shutting down). */
	stopAll() {
		for (const run of [...this.running.values()]) {
			run.stopReason = "stopped";
			clearTimeout(run.timer);
			signalGroup(run.child, "SIGKILL");
		}
	}

	private kill(id: string, why: "timeout" | "stopped") {
		const run = this.running.get(id);
		if (!run) return;
		run.stopReason = why;
		signalGroup(run.child, "SIGTERM");
		// What ignores TERM gets KILL a little later.
		setTimeout(() => {
			if (this.running.has(id)) signalGroup(run.child, "SIGKILL");
		}, 3000).unref();
	}

	private end(run: Running, code: number | null) {
		if (!this.running.delete(run.job.id)) return;
		clearTimeout(run.timer);
		const job = run.job;
		job.exitCode = code;
		job.finishedAt = this.now();
		job.status = run.stopReason ?? (code === 0 ? "done" : "failed");
		this.hooks.send({ type: "job", job: jobWire(job, this.now()) });
		this.hooks.finished(job);
	}
}

function signalGroup(child: ChildProcess, signal: NodeJS.Signals) {
	if (!child.pid) return;
	try {
		process.kill(-child.pid, signal);
	} catch {
		try {
			child.kill(signal);
		} catch {
			// Already gone.
		}
	}
}

function firstLine(text: string) {
	const line = text.split("\n")[0].trim();
	return line.length > 80 ? `${line.slice(0, 79)}…` : line;
}

/** "2m 31s", "45s", "1h 3m". */
export function formatJobDuration(ms: number) {
	const s = Math.max(0, Math.round(ms / 1000));
	if (s < 60) return `${s}s`;
	if (s < 3600) return `${Math.floor(s / 60)}m ${s % 60}s`;
	return `${Math.floor(s / 3600)}h ${Math.floor((s % 3600) / 60)}m`;
}

/** What the agent is told when a job ends: what ran, how it ended, and the end of its output. */
export function jobReport(job: JobRecord) {
	const took = formatJobDuration((job.finishedAt ?? job.startedAt) - job.startedAt);
	const how = {
		running: "is still running",
		done: `finished after ${took} (exit code 0)`,
		failed: `failed after ${took} (exit code ${job.exitCode ?? "none"})`,
		timeout: `was stopped at its ${job.limitMinutes}-minute limit`,
		stopped: `was stopped by the user after ${took}`,
	}[job.status];
	const out = job.tail.length > REPORT_CAP ? job.tail.slice(job.tail.length - REPORT_CAP) : job.tail;
	const cut = job.truncated || job.tail.length > REPORT_CAP;
	return [
		`[Background job ${job.id}] \`${job.command}\` in ${job.cwd} ${how}.`,
		out.trim() ? `${cut ? "Last lines of its output" : "Its output"}:\n\`\`\`\n${out.trimEnd()}\n\`\`\`` : "It printed nothing.",
		"This message comes from the app, not from the user. Carry on with the task with this result.",
	].join("\n\n");
}

/** The open chat, as a job's owner. Read when the tool runs. */
export interface JobParent {
	sessionFile: string;
	cwd: string;
}

/**
 * The `background_job` tool, for interactive chats only (never background runs or subagents). It returns at once;
 * the result comes later as a message of its own.
 */
export function jobTool(jobs: Jobs, getParent: () => JobParent) {
	return {
		name: "background_job",
		label: "Background job",
		description:
			"Start a long shell command in the background and get its result later, without waiting for it: a build, a test suite, a large install or download. " +
			`It runs in the same shell and folder as bash, for at most ${JOB_LIMIT_MINUTES} minutes. ` +
			"This call returns at once. When the command ends you are called back automatically in this chat with its exit code and the end of its output, so do not poll or sleep for it: go on with other work, or end your turn. " +
			"Not for servers that never exit (a dev server): start those with bash and `&` instead.",
		promptSnippet: "background_job: run a long command in the background; its result comes back to this chat when it ends",
		promptGuidelines: [
			"For a command that takes minutes (a full build, the whole test suite, a large install), use background_job instead of bash, then continue with other work.",
			"Do not wait, sleep or poll for a background job: the result arrives as its own message when the command ends.",
		],
		parameters: Type.Object({
			command: Type.String({ description: "The shell command to run." }),
			label: Type.Optional(Type.String({ description: "A short name for it, shown to the user (e.g. 'Build the app')." })),
			minutes: Type.Optional(Type.Number({ description: `Stop it after this many minutes (1-${JOB_LIMIT_MINUTES}, default ${JOB_LIMIT_MINUTES}).` })),
		}),
		async execute(toolCallId: string, params: { command: string; label?: string; minutes?: number }) {
			const parent = getParent();
			const job = jobs.start({
				sessionFile: parent.sessionFile,
				cwd: parent.cwd,
				command: String(params.command ?? ""),
				label: params.label,
				minutes: params.minutes,
				toolCallId,
			});
			return {
				content: [
					{
						type: "text" as const,
						text: `Started background job ${job.id}: \`${job.command}\` in ${job.cwd} (limit ${job.limitMinutes} min). Its result will come back to this chat as a message when it ends. Continue with other work, or end your turn.`,
					},
				],
				details: { jobId: job.id },
			};
		},
	};
}
