/**
 * Subagents: separate agent loops owned by a parent chat.
 *
 * A subagent is a real pi session (createAgentSession) with a RESTRICTED tool
 * registry, running inside the same host process as the parent chat:
 *
 * - It never becomes a chat. Its session manager is in-memory, so no session
 *   file exists that could leak into the chat list, and it never appears in
 *   `sessions` output. Its progress is only visible inside the parent chat,
 *   through `subagent_*` records on the same JSONL stream.
 * - It cannot create chats or other subagents. That is enforced by the tool
 *   registry, not by prompt wording: the `subagent` tool is only registered on
 *   interactive parent sessions, never on subagent sessions, and subagent
 *   sessions get no session/chat tools at all.
 * - It sees nothing of the parent conversation, only the brief the parent
 *   wrote. Its report returns to the parent as the result of the `subagent`
 *   tool call, and the parent decides what enters the parent chat.
 * - Limits (credits, wall-clock minutes, approval mode) come from Settings
 *   and are snapshotted when the subagent starts. Credit and time limits are
 *   enforced at the next tool call after they are crossed (see
 *   subagentBudgetExtension), not by killing a tool mid-flight.
 * - Queueing and stopping are boundary-safe. A queued message is only sent as
 *   a new turn once the current turn settles; a graceful stop blocks the next
 *   tool call and finishes with a partial report. A force-stop aborts the
 *   session immediately and says so.
 *
 * This module is deliberately independent of CoderRa or any other agent's
 * subagent code: the design follows from the pi SDK's own session/extension
 * API and the product requirements (no new chat, inline progress, queue +
 * stop, Settings-only limits).
 */

import type {
	AgentSession,
	AgentSessionEvent,
	ExtensionAPI,
} from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";

import { Guard, type ApprovalMode } from "./guard.js";
import { messageCost, rateForModel } from "./pricing.js";

/** Read-only work: research, read files, search the web. Never changes anything. */
export const READ_TOOLS = ["read", "grep", "find", "ls", "web_search", "web_fetch"];

/** Full work: read-only tools plus changing files and running commands. */
export const FULL_TOOLS = [...READ_TOOLS, "edit", "write", "bash"];

export type SubagentProfile = "read" | "full";

export type SubagentStatus =
	| "queued"
	| "running"
	| "waiting_approval"
	| "stopping"
	| "done"
	| "failed"
	| "stopped";

/** Limits for one subagent, snapshotted from Settings at start. 0 = no limit. */
export interface SubagentLimits {
	creditLimit: number;
	minutesLimit: number;
	approvalMode: ApprovalMode;
}

export interface QueuedMessage {
	id: string;
	text: string;
	at: number;
}

export interface SubagentToolCall {
	id: string;
	name: string;
	/** One-line summary of the arguments (paths, commands, queries), never the full blob. */
	args: string;
	/** Tool result, capped so one record cannot flood the JSONL stream. */
	output: string;
	status: "running" | "done" | "failed";
	startedAt: number;
	finishedAt?: number;
}

/**
 * Why a subagent stopped, as a stable code the app localizes. `stopReason`
 * carries the same thing as English text for the parent model.
 */
export type SubagentStopCode = "user" | "force" | "time" | "credit" | "before_start" | "limit";

/** Everything Dart needs to render the card, the modal and the history view. */
export interface SubagentRecord {
	id: string;
	/** The parent's `subagent` tool call that created this subagent, so the app can draw the card at that call. */
	toolCallId?: string;
	parentSessionFile: string;
	parentTitle: string;
	/** The brief the parent wrote; shown verbatim in the detail modal. */
	brief: string;
	profile: SubagentProfile;
	status: SubagentStatus;
	createdAt: number;
	startedAt?: number;
	finishedAt?: number;
	currentTool?: string;
	/** One-line argument summary of the current tool (path, query, command). */
	currentArgs?: string;
	/** English activity line, kept for older app builds; the app builds its own from currentTool/currentArgs. */
	currentActivity?: string;
	toolCalls: SubagentToolCall[];
	queue: QueuedMessage[];
	inputTokens: number;
	outputTokens: number;
	cacheReadTokens: number;
	cacheWriteTokens: number;
	/**
	 * Estimated spend in GripHub credits by the router's rule, summed per model
	 * request as each one ends (rate × all tokens incl. cache, or the model's
	 * per-request floor when higher); null when the model has no known rate.
	 */
	credits: number | null;
	/** Model requests made so far, and how many of them were billed at the floor. */
	requests: number;
	flooredRequests: number;
	/** The model doing the work ("provider/id" split), its display name, and its thinking level. */
	provider?: string;
	model?: string;
	modelName?: string;
	thinkingLevel?: string;
	/** The model's rate, for the detail view (credits per 1M tokens, or per image). */
	rate?: number | null;
	/** Final assistant text (full report when done, partial report when stopped). */
	report?: string;
	error?: string;
	stopReason?: string;
	stopCode?: SubagentStopCode;
}

