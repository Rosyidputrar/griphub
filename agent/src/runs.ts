/**
 * Background agent runs: a queue (with a concurrency limit, so several agents
 * can work at once), scheduled tasks, and GitHub issue triggers. Each run is
 * its own pi session, so the result can be opened later as a normal chat.
 */

import { atomicWrite, isObject, keepBackup, loadStore, readJsonFile } from "./state.js";

/** Nobody watches a background run, so one that never settles is stopped after this long. */
export const RUN_TIME_LIMIT_MS = 60 * 60_000;
/** Finished runs kept in the list; queued and running ones are always kept. */
const KEEP_FINISHED = 100;

export interface RunSession {
	sessionFile?: string;
	prompt(text: string): Promise<void>;
	lastText(): string | undefined;
	errorText(): string | undefined;
	abort(): Promise<void>;
	dispose(): void;
}

export interface Run {
	id: string;
	title: string;
	prompt: string;
	cwd: string;
	status: "queued" | "running" | "done" | "error" | "cancelled";
	source: "queue" | "schedule" | "trigger";
	createdAt: number;
	startedAt?: number;
	finishedAt?: number;
	sessionFile?: string;
	summary?: string;
	/** The schedule that queued this run, so a slow run is not queued again on top of itself. */
	scheduleId?: string;
}

export interface Schedule {
	id: string;
	name: string;
	prompt: string;
	cwd: string;
	enabled: boolean;
	/** Run every N minutes, or daily at "HH:MM" (device time). */
	everyMinutes?: number;
	dailyAt?: string;
	/** Optional trigger instead of a clock: new GitHub issues with a label. */
	trigger?: { type: "github_issues"; repo: string; label: string; seen?: number[] };
	lastRun?: number;
}

interface Store {
	runs: Run[];
	schedules: Schedule[];
	concurrency: number;
}

export class Runner {
	private store: Store = { runs: [], schedules: [], concurrency: 1 };
	private active = new Map<string, RunSession>();
	private timer?: NodeJS.Timeout;
	private firstTick?: NodeJS.Timeout;
	/** Issue approvals waiting for an answer, so polls never stack duplicate cards. */
	private pendingIssueApprovals = new Set<string>();

	constructor(
		private readonly file: string,
		private readonly makeSession: (cwd: string) => Promise<RunSession>,
		private readonly notify: (record: object) => void,
		private readonly github: (path: string) => Promise<any>,
		/**
		 * Asks the user before an issue-triggered run starts. Issue text is
		 * untrusted input from GitHub; without this callback the run never
		 * starts (fail closed).
		 */
		private readonly requestApproval?: (summary: string, reason: string) => Promise<boolean>,
	) {
		// A file that cannot be read is set aside and reported, not taken for "no runs and no schedules" and written over.
		const saved = loadStore<Record<string, unknown> | null>(file, readJsonFile, null, (v) => isObject(v) && (v.runs === undefined || Array.isArray(v.runs)) && (v.schedules === undefined || Array.isArray(v.schedules)));
		if (saved) this.store = { runs: [], schedules: [], concurrency: 1, ...saved } as typeof this.store;
		// Runs interrupted by an app restart cannot resume.
		for (const r of this.store.runs) if (r.status === "running") r.status = "error";
		this.timer = setInterval(() => void this.tick(), 60_000);
		this.firstTick = setTimeout(() => void this.tick(), 5_000);
	}

	private save() {
		// Cutting the list at a fixed length used to drop the oldest runs even while they were still queued.
		let finished = 0;
		this.store.runs = this.store.runs.filter((r) => r.status === "queued" || r.status === "running" || ++finished <= KEEP_FINISHED);
		keepBackup(this.file, readJsonFile, isObject);
		atomicWrite(this.file, JSON.stringify(this.store, null, 1));
	}

	summary() {
		return {
			runs: this.store.runs,
			schedules: this.store.schedules,
			concurrency: this.store.concurrency,
			running: this.active.size,
			keepAlive: this.keepAlive(),
		};
	}

	/** Whether the app should stay alive in the background (runs or schedules pending). */
	keepAlive() {
		return this.active.size > 0 || this.store.runs.some((r) => r.status === "queued") || this.store.schedules.some((s) => s.enabled);
	}

	private changed() {
		this.save();
		this.notify({ type: "runs", ...this.summary() });
	}

	setConcurrency(n: number) {
		this.store.concurrency = Math.min(Math.max(Math.round(n) || 1, 1), 3);
		this.changed();
		this.pump();
	}