/** How many subagents may run at once; the rest wait for a slot. */
export const MAX_RUNNING = 3;
/** A parent brief longer than this is refused instead of truncated silently. */
export const MAX_TASK_CHARS = 20_000;
/** Characters of tool output kept per call in the record. */
export const TOOL_OUTPUT_CAP = 4000;
/** Tool calls kept per subagent; older ones drop off the head. */
export const TOOL_CALLS_CAP = 200;

/** What the parent chat looks like to a subagent. */
export interface SubagentParent {
	sessionFile: string;
	title: string;
	cwd: string;
	/** The parent's model id, for credit estimates; "" when unknown. */
	modelId: string;
}

export interface SubagentSessionFactoryOptions {
	cwd: string;
	profile: SubagentProfile;
	guard: Guard;
	budgetExtension: (pi: ExtensionAPI) => void;
	onLimit: (reason: string) => void;
	parent: SubagentParent;
}

export type SubagentSessionFactory = (opts: SubagentSessionFactoryOptions) => Promise<AgentSession>;

export interface SubagentHooks {
	send(record: object): void;
	wireEvent(event: AgentSessionEvent): object;
	createSession: SubagentSessionFactory;
	limits(): SubagentLimits;
	/** Throws when the daily budget is used up: a subagent costs a full request before any limit of its own can stop it. */
	checkBudget?(): void;
}

/**
 * Live budget probe for the budget extension. The extension runs on pi's
 * tool-call path, where cumulative token usage is not available, so the
 * manager feeds it cached stats refreshed after every tool result. The
 * worst overshoot is therefore one tool call past the limit.
 */
export interface SubagentBudgetProbe {
	credits(): number | null;
	creditLimit(): number;
	deadlineMs(): number | null;
	stopping(): boolean;
}

/**
 * Blocks the next tool call once a limit is crossed or a stop was requested.
 * `terminate: true` ends the run after the current batch, so the manager's
 * settled handler can finish it with a (partial) report instead of leaving
 * the run hanging. Never kills a tool mid-flight.
 */
export function subagentBudgetExtension(probe: SubagentBudgetProbe) {
	return (pi: ExtensionAPI) => {
		pi.on("tool_call", () => {
			if (probe.stopping()) {
				return {
					block: true,
					reason: "The user stopped this subagent. Do not call any more tools: reply now with a partial report of what you have done and found so far.",
					terminate: true,
				};
			}
			const deadline = probe.deadlineMs();
			if (deadline !== null && Date.now() > deadline) {
				return {
					block: true,
					reason: "The subagent time limit is reached. Do not call any more tools: reply now with a partial report of what you have done and found so far.",
					terminate: true,
				};
			}
			const cap = probe.creditLimit();
			const spent = probe.credits();
			if (cap > 0 && spent !== null && spent >= cap) {
				return {
					block: true,
					reason: "The subagent credit limit is reached. Do not call any more tools: reply now with a partial report of what you have done and found so far.",
					terminate: true,
				};
			}
			return undefined;
		});
	};
}

/** Short English activity line, from a tool call (the app localizes its own from currentTool/currentArgs). */
function activityFor(toolName: string, args: any): string {
	const a = (args ?? {}) as Record<string, unknown>;
	switch (toolName) {
		case "read":
			return `Reading ${String(a.path ?? "")}`;
		case "grep":
			return `Searching for "${String(a.pattern ?? "")}"`;
		case "find":
			return `Finding files ${String(a.pattern ?? "")}`;
		case "ls":
			return `Looking at ${String(a.path ?? "")}`;
		case "web_search":
			return `Searching the web for "${String(a.query ?? "")}"`;
		case "web_fetch":
			return `Opening ${String(a.url ?? "")}`;
		case "edit":
		case "write":
			return `Changing ${String(a.path ?? "")}`;
		case "bash":
			return `Running ${String(a.command ?? "").slice(0, 80)}`;
		default:
			return `Using ${toolName}`;
	}
}

/** One-line argument summary for the tool list in the modal. */
function argsSummary(toolName: string, args: any): string {
	const a = (args ?? {}) as Record<string, unknown>;
	const v = (k: string) => (typeof a[k] === "string" ? (a[k] as string) : "");
	switch (toolName) {
		case "read":
		case "ls":
		case "edit":
		case "write":
			return v("path");
		case "grep":
		case "find":
			return v("pattern");
		case "web_search":
			return v("query");
		case "web_fetch":
			return v("url");
		case "bash":
			return v("command").slice(0, 200);
		default:
			return JSON.stringify(args ?? {}).slice(0, 200);
	}
}

function contentText(content: unknown): string {
	if (typeof content === "string") return content;
	if (!Array.isArray(content)) return "";
	return content.map((c: any) => (c?.type === "text" ? String(c.text ?? "") : "")).join("");
}

function capText(text: string): string {
	return text.length > TOOL_OUTPUT_CAP ? `${text.slice(0, TOOL_OUTPUT_CAP)}… (truncated)` : text;
}

function formatDuration(ms: number): string {
	const s = Math.max(0, Math.round(ms / 1000));
	if (s < 60) return `${s}s`;
	const m = Math.floor(s / 60);
	return `${m}m ${s % 60}s`;
}

/** The suffix appended to the brief when it is sent (the stored brief stays clean). */
const SUBAGENT_SUFFIX =
	"\n\n[You are a subagent working alone on this task. You cannot create chats or other subagents, and you see nothing outside this task. When finished, reply with a complete report of what you did and found.]";

interface Runtime {
	record: SubagentRecord;
	parent: SubagentParent;
	brief: string;
	limits: SubagentLimits;
	guard: Guard;
	session?: AgentSession;
	unsubscribe?: () => void;
	completion: Promise<SubagentRecord>;
	resolveCompletion: (r: SubagentRecord) => void;
	stopRequested: boolean;
	forceStop: boolean;
	limitReason?: string;
	lastError?: string;
	deadlineMs: number | null;
	/** Fires at the time limit: a subagent waiting for an approval would otherwise wait past it (see begin). */
	deadlineTimer?: NodeJS.Timeout;
	settling: boolean;
	cachedCredits: number | null;
}

export class SubagentManager {
	private readonly hooks: SubagentHooks;
	private readonly runtimes = new Map<string, Runtime>();
	private readonly waiting: string[] = [];
	private next = 1;
	private nextQueue = 1;
	/** Set by [stopAll]: the host is going away, so nothing new starts (a freed slot must not start a queued one). */
	private closing = false;

	constructor(hooks: SubagentHooks) {
		this.hooks = hooks;
	}

	list(): SubagentRecord[] {
		return [...this.runtimes.values()].map((r) => r.record);
	}

	get(id: string): SubagentRecord | undefined {
		return this.runtimes.get(id)?.record;
	}

	/** Resolves when the subagent reaches a terminal status. */
	waitFor(id: string): Promise<SubagentRecord> {
		const rt = this.runtimes.get(id);
		if (!rt) return Promise.reject(new Error("Subagent not found"));
		return rt.completion;
	}

	/**
	 * Approvals the subagents are waiting on, as the `subagent_approval_request` records that asked for them, so an app
	 * that reconnects (server agent) can show the cards again even when the replay no longer holds them.
	 */
	pendingApprovals(): object[] {
		const out: object[] = [];
		for (const [id, rt] of this.runtimes) {
			for (const a of rt.guard.pendingApprovals()) out.push({ ...a, type: "subagent_approval_request", subagentId: id });
		}
		return out;
	}

	/** Whether any subagent is waiting for a slot, working, waiting for an approval or stopping: not a time to restart. */
	busy(): boolean {
		for (const rt of this.runtimes.values()) {
			const s = rt.record.status;
			if (s === "queued" || s === "running" || s === "waiting_approval" || s === "stopping") return true;
		}
		return false;
	}