	enqueue(prompt: string, cwd: string, title?: string, source: Run["source"] = "queue", scheduleId?: string) {
		const run: Run = {
			id: `r${Date.now().toString(36)}${Math.random().toString(36).slice(2, 6)}`,
			title: title || prompt.split("\n")[0].slice(0, 80),
			prompt,
			cwd,
			status: "queued",
			source,
			createdAt: Date.now(),
			scheduleId,
		};
		this.store.runs.unshift(run);
		this.changed();
		this.pump();
		return run;
	}

	async cancel(id: string) {
		const run = this.store.runs.find((r) => r.id === id);
		if (!run) return;
		if (run.status === "running") await this.active.get(id)?.abort();
		if (run.status === "queued" || run.status === "running") run.status = "cancelled";
		this.changed();
	}

	clearFinished() {
		this.store.runs = this.store.runs.filter((r) => r.status === "queued" || r.status === "running");
		this.changed();
	}

	/**
	 * Removes one finished run from the list (its chat stays, like "Clear finished"). Returns it and its
	 * place so the app can offer Undo; queued and running runs are refused, they must be cancelled first.
	 */
	delete(id: string): { run: Run; index: number } | null {
		const index = this.store.runs.findIndex((r) => r.id === id);
		if (index < 0) return null;
		const run = this.store.runs[index];
		if (run.status === "queued" || run.status === "running") throw new Error("Cancel the run before removing it");
		this.store.runs.splice(index, 1);
		this.changed();
		return { run, index };
	}

	/** Puts back a run [delete] removed (Undo), at its old place. A finished run only; never twice. */
	restore(run: Run, index: number) {
		if (!run?.id || this.store.runs.some((r) => r.id === run.id)) return;
		if (run.status === "queued" || run.status === "running") return;
		this.store.runs.splice(Math.min(Math.max(Math.trunc(index) || 0, 0), this.store.runs.length), 0, run);
		this.changed();
	}

	private pump() {
		// Count by status, not by the active map: start() is async and only
		// registers in `active` after makeSession resolves, so counting the
		// map let this synchronous loop drain the whole queue at once and
		// the concurrency limit never applied. start() flips the status
		// synchronously, so this count is exact.
		while (this.store.runs.filter((r) => r.status === "running").length < this.store.concurrency) {
			const next = [...this.store.runs].reverse().find((r) => r.status === "queued");
			if (!next) return;
			void this.start(next);
		}
	}

	private async start(run: Run) {
		run.status = "running";
		run.startedAt = Date.now();
		this.changed();
		let session: RunSession | undefined;
		let timer: NodeJS.Timeout | undefined;
		let timedOut = false;
		try {
			session = await this.makeSession(run.cwd);
			this.active.set(run.id, session);
			run.sessionFile = session.sessionFile;
			this.changed();
			const started = session;
			timer = setTimeout(() => {
				timedOut = true;
				void started.abort();
			}, RUN_TIME_LIMIT_MS);
			await session.prompt(run.prompt);
			const err = timedOut ? `Stopped after ${RUN_TIME_LIMIT_MS / 60_000} minutes without finishing.` : session.errorText();
			if ((run.status as string) === "cancelled") return;
			run.status = err ? "error" : "done";
			run.summary = (err ?? session.lastText() ?? "").slice(0, 600);
		} catch (e) {
			if ((run.status as string) !== "cancelled") {
				run.status = "error";
				run.summary = String((e as Error).message ?? e).slice(0, 600);
			}
		} finally {
			clearTimeout(timer);
			run.finishedAt = Date.now();
			this.active.delete(run.id);
			session?.dispose();
			this.changed();
			this.notify({ type: "run_finished", run });
			this.pump();
		}
	}

	// -------------------------------------------------------------------------
	// Schedules

	saveSchedule(s: Partial<Schedule>) {
		if (!s.name?.trim() || !s.prompt?.trim()) throw new Error("A schedule needs a name and a prompt");
		if (!s.trigger && !s.everyMinutes && !s.dailyAt) throw new Error("Choose how often it runs");
		const i = s.id ? this.store.schedules.findIndex((x) => x.id === s.id) : -1;
		// lastRun is server-managed (the edit form never sends it): an edit
		// used to overwrite it with undefined, which re-armed every-minute
		// and daily schedules to fire immediately after any edit.
		const entry: Schedule = {
			id: s.id ?? `s${Date.now().toString(36)}`,
			name: s.name.trim(),
			prompt: s.prompt.trim(),
			cwd: s.cwd ?? "",
			enabled: s.enabled ?? true,
			everyMinutes: s.everyMinutes ? Math.max(15, Math.round(s.everyMinutes)) : undefined,
			dailyAt: s.dailyAt || undefined,
			trigger: s.trigger,
			lastRun: s.lastRun ?? (i >= 0 ? this.store.schedules[i].lastRun : undefined),
		};
		if (i >= 0) this.store.schedules[i] = { ...this.store.schedules[i], ...entry };
		else this.store.schedules.push(entry);
		this.changed();
		return entry;
	}