	/**
	 * Force-stops every subagent that has not finished (the host is shutting down) and resolves once they have all
	 * finished, each with its partial report, or after [timeoutMs].
	 */
	async stopAll(timeoutMs = 5000): Promise<void> {
		// Stopping a running one frees a slot; [closing] keeps a queued one from taking it.
		this.closing = true;
		const open: Promise<SubagentRecord>[] = [];
		for (const [id, rt] of this.runtimes) {
			const s = rt.record.status;
			if (s === "done" || s === "failed" || s === "stopped") continue;
			this.stop(id, true);
			open.push(rt.completion);
		}
		if (!open.length) return;
		let timer: NodeJS.Timeout | undefined;
		await Promise.race([
			Promise.allSettled(open),
			new Promise<void>((resolve) => {
				timer = setTimeout(resolve, timeoutMs);
			}),
		]);
		clearTimeout(timer);
	}

	private activeCount(): number {
		let n = 0;
		for (const rt of this.runtimes.values()) {
			if (rt.record.status === "running" || rt.record.status === "waiting_approval" || rt.record.status === "stopping") n++;
		}
		return n;
	}

	/**
	 * Creates a subagent. Starts immediately when a slot is free, otherwise
	 * waits in line (status "queued") and starts when a slot frees up.
	 * The parent is responsible for the brief; this only validates it.
	 */
	start(parent: SubagentParent, brief: string, profile: SubagentProfile, toolCallId?: string): SubagentRecord {
		if (this.closing) throw new Error("The agent is shutting down; the subagent was not started");
		this.hooks.checkBudget?.();
		const clean = brief.trim();
		if (!clean) throw new Error("The subagent task is empty");
		if (clean.length > MAX_TASK_CHARS) throw new Error(`The subagent task is longer than ${MAX_TASK_CHARS} characters`);
		const id = `sub-${Date.now().toString(36)}-${this.next++}`;
		const limits = this.hooks.limits();
		const record: SubagentRecord = {
			id,
			...(toolCallId ? { toolCallId } : {}),
			parentSessionFile: parent.sessionFile,
			parentTitle: parent.title,
			brief: clean,
			profile,
			status: "queued",
			createdAt: Date.now(),
			toolCalls: [],
			queue: [],
			inputTokens: 0,
			outputTokens: 0,
			cacheReadTokens: 0,
			cacheWriteTokens: 0,
			credits: null,
			requests: 0,
			flooredRequests: 0,
			...(parent.modelId ? { model: parent.modelId } : {}),
		};
		// Declared before the guard so its send closure can reference it.
		let rt!: Runtime;
		// Each subagent gets its own guard (own pending approvals, own mode).
		// Approval records are rewritten to the subagent channel so they never
		// surface as the main chat's approval card.
		const guard = new Guard({
			send: (r) => {
				const rec = r as Record<string, unknown>;
				if (rec.type === "approval") {
					if (record.status === "running") {
						record.status = "waiting_approval";
						this.emitStatus(rt);
					}
					this.hooks.send({ ...rec, type: "subagent_approval_request", subagentId: id });
				} else if (rec.type === "approval_dismiss") {
					if (record.status === "waiting_approval") {
						record.status = "running";
						this.emitStatus(rt);
					}
					this.hooks.send({ ...rec, type: "subagent_approval_dismiss", subagentId: id });
				} else {
					this.hooks.send({ type: "subagent_event", subagentId: id, event: rec });
				}
			},
			// No checkpoint: a subagent's file changes are not covered by the
			// parent chat's undo snapshot, and snapshotting from here could
			// reorder the parent's own undo history.
			checkpoint: async () => {},
			cwd: () => parent.cwd,
		});
		guard.mode = limits.approvalMode;
		let resolveCompletion!: (r: SubagentRecord) => void;
		const completion = new Promise<SubagentRecord>((resolve) => {
			resolveCompletion = resolve;
		});
		rt = {
			record,
			parent,
			brief: clean,
			limits,
			guard,
			completion,
			resolveCompletion,
			stopRequested: false,
			forceStop: false,
			deadlineMs: null,
			settling: false,
			cachedCredits: null,
		};
		this.runtimes.set(id, rt);
		if (this.activeCount() < MAX_RUNNING) void this.begin(rt);
		else this.waiting.push(id);
		this.hooks.send({ type: "subagent_started", subagent: record });
		return record;
	}

	/** Graceful stop: finish the current tool, then stop with a partial report. */
	stop(id: string, force: boolean): SubagentRecord {
		const rt = this.runtimes.get(id);
		if (!rt) throw new Error("Subagent not found");
		const rec = rt.record;
		if (rec.status === "done" || rec.status === "failed" || rec.status === "stopped") return rec;
		if (rec.status === "queued") {
			const at = this.waiting.indexOf(id);
			if (at >= 0) this.waiting.splice(at, 1);
			return this.finish(rt, "stopped", "Stopped before it started.", "before_start");
		}
		rt.stopRequested = true;
		if (force) rt.forceStop = true;
		rec.status = "stopping";
		// Unblock a pending approval so the run can reach a boundary instead
		// of hanging on a question nobody will answer.
		rt.guard.cancelAll();
		if (force && rt.session) {
			try {
				rt.session.abort();
			} catch {
				// The settled handler still finishes the run below.
			}
		}
		this.emitStatus(rt);
		return rec;
	}

	/**
	 * Stops the subagents of chats that are being deleted ([gone]: their session files, resolved): nothing would hear
	 * their report, and one still writing would change files with no chat left to say who did. Returns how many.
	 */
	stopForChats(gone: Set<string>, resolvePath: (p: string) => string): number {
		let n = 0;
		for (const [id, rt] of this.runtimes) {
			const s = rt.record.status;
			if (s === "done" || s === "failed" || s === "stopped") continue;
			if (!gone.has(resolvePath(rt.record.parentSessionFile))) continue;
			this.stop(id, true);
			n++;
		}
		return n;
	}

	/** Queues a message for the subagent; it is sent as a new turn at the next settled boundary. */
	queueMessage(id: string, text: string): SubagentRecord {
		const rt = this.runtimes.get(id);
		if (!rt) throw new Error("Subagent not found");
		const rec = rt.record;
		if (rec.status === "done" || rec.status === "failed" || rec.status === "stopped") {
			throw new Error("The subagent has finished; messages can no longer be queued");
		}
		if (rec.status === "stopping") {
			throw new Error("The subagent is stopping; messages can no longer be queued");
		}
		const clean = text.trim();
		if (!clean) throw new Error("The message is empty");
		rec.queue.push({ id: `q-${Date.now().toString(36)}-${this.nextQueue++}`, text: clean, at: Date.now() });
		this.hooks.send({ type: "subagent_queued", subagentId: id, queue: rec.queue });
		return rec;
	}

	removeQueued(id: string, queueId: string): SubagentRecord {
		const rt = this.runtimes.get(id);
		if (!rt) throw new Error("Subagent not found");
		const rec = rt.record;
		rec.queue = rec.queue.filter((q) => q.id !== queueId);
		this.hooks.send({ type: "subagent_queued", subagentId: id, queue: rec.queue });
		return rec;
	}

	moveQueued(id: string, queueId: string, direction: "up" | "down"): SubagentRecord {
		const rt = this.runtimes.get(id);
		if (!rt) throw new Error("Subagent not found");
		const rec = rt.record;
		const at = rec.queue.findIndex((q) => q.id === queueId);
		if (at < 0) return rec;
		const to = direction === "up" ? at - 1 : at + 1;
		if (to < 0 || to >= rec.queue.length) return rec;
		const [item] = rec.queue.splice(at, 1);
		rec.queue.splice(to, 0, item);
		this.hooks.send({ type: "subagent_queued", subagentId: id, queue: rec.queue });
		return rec;
	}

	approvalReply(id: string, approvalId: string, allow: boolean, always: boolean, key?: string): SubagentRecord {
		const rt = this.runtimes.get(id);
		if (!rt) throw new Error("Subagent not found");
		rt.guard.reply(approvalId, allow, always, key);
		// Answered: the app drops the request (and its notification) on this, like the guard's own dismiss.
		this.hooks.send({ type: "subagent_approval_dismiss", subagentId: id, approvalId });
		if (rt.record.status === "waiting_approval") {
			rt.record.status = "running";
			this.emitStatus(rt);
		}
		return rt.record;
	}