	deleteSchedule(id: string) {
		this.store.schedules = this.store.schedules.filter((s) => s.id !== id);
		this.changed();
	}

	runScheduleNow(id: string) {
		const s = this.store.schedules.find((x) => x.id === id);
		if (!s) throw new Error("Unknown schedule");
		s.lastRun = Date.now();
		return this.enqueue(s.prompt, s.cwd, s.name, "schedule", s.id);
	}

	private due(s: Schedule, now: Date) {
		if (s.everyMinutes) return !s.lastRun || now.getTime() - s.lastRun >= s.everyMinutes * 60_000;
		if (s.dailyAt) {
			const [h, m] = s.dailyAt.split(":").map(Number);
			const today = new Date(now);
			today.setHours(h, m, 0, 0);
			return now >= today && (!s.lastRun || s.lastRun < today.getTime());
		}
		return false;
	}

	private async tick() {
		const now = new Date();
		for (const s of this.store.schedules) {
			if (!s.enabled) continue;
			if (s.trigger?.type === "github_issues") {
				// Poll at most every 10 minutes.
				if (s.lastRun && now.getTime() - s.lastRun < 10 * 60_000) continue;
				s.lastRun = now.getTime();
				await this.pollIssues(s).catch((e) => this.notify({ type: "notice", message: `Trigger ${s.name}: ${e.message}` }));
				continue;
			}
			if (this.due(s, now)) {
				// Still queued or running from last time: wait for it instead of stacking another (lastRun is left as is, so it runs once that one ends).
				if (this.store.runs.some((r) => r.scheduleId === s.id && (r.status === "queued" || r.status === "running"))) continue;
				s.lastRun = now.getTime();
				this.enqueue(s.prompt, s.cwd, s.name, "schedule", s.id);
			}
		}
		this.save();
	}

	private async pollIssues(s: Schedule) {
		const t = s.trigger!;
		const issues: any[] = await this.github(
			`/repos/${t.repo}/issues?state=open&labels=${encodeURIComponent(t.label)}&per_page=20&sort=created&direction=desc`,
		);
		const seen = new Set(t.seen ?? []);
		const first = t.seen === undefined;
		for (const issue of issues.filter((i) => !i.pull_request)) {
			if (seen.has(issue.number)) continue;
			// The first poll only records what already exists.
			if (first) {
				seen.add(issue.number);
				continue;
			}
			// Issue text is untrusted input: it only reaches a run (with the
			// user's tokens) after an explicit approval. Denied issues are
			// marked seen so they are not re-prompted; undecided ones are
			// not, so a host restart re-prompts instead of dropping them.
			const approvalKey = `${s.id}:${t.repo}#${issue.number}`;
			if (this.pendingIssueApprovals.has(approvalKey)) continue;
			this.pendingIssueApprovals.add(approvalKey);
			let ok = false;
			try {
				ok = this.requestApproval
					? await this.requestApproval(
							`${s.name}: #${issue.number} ${issue.title}`,
							"Approve only if you trust this issue: its title and body come from GitHub and may contain instructions for the agent. The run uses your saved tokens.",
						)
					: false;
			} catch {
				ok = false;
			}
			this.pendingIssueApprovals.delete(approvalKey);
			seen.add(issue.number);
			if (!ok) {
				this.notify({ type: "notice", message: `Trigger ${s.name}: issue #${issue.number} was not approved, skipping` });
				continue;
			}
			this.enqueue(
				`${s.prompt}\n\nGitHub issue ${t.repo}#${issue.number}: ${issue.title}\n\n${issue.body ?? ""}\n\n${issue.html_url}`,
				s.cwd,
				`${s.name}: #${issue.number} ${issue.title}`,
				"trigger",
			);
		}
		t.seen = [...seen].slice(-200);
		this.changed();
	}

	dispose() {
		if (this.timer) clearInterval(this.timer);
		if (this.firstTick) clearTimeout(this.firstTick);
	}
}