	private async begin(rt: Runtime) {
		const rec = rt.record;
		rec.status = "running";
		rec.startedAt = Date.now();
		rec.currentActivity = "Starting…";
		rt.deadlineMs = rt.limits.minutesLimit > 0 ? rec.startedAt + rt.limits.minutesLimit * 60_000 : null;
		// The time limit is checked when the subagent reaches for a tool. One waiting for an approval nobody answers
		// reaches for nothing: it held its slot (and kept queued ones out) past its limit, for good. At the limit the
		// question is withdrawn; the next tool call then meets the limit and the subagent reports what it has.
		if (rt.deadlineMs !== null) {
			rt.deadlineTimer = setTimeout(() => {
				if (rt.record.status === "waiting_approval") rt.guard.cancelAll();
			}, rt.deadlineMs - Date.now() + 50);
			rt.deadlineTimer.unref?.();
		}
		this.emitStatus(rt);
		const probe: SubagentBudgetProbe = {
			credits: () => rt.cachedCredits,
			creditLimit: () => rt.limits.creditLimit,
			deadlineMs: () => rt.deadlineMs,
			stopping: () => rt.stopRequested || rt.forceStop,
		};
		try {
			const session = await this.hooks.createSession({
				cwd: rt.parent.cwd,
				profile: rec.profile,
				guard: rt.guard,
				budgetExtension: subagentBudgetExtension(probe),
				onLimit: (reason) => {
					rt.limitReason = reason;
				},
				parent: rt.parent,
			});
			rt.session = session;
			// Stopped while the session was being made: it never gets the brief.
			if (rt.forceStop || rt.stopRequested) {
				this.finish(rt, "stopped", rt.forceStop ? "Force-stopped by the user." : "Stopped by the user.", rt.forceStop ? "force" : "user");
				return;
			}
			// The model and thinking level actually in use (the parent's, unless unavailable).
			const m = (session as any).model;
			if (m?.id) {
				rec.provider = m.provider;
				rec.model = m.id;
				rec.modelName = m.name ?? m.id;
				const r = rateForModel(m.id);
				rec.rate = r ? r.credits : null;
			}
			const level = (session as any).thinkingLevel;
			if (typeof level === "string") rec.thinkingLevel = level;
			this.emitStatus(rt);
			rt.unsubscribe = session.subscribe((event) => this.onEvent(rt, event));
			session.prompt(`${rt.brief}${SUBAGENT_SUFFIX}`).catch((e: unknown) => {
				this.finish(rt, "failed", String((e as any)?.message ?? e));
			});
		} catch (e: unknown) {
			this.finish(rt, "failed", String((e as any)?.message ?? e));
		}
	}

	private onEvent(rt: Runtime, event: AgentSessionEvent) {
		const rec = rt.record;
		this.hooks.send({ type: "subagent_event", subagentId: rec.id, event: this.hooks.wireEvent(event) });
		const e = event as any;
		switch (event.type) {
			case "agent_start":
				rt.settling = false;
				if (rec.status === "running") {
					rec.currentActivity = "Working…";
					this.emitStatus(rt);
				}
				break;
			case "tool_execution_start":
				rec.currentTool = e.toolName;
				rec.currentArgs = argsSummary(e.toolName, e.args);
				rec.currentActivity = activityFor(e.toolName, e.args);
				rec.toolCalls.push({
					id: String(e.toolCallId),
					name: String(e.toolName),
					args: argsSummary(e.toolName, e.args),
					output: "",
					status: "running",
					startedAt: Date.now(),
				});
				if (rec.toolCalls.length > TOOL_CALLS_CAP) {
					rec.toolCalls.splice(0, rec.toolCalls.length - TOOL_CALLS_CAP);
				}
				this.emitStatus(rt);
				break;
			case "tool_execution_update": {
				const call = rec.toolCalls.find((c) => c.id === String(e.toolCallId));
				if (call) call.output = capText(contentText(e.partialResult?.content));
				break;
			}
			case "tool_execution_end": {
				const call = rec.toolCalls.find((c) => c.id === String(e.toolCallId));
				if (call) {
					call.output = capText(contentText(e.result?.content));
					call.status = e.isError === true ? "failed" : "done";
					call.finishedAt = Date.now();
				}
				rec.currentTool = undefined;
				rec.currentArgs = undefined;
				this.refreshUsage(rt);
				this.emitStatus(rt);
				break;
			}
			case "message_end": {
				const m = e.message;
				if (m?.role === "assistant") {
					// A later answer (pi's auto-retry succeeding) clears an earlier error.
					rt.lastError = m.stopReason === "error" ? String(m.errorMessage ?? "Model error") : undefined;
					this.chargeRequest(rt, m);
				}
				break;
			}
			// Not agent_end: pi can end several agent loops in one run (auto-retry,
			// compaction, follow-ups) and stays busy until agent_settled, so a
			// prompt() sent at agent_end is refused and finishing there would
			// dispose a run pi is still retrying.
			case "agent_settled":
				if (!rt.settling) {
					rt.settling = true;
					this.onSettled(rt);
				}
				break;
			default:
				break;
		}
	}

	/** The one safe boundary: a turn fully ended, nothing mid-flight. */
	private onSettled(rt: Runtime) {
		const rec = rt.record;
		this.refreshUsage(rt);
		if (rt.forceStop) return this.finish(rt, "stopped", "Force-stopped by the user.", "force");
		if (rt.stopRequested) return this.finish(rt, "stopped", "Stopped by the user.", "user");
		if (rt.limitReason) return this.finish(rt, "stopped", rt.limitReason, "limit");
		const over = this.overLimit(rt);
		if (over) return this.finish(rt, "stopped", over.reason, over.code);
		if (rec.queue.length > 0) {
			const next = rec.queue.shift()!;
			this.hooks.send({ type: "subagent_queued", subagentId: rec.id, queue: rec.queue });
			rt.settling = false;
			rt.session?.prompt(next.text).catch((e: unknown) => {
				this.finish(rt, "failed", String((e as any)?.message ?? e));
			});
			return;
		}
		if (rt.lastError) return this.finish(rt, "failed", rt.lastError);
		return this.finish(rt, "done");
	}

	private overLimit(rt: Runtime): { reason: string; code: SubagentStopCode } | null {
		if (rt.deadlineMs !== null && Date.now() > rt.deadlineMs) {
			return { reason: `The subagent time limit was reached (${rt.limits.minutesLimit} min).`, code: "time" };
		}
		if (rt.limits.creditLimit > 0 && rt.cachedCredits !== null && rt.cachedCredits >= rt.limits.creditLimit) {
			return { reason: `The subagent cost limit was reached (${rt.limits.creditLimit} credits).`, code: "credit" };
		}
		return null;
	}

	/**
	 * Adds one finished model request to the running cost, the router's way:
	 * max(floor, rate × all tokens), nothing for a failed request. Called per
	 * request, so the card's credits move with every step instead of at the end.
	 */
	private chargeRequest(rt: Runtime, m: any) {
		const rec = rt.record;
		const model = String(m.model ?? rec.model ?? rt.parent.modelId ?? "");
		if (!model || !m.usage) return;
		// The same estimate as the chat's per-turn cost (pricing.ts): floor, cache tokens, failed requests free.
		const c = messageCost({ ...m, model });
		const cost = c?.credits ?? null;
		rec.requests += 1;
		// One request of unknown price makes the total unknown (never a made-up number).
		const unknown = cost === null || (rec.requests > 1 && rec.credits === null);
		rec.credits = unknown ? null : (rec.credits ?? 0) + cost;
		if (c?.floored) rec.flooredRequests += 1;
		rt.cachedCredits = rec.credits;
		this.refreshUsage(rt);
		this.emitStatus(rt);
	}

	/** Token totals from the session (credits are summed per request in chargeRequest). */
	private refreshUsage(rt: Runtime) {
		const s = rt.session;
		if (!s) return;
		try {
			const stats = s.getSessionStats();
			rt.record.inputTokens = stats.tokens.input;
			rt.record.outputTokens = stats.tokens.output;
			rt.record.cacheReadTokens = stats.tokens.cacheRead ?? 0;
			rt.record.cacheWriteTokens = stats.tokens.cacheWrite ?? 0;
		} catch {
			// Stats are best-effort; a failure here must not kill the run.
		}
	}

	private finish(rt: Runtime, status: "done" | "failed" | "stopped", reason?: string, code?: SubagentStopCode): SubagentRecord {
		const rec = rt.record;
		if (rec.status === "done" || rec.status === "failed" || rec.status === "stopped") return rec;
		clearTimeout(rt.deadlineTimer);
		rec.status = status;
		rec.finishedAt = Date.now();
		rec.currentTool = undefined;
		rec.currentArgs = undefined;
		rec.currentActivity = undefined;
		if (status === "failed") rec.error = reason ?? "Failed.";
		if (status === "stopped") {
			rec.stopReason = reason ?? "Stopped.";
			rec.stopCode = code ?? "user";
		}
		try {
			const text = rt.session?.getLastAssistantText() ?? "";
			if (text) rec.report = text;
		} catch {
			// Report is best-effort.
		}
		this.refreshUsage(rt);
		try {
			rt.unsubscribe?.();
		} catch {
			// Ignore teardown errors.
		}
		rt.guard.cancelAll();
		try {
			rt.session?.dispose();
		} catch {
			// Ignore teardown errors.
		}
		rt.session = undefined;
		this.hooks.send({ type: "subagent_finished", subagent: rec });
		rt.resolveCompletion(rec);
		this.promoteNext();
		return rec;
	}

	private promoteNext() {
		if (this.closing) return;
		while (this.activeCount() < MAX_RUNNING && this.waiting.length > 0) {
			const id = this.waiting.shift()!;
			const rt = this.runtimes.get(id);
			if (!rt || rt.record.status !== "queued") continue;
			void this.begin(rt);
		}
	}

	/** Lightweight status broadcast (no tool outputs; those travel via subagent_event). */
	private emitStatus(rt: Runtime) {
		const rec = rt.record;
		this.hooks.send({
			type: "subagent_status",
			subagentId: rec.id,
			status: rec.status,
			currentTool: rec.currentTool ?? null,
			currentArgs: rec.currentArgs ?? null,
			currentActivity: rec.currentActivity ?? null,
			queueCount: rec.queue.length,
			inputTokens: rec.inputTokens,
			outputTokens: rec.outputTokens,
			cacheReadTokens: rec.cacheReadTokens,
			cacheWriteTokens: rec.cacheWriteTokens,
			credits: rec.credits,
			requests: rec.requests,
			flooredRequests: rec.flooredRequests,
			provider: rec.provider ?? null,
			model: rec.model ?? null,
			modelName: rec.modelName ?? null,
			thinkingLevel: rec.thinkingLevel ?? null,
			rate: rec.rate ?? null,
		});
	}
}

/**
 * The `subagent` tool for interactive parent sessions. The parent model calls
 * it with a self-contained brief; the call blocks until the subagent finishes
 * and returns its report (full when done, partial when stopped, plus the
 * failure reason when it fails). The parent never sees the subagent's
 * transcript, only the report.
 */
export function subagentTool(manager: SubagentManager, getParent: () => SubagentParent) {
	return {
		name: "subagent",
		label: "Subagent",
		description:
			"Hand a self-contained job to a separate agent and wait for its report. " +
			"Use it when a task is independent enough to stand alone: research, reading a codebase, checking something, or a bounded change. " +
			"The subagent sees ONLY the task text you write here, nothing of this conversation, so the task must include every fact, path and constraint it needs. " +
			"It cannot create chats or other subagents. Its report comes back as this tool's result; quote or use what matters and say what it could not finish. " +
			"Default profile is read (research only, no file changes, no commands). Use full only when the task genuinely needs to edit files or run commands.",
		promptSnippet: "subagent: delegate self-contained jobs to a separate agent and use its report",
		promptGuidelines: [
			"For a self-contained side task, call subagent with the full task text instead of doing it inline, then continue with its report.",
			"Write the task so it stands alone: goal, exact paths or questions, what a good report looks like. Never assume the subagent knows this conversation.",
			"Use profile read unless the task must change files or run commands; a read subagent cannot break anything.",
		],
		parameters: Type.Object({
			task: Type.String({ description: "The self-contained task, with all facts, paths and constraints it needs." }),
			profile: Type.Optional(
				Type.String({ description: "read (default): research only. full: may edit files and run commands." }),
			),
		}),
		async execute(toolCallId: string, params: { task: string; profile?: string }) {
			const parent = getParent();
			const profile: SubagentProfile = params.profile === "full" ? "full" : "read";
			const record = manager.start(parent, params.task, profile, toolCallId);
			const done = await manager.waitFor(record.id);
			const elapsed = done.startedAt && done.finishedAt ? formatDuration(done.finishedAt - done.startedAt) : "?";
			const usage = `(${done.toolCalls.length} tool calls, ${elapsed}${done.credits !== null ? `, ~${done.credits.toFixed(2)} credits (estimate)` : ""})`;
			let text: string;
			if (done.status === "done") {
				text = `Subagent finished ${usage}.\n\nReport:\n${done.report ?? "(no report)"}`;
			} else if (done.status === "stopped") {
				text = `Subagent stopped ${usage}. Reason: ${done.stopReason ?? "stopped"}\n\nPartial report:\n${done.report ?? "(no partial report)"}`;
			} else {
				text = `Subagent failed ${usage}. Error: ${done.error ?? "unknown"}\n\nPartial output:\n${done.report ?? "(no partial output)"}`;
			}
			return {
				content: [{ type: "text" as const, text }],
				details: { subagentId: done.id, status: done.status },
			};
		},
	};
}
