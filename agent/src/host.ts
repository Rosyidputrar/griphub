/**
 * GripHub AI Agent agent host.
 *
 * Runs inside the bundled Node runtime on the device and exposes the pi SDK to
 * the Flutter app over JSONL on stdin/stdout. On a server (--listen, see
 * server_agent.md) the same records go over a unix socket instead (transport.ts):
 *
 *   app  -> host   {"id": 1, "type": "prompt", "text": "..."}
 *   host -> app    {"type": "response", "id": 1, "ok": true, "data": ...}
 *   host -> app    {"type": "event", "event": <pi session event>}
 *   host -> app    {"type": "auth_prompt" | "approval" | "task" | "runs" | ...}
 *
 * stdout is reserved for protocol records; logs go to stderr.
 */

import { existsSync, mkdirSync, readdirSync, readFileSync, rmSync, unlinkSync, writeFileSync } from "node:fs";
import { dirname, join, resolve, sep } from "node:path";
import { fileURLToPath } from "node:url";
import {
	type AgentSession,
	type AgentSessionEvent,
	createAgentSession,
	DefaultResourceLoader,
	estimateTokens,
	getAgentDir,
	ModelRuntime,
	SessionManager,
	SettingsManager,
	sessionEntryToContextMessages,
	VERSION,
} from "@earendil-works/pi-coding-agent";
import { agentsFileText, isManaged } from "./agents-file.js";
import { AutoBackup, decryptBackup, restoreBackup } from "./autobackup.js";
import { Checkpoints } from "./checkpoints.js";
import { Container, type Distro } from "./container.js";
import { installDohLookup } from "./dns.js";
import * as gitops from "./gitops.js";
import { Fs, isFsCommand, runFsCommand } from "./fs.js";
import { Guard } from "./guard.js";
import { DEFAULT_HEALTH_LIMITS, Health, type HealthChange, humanBytes } from "./health.js";
import { compactLimit, gitRun, Integrations, type Log, run } from "./integrations.js";
import { type JobRecord, Jobs, jobReport, jobTool, jobWire } from "./jobs.js";
import { installLenientTools } from "./lenient.js";
import { limitsExtension } from "./limits.js";
import { Mcp } from "./mcp.js";
import { Notifier } from "./notify.js";
import { syncLauncher } from "./launcher.js";
import { PodmanBox } from "./podmanbox.js";
import { Preview } from "./preview.js";
import { CustomProviders, fetchModels, generateImage, GRIPHUB_API, GRIPHUB_BASE_URL, GRIPHUB_ID, listImageModels } from "./providers.js";
import { type RunSession, Runner } from "./runs.js";
import { onStoreProblem, storeProblemMessage } from "./state.js";
import { serialQueue, swapSession } from "./sessionswap.js";
import { startWatchdog } from "./watchdog.js";
import { Skills } from "./skills.js";
import {
	FULL_TOOLS,
	READ_TOOLS,
	SubagentManager,
	subagentTool,
	type SubagentParent,
	type SubagentSessionFactoryOptions,
} from "./subagent.js";
import { GitHubSync } from "./sync.js";
import { todoTool } from "./todo.js";
import { s1Usage, webTools } from "./web.js";
import {
	collectFiles,
	dbQuery,
	dbTables,
	detectTests,
	readZip,
	search,
	findFiles,
	Templates,
	Tunnels,
	usageSummary,
	wibDay,
	writeZip,
} from "./workbench.js";
import { FALLBACK_RATES, messageCost, requestEstimate, usageOf, usePricingRouter } from "./pricing.js";
import { PromptQueue } from "./promptqueue.js";
import { Router } from "./router.js";
import { Hub, LineBuffer, listenOnSocket, PROTOCOL, RestartGate, stdioConn } from "./transport.js";

type Command = { id?: number; type: string; [key: string]: any };

/** Built-in and app tools; MCP tools are added per session. This is the *active* set. */
const TOOLS = ["read", "bash", "edit", "write", "grep", "find", "ls", "web_search", "web_fetch", "web_screenshot", "todo_write"];

const agentDir = getAgentDir();
const workspace = process.env.GRIPHUB_WORKSPACE ?? process.cwd();
const stateDir = join(agentDir, "griphub");

let modelRuntime: ModelRuntime;
let settingsManager: SettingsManager;
let session: AgentSession | undefined;
let integrations: Integrations;
let container: Container;
let skills: Skills;
let templates: Templates;
let checkpoints: Checkpoints;
let runner: Runner;
let mcp: Mcp;
let customProviders: CustomProviders;
let sync: GitHubSync;
let subagents: SubagentManager;
let jobs: Jobs;
let router: Router;
let fsService: Fs;
let preview: Preview;
/** Server only: hourly encrypted backups for the phone to keep (autobackup.ts). */
let autoBackup: AutoBackup | undefined;
const tunnels = new Tunnels();
let unsubscribe: (() => void) | undefined;

const guard = new Guard({
	send: (r) => send(r),
	checkpoint: async (cwd, label) => {
		await checkpoints.snapshot(cwd, label);
	},
	cwd: () => session?.sessionManager.getCwd() ?? workspace,
});

// ---------------------------------------------------------------------------
// Output

function argValue(name: string): string | undefined {
	const i = process.argv.indexOf(name);
	return i >= 0 ? process.argv[i + 1] : undefined;
}

/**
 * Set when the host runs as a daemon on a server (server mode, see server_agent.md): it listens on this unix socket
 * and outlives its clients, which reach it over ssh. Unset on the phone, where the app spawned this process and talks
 * to it over stdin/stdout exactly as before.
 */
const listenPath = argValue("--listen") ?? process.env.GRIPHUB_LISTEN;

/** "server" on a VPS, "phone" in the app's own process. A daemon is a server unless told otherwise. */
const mode = process.env.GRIPHUB_MODE ?? (listenPath ? "server" : "phone");

/** A server agent: the daemon on a VPS. Everything that differs from the phone hangs off this. */
const server = mode === "server";

/** Where the host keeps its own small files on a server (`running` marker, the box). */
const griphubDir = process.env.GRIPHUB_DIR ?? join(process.env.HOME ?? agentDir, ".griphub");
/** Exists while the daemon runs and is removed by a clean shutdown; finding it at start means the last one crashed. */
const runningMarker = join(griphubDir, "running");

/** The `.stamp` next to this host (written with the agent bundle), or undefined when there is none. */
function bundleStamp(): string | undefined {
	try {
		return readFileSync(join(fileURLToPath(new URL(".", import.meta.url)), ".stamp"), "utf8").trim() || undefined;
	} catch {
		return undefined;
	}
}

/** The folder this host runs from (its `.stamp`, `skills/` and, on a server, `launcher/` are next to it). */
const hostDir = fileURLToPath(new URL(".", import.meta.url));

/** The bundle this process started from. The `.stamp` on disk may already be a newer one that is waiting for a restart. */
const runningStamp = bundleStamp();

/**
 * Sends the host's records to the app. On the phone that is stdout, as always (no numbering, no buffer). As a daemon
 * the hub numbers what is worth replaying and keeps it, so an app that lost its connection gets exactly what it
 * missed (transport.ts).
 */
const hub = new Hub({
	replay: !!listenPath,
	mode,
	hostVersion: VERSION,
	bundleStamp: runningStamp,
	handle: (cmd) => handle(cmd as Command),
	// Only tests shorten these.
	pingIntervalMs: Number(process.env.GRIPHUB_PING_MS) || undefined,
	idleTimeoutMs: Number(process.env.GRIPHUB_IDLE_MS) || undefined,
});
// The app that spawned us is connected from the first byte, so early records reach it.
const stdio = listenPath ? undefined : hub.attach(stdioConn());

function send(record: object) {
	hub.emit(record);
	if (server) notifyFor(record as Record<string, any>);
}

/** The launcher that runs bash inside the rootless container on a server (server/box/box). */
const boxScript = process.env.GRIPHUB_BOX ?? join(griphubDir, "bin", "box");
/** The rootless container the agent's shell runs in on a server. The phone's container is container.ts (proot). */
const box = new PodmanBox({ script: boxScript, griphubDir });

const envBytes = (name: string) => {
	const n = Number(process.env[name]);
	return Number.isFinite(n) && n > 0 ? n : undefined;
};

/** Disk and memory. On a server a nearly full disk refuses new work; on a phone it is only reported. */
const health = new Health({
	path: workspace,
	enforce: server,
	limits: {
		diskWarnBytes: envBytes("GRIPHUB_DISK_WARN_BYTES") ?? DEFAULT_HEALTH_LIMITS.diskWarnBytes,
		diskMinBytes: envBytes("GRIPHUB_DISK_MIN_BYTES") ?? DEFAULT_HEALTH_LIMITS.diskMinBytes,
		memoryWarnBytes: envBytes("GRIPHUB_MEMORY_WARN_BYTES") ?? DEFAULT_HEALTH_LIMITS.memoryWarnBytes,
	},
	// Only a server tells anyone about it: on the phone `health` answers when asked, and nothing else changes.
	onChange: server ? reportHealth : undefined,
});

/**
 * Pushes to the phone through ntfy when nobody is looking at the app (notify.ts). Server only: on the phone the app
 * makes its own notifications, and it is the app that is closed. Titles are generic, with nothing of the work in them.
 */
const notifier = new Notifier({
	config: () => (server ? (integrations?.notifyConfig() ?? null) : null),
	shouldSend: () => !hub.hasClient() || hub.clientInBackground(),
	log: (m) => log(m),
});

function reportHealth(c: HealthChange) {
	if (c.what === "disk") {
		if (c.to === "ok") {
			send({ type: "notice", message: `Disk space is back to normal (${humanBytes(c.freeBytes)} free).` });
			return;
		}
		const critical = c.to === "critical";
		send({
			type: "notice",
			message: critical
				? `The disk is almost full (${humanBytes(c.freeBytes)} free). New prompts and tasks are refused until space is freed.`
				: `Disk space is getting low (${humanBytes(c.freeBytes)} free).`,
		});
		void notifier.send("disk", critical ? "Disk is almost full" : "Disk space is low", { priority: critical ? 5 : 4, tags: ["warning"] });
	} else if (c.to === "high") {
		send({ type: "notice", message: `The host is using a lot of memory (${humanBytes(c.rssBytes)}).` });
		void notifier.send("memory", "Host memory is high", { priority: 3, tags: ["warning"] });
	}
}

/**
 * Pushes for what the app would have shown as a notification itself (agent, approvals, background tasks, subagents).
 * Every record passes through here on a server; the notifier drops what comes while someone is looking at the app.
 */
function notifyFor(record: Record<string, any>) {
	switch (record.type) {
		case "approval":
			void notifier.send("approval", "Approval needed", { priority: 4, tags: ["raised_hand"] });
			return;
		case "agent_done":
			if (!record.retrying) void notifier.send("agent_done", "Agent finished", { tags: ["white_check_mark"] });
			return;
		case "run_finished":
			if (record.run?.status === "done") void notifier.send("run_done", "Task finished", { tags: ["white_check_mark"] });
			else if (record.run?.status === "error") void notifier.send("run_error", "Task failed", { priority: 4, tags: ["x"] });
			return;
		case "subagent_finished": {
			// The same switches as the app's own subagent notifications (Settings → Subagents).
			const st = integrations?.settings ?? {};
			const rec = record.subagent ?? {};
			const limited = rec.status === "stopped" && ["time", "credit", "limit"].includes(rec.stopCode);
			if (rec.status === "done" && st.subagentNotifyDone !== false) {
				void notifier.send("subagent_done", "Subagent finished", { tags: ["white_check_mark"] });
			} else if ((rec.status === "failed" || limited) && st.subagentNotifyFailed !== false) {
				void notifier.send("subagent_failed", limited ? "Subagent hit its limit" : "Subagent failed", { priority: 4, tags: ["x"] });
			}
			return;
		}
		case "job":
			if (record.job?.status === "done") void notifier.send("job_done", "Background job finished", { tags: ["white_check_mark"] });
			else if (record.job?.status === "failed" || record.job?.status === "timeout") {
				void notifier.send("job_failed", "Background job failed", { priority: 4, tags: ["x"] });
			}
			return;
		case "subagent_approval_request":
			if (integrations?.settings.subagentNotifyApproval !== false) {
				void notifier.send("subagent_approval", "Subagent needs approval", { priority: 4, tags: ["raised_hand"] });
			}
			return;
	}
}

function log(...args: unknown[]) {
	process.stderr.write(`${args.map(String).join(" ")}\n`);
}

/**
 * An assistant message as the app gets it: a copy with `griphubCost`, the estimate for that model request
 * (pricing.ts), so the chat can total a turn. A copy, because pi persists the original to the session file.
 */
function withCost(m: any) {
	return m?.role === "assistant" ? { ...m, griphubCost: messageCost(m) } : m;
}

/**
 * What a summary of older turns cost (it is a model request too), as `griphubCost` on its result. Its request has
 * no model of its own on record: it ran on the chat's model ([model]).
 */
function summaryCost(usage: any, model: { provider?: string; id?: string } | undefined) {
	return usage && model ? messageCost({ role: "assistant", usage, provider: model.provider, model: model.id }) : null;
}

/** Drop cumulative snapshots from streaming updates, like pi's JSON mode. */
function wireEvent(event: AgentSessionEvent): object {
	if (event.type === "message_end") return { ...event, message: withCost((event as any).message) };
	if (event.type === "compaction_end" && (event as any).result?.usage) {
		const result = (event as any).result;
		event = { ...event, result: { ...result, griphubCost: summaryCost(result.usage, session?.model) } } as AgentSessionEvent;
	}
	// A summary the host started for the context limit (capContext) says so, with the limit, rather than "manual".
	if ((event.type === "compaction_start" || event.type === "compaction_end") && capping) {
		return { ...event, reason: "limit", limit: compactAt() };
	}
	if (event.type === "message_update") {
		const { message: _message, assistantMessageEvent, ...rest } = event as any;
		const { partial, ...delta } = assistantMessageEvent ?? {};
		// Tool-call deltas don't name their tool; lift id and name from the snapshot.
		const block = delta.type?.startsWith("toolcall_") ? partial?.content?.[delta.contentIndex] : undefined;
		if (block?.type === "toolCall") Object.assign(delta, { id: block.id, toolName: block.name });
		return { ...rest, assistantMessageEvent: delta };
	}
	return event;
}

// ---------------------------------------------------------------------------
// Sessions

function modelInfo(model: any) {
	if (!model || model.provider === "unknown") return null;
	// GripHub pricing for the picker: rate, per-request floor, promo, status.
	const griphub = model.provider === GRIPHUB_ID && router;
	const rate = griphub ? router.rate(model.id) : undefined;
	return {
		provider: model.provider,
		id: model.id,
		name: model.name ?? model.id,
		reasoning: !!model.reasoning,
		contextWindow: model.contextWindow ?? null,
		maxTokens: model.maxTokens ?? null,
		input: model.input ?? ["text"],
		...(griphub && {
			pricing: {
				credits: rate?.credits ?? null,
				list: rate?.list ?? null,
				promo: rate?.promo ?? null,
				promoEndsAt: rate?.promoEndsAt ?? null,
				floor: router.floor(model.id) ?? null,
				available: router.modelAvailable(model.id),
			},
		}),
	};
}

/** Image models a key fetched before they were filtered out must not be offered for chat. */
function isChatModel(m: any) {
	return !(m?.provider === GRIPHUB_ID && router?.rate(m.id)?.perImage);
}

function state() {
	const s = session!;
	return {
		model: modelInfo(s.model),
		thinkingLevel: s.thinkingLevel,
		thinkingLevels: s.getAvailableThinkingLevels(),
		isStreaming: s.isStreaming,
		sessionId: s.sessionId,
		sessionFile: s.sessionFile ?? null,
		sessionName: s.sessionName ?? null,
		cwd: s.sessionManager.getCwd(),
		billingNotice: billingNotice(),
		planMode: guard.planMode,
		approvalMode: guard.mode,
		// How long the running turn has taken so far, by this host's clock (the app counts on from there).
		turnElapsedMs: turnStartedAt === null ? null : Date.now() - turnStartedAt,
	};
}

/** Every session (chat or background run) is built the same way. */
async function buildSession(
	sessionManager: SessionManager,
	opts: { interactive: boolean; onLimit: (reason: string) => void; unattended?: Guard },
) {
	const cwd = sessionManager.getCwd();
	const resourceLoader = new DefaultResourceLoader({
		cwd,
		agentDir,
		settingsManager,
		// Limits come first, so a call past a limit is refused before it asks for approval.
		// Approvals and plan mode only make sense with someone watching.
		extensionFactories: [
			{ name: "griphub-limits", factory: limitsExtension({ budgetError, stopped: opts.onLimit }), hidden: true },
			...(opts.interactive ? [{ name: "griphub", factory: guard.extension, hidden: true }] : []),
			// A server's background runs go on while nobody is there: what would need approval is refused instead.
			...(opts.unattended ? [{ name: "griphub-unattended", factory: opts.unattended.extension, hidden: true }] : []),
		],
	});
	await resourceLoader.reload();
	const mcpTools = mcp.toolDefinitions();
	const result = await createAgentSession({
		cwd,
		agentDir,
		modelRuntime,
		settingsManager,
		sessionManager,
		resourceLoader,
		// "subagent" must be named here: the SDK drops custom tools whose
		// name is not in this allow-list (that is why 1.0.42 never showed it).
		tools: [...TOOLS, ...(opts.interactive ? ["subagent", "background_job"] : []), ...mcpTools.map((t) => t.name)],
		customTools: [
			...webTools(
				() => ({
					...integrations.searchKeys(),
					// The router search backends reuse the saved GripHub key with the dedicated
					// search models from settings (not the conversation's model). The callback
					// runs per tool call, so it always reads the current settings.
					griphubKey: customProviders?.key(GRIPHUB_ID) ?? "",
					griphubBaseUrl: GRIPHUB_BASE_URL,
					activeModel: session?.model?.id ?? "",
				}),
				() => sessionManager.getCwd(),
			),
			todoTool(),
			...mcpTools,
			// The parent's only way to create a subagent. Interactive sessions
			// only: background runs and subagent sessions never get this tool,
			// so a subagent can never spawn another one.
			...(opts.interactive ? [subagentTool(subagents, () => currentParent())] : []),
			// Long commands the chat does not wait for; their result calls the chat back (jobs.ts, deliverJobs).
			...(opts.interactive ? [jobTool(jobs, () => currentParent())] : []),
		] as any,
	});
	// Some models send "None" or numbers-as-strings for tool arguments.
	installLenientTools(result.session.agent);
	return result;
}

/** The open chat, as a subagent's parent. Read lazily: the tool runs later. */
function currentParent(title?: string): SubagentParent {
	const s = session!;
	return {
		sessionFile: s.sessionFile ?? s.sessionId,
		title: title ?? s.sessionName ?? "",
		cwd: s.sessionManager.getCwd(),
		modelId: (s.model as any)?.id ?? "",
	};
}

/**
 * One subagent's session: same pi machinery as buildSession, but a restricted
 * tool registry (no subagent tool, no todo state, no MCP), an in-memory
 * session manager (no file that could surface as a chat), and its own guard
 * and limit instances. The parent's model carries over so cost estimates and
 * behaviour match the chat that spawned it.
 */
async function buildSubagentSession(opts: SubagentSessionFactoryOptions) {
	const { cwd, profile, guard: subGuard, budgetExtension, onLimit, parent } = opts;
	// Like a prompt: no new work on a server whose disk is nearly full. The subagent then fails with the reason.
	await health.assertRoom();
	const resourceLoader = new DefaultResourceLoader({
		cwd,
		agentDir,
		settingsManager,
		extensionFactories: [
			{ name: "griphub-limits", factory: limitsExtension({ budgetError, stopped: onLimit }), hidden: true },
			{ name: "griphub-subagent-guard", factory: subGuard.extension, hidden: true },
			{ name: "griphub-subagent-budget", factory: budgetExtension, hidden: true },
		],
	});
	await resourceLoader.reload();
	const parentModel =
		session?.model != null
			? modelRuntime.getModel((session.model as any).provider, (session.model as any).id)
			: undefined;
	const result = await createAgentSession({
		cwd,
		agentDir,
		modelRuntime,
		settingsManager,
		sessionManager: SessionManager.inMemory(cwd),
		resourceLoader,
		tools: profile === "full" ? FULL_TOOLS : READ_TOOLS,
		customTools: [
			...webTools(
				() => ({
					...integrations.searchKeys(),
					griphubKey: customProviders?.key(GRIPHUB_ID) ?? "",
					griphubBaseUrl: GRIPHUB_BASE_URL,
					activeModel: parent.modelId,
				}),
				() => cwd,
			),
		] as any,
		...(parentModel ? { model: parentModel } : {}),
		...(session?.thinkingLevel ? { thinkingLevel: session.thinkingLevel } : {}),
	});
	installLenientTools(result.session.agent);
	return result.session;
}

/** The last prompt sent from the app until it reaches the history, so Try again can send it once more. */
let lastPrompt: { text: string; images?: any[]; sessionId: string } | null = null;
let fallbackTried = false;
/** A fallback model is about to continue the failed turn; the turn is not over for the app's purposes. */
let fallbackPending = false;

/** Said when a chat switch would drop a running turn; the app matches it to offer "Stop and switch". */
const BUSY_SWITCH = "The agent is still working in this chat. Stop it before switching chats.";

/**
 * Switching chats disposes the open session. While it streams that silently
 * killed the running turn (the user tapped another chat, the reply was just
 * gone), so every switch now refuses until the turn is stopped.
 */
function assertIdle() {
	if (session?.isStreaming || fallbackPending) throw new Error(BUSY_SWITCH);
}

/** Follow-ups queued while the agent works (promptqueue.ts). */
const promptQueue = new PromptQueue(
	(items) => send({ type: "prompt_queue", sessionId: session?.sessionId ?? null, items }),
	(message) => send({ type: "error", message }),
);

/** One chat switch or rebuild at a time (sessionswap.ts). */
const oneSwitch = serialQueue();

function openSession(sessionManager: SessionManager) {
	return oneSwitch(async () => {
		// The new session is built before the old one is let go of: a build that fails leaves the open chat as it was.
		let modelFallbackMessage: string | undefined;
		await swapSession({
			assertIdle,
			build: async () => {
				const result = await buildSession(sessionManager, {
					interactive: true,
					onLimit: (reason) => send({ type: "notice", message: reason }),
				});
				modelFallbackMessage = result.modelFallbackMessage;
				return result.session;
			},
			retire: () => {
				unsubscribe?.();
				guard.cancelAll();
				session?.dispose();
				turnStartedAt = null;
				// Queued follow-ups belong to the chat being left (pi drops them with it).
				promptQueue.clear();
			},
			install: (next) => {
				session = next;
				unsubscribe = next.subscribe((event) => {
					send({ type: "event", event: wireEvent(event) });
					onSessionEvent(event);
				});
			},
		});
		if (modelFallbackMessage) send({ type: "notice", message: modelFallbackMessage });
		// Jobs of this chat that ended while another chat was open call it back now (after this command has answered).
		setTimeout(deliverJobs, 0);
		return state();
	});
}

/** Hooks on the active chat: model fallback and "done" notifications. */
function onSessionEvent(event: AgentSessionEvent) {
	if ((event as any).type === "queue_update") promptQueue.sync(((event as any).followUp ?? []).length);
	// A turn that ends with nothing running drops what was still waiting (abort).
	if ((event as any).type === "agent_settled" && !session?.isStreaming) {
		promptQueue.sync(session?.getFollowUpMessages().length ?? 0);
	}
	if (event.type === "message_start" && lastPrompt) {
		const m = (event as any).message;
		if (m?.role === "user" && messageText(m).includes(lastPrompt.text)) lastPrompt = null;
	}
	if (event.type === "message_end") {
		const m = (event as any).message;
		if (m?.role === "assistant" && m.stopReason === "error") void tryFallback(String(m.errorMessage ?? ""));
	}
	if (event.type === "agent_start" && turnStartedAt === null) turnStartedAt = Date.now();
	if (event.type === "agent_end" || (event as any).type === "agent_settled") {
		const text = session?.getLastAssistantText?.() ?? "";
		const over = (event as any).type === "agent_settled" && !session?.isStreaming && !fallbackPending;
		const turnMs = over && turnStartedAt !== null ? Date.now() - turnStartedAt : undefined;
		if (over) {
			if (turnMs !== undefined) recordTurnTime(turnMs);
			turnStartedAt = null;
		}
		send({
			type: "agent_done",
			sessionFile: session?.sessionFile ?? null,
			preview: text.slice(0, 200),
			// A fallback model is taking over (or already running): not finished, and not failed.
			retrying: fallbackPending || !!session?.isStreaming,
			...(turnMs !== undefined && { turnMs }),
		});
		// Sync a little after the turn, so a quick follow-up doesn't cause two pushes.
		sync?.schedule(90_000);
		// Past the context limit the chat is summarized first; then a job that ended while this turn ran calls it back.
		// Out of pi's agent_settled emission: compaction must not start inside it.
		if (over) setTimeout(() => void capContext().finally(deliverJobs), 0);
	}
}

// ---------------------------------------------------------------------------
// Keeping the context in bounds

/** The summary the host started itself, while it runs: prompts and job callbacks wait for it. */
let capping: Promise<void> | null = null;

/** The context limit in force: the user's, or the default share of the open chat's model window; 0 leaves it to pi. */
function compactAt(): number {
	return compactLimit(integrations?.settings.compactAt, session?.getContextUsage()?.contextWindow);
}

/**
 * Summaries that left the chat over the limit (they failed, or the router refused them): which chat, at how many
 * tokens the last one was, and how many in a row. Each try is a paid request, and a chat whose summary keeps failing
 * used to buy one after every turn until the daily budget was gone. Now it is tried again only once the chat has grown
 * by a quarter since, and not at all after CAP_MAX_FAILURES in a row (pi's own summary near the model's limit still
 * stands behind it).
 */
let capFailed: { chat: string; tokens: number; count: number } | null = null;

/** How much a chat must grow after a failed summary before it is tried again. */
const CAP_RETRY_GROWTH = 1.25;

/** Failed summaries in a row after which the chat is left to pi's own. */
const CAP_MAX_FAILURES = 3;

/**
 * Summarizes the open chat when its context passed the limit and the model allows more than that (pi itself only
 * compacts near the model's limit). Between turns only, never past the daily budget (a summary is a request too); a
 * failure is said by the compaction_end the app gets, and pi's own compaction stays as the safety net.
 */
async function capContext() {
	const s = session;
	if (!s || s.isStreaming || s.isCompacting || fallbackPending || capping) return;
	const usage = s.getContextUsage();
	const limit = compactLimit(integrations?.settings.compactAt, usage?.contextWindow);
	if (!limit || !usage?.tokens || usage.contextWindow <= limit || usage.tokens <= limit) return;
	const chat = s.sessionFile ?? s.sessionId;
	if (capFailed?.chat === chat && (capFailed.count >= CAP_MAX_FAILURES || usage.tokens < capFailed.tokens * CAP_RETRY_GROWTH)) return;
	// pi keeps the newest turns as they are (keepRecentTokens); with no more than that in the chat (the rest is the
	// system prompt) there is nothing to summarize, and trying would only report a failure.
	const keep = settingsManager.getCompactionSettings(s.model).keepRecentTokens;
	const said = (s.messages as any[]).filter((m) => m.role !== "system").reduce((n, m) => n + estimateTokens(m), 0);
	if (said <= keep + 4_000) return;
	if (budgetError()) return;
	capping = s
		.compact()
		.then(() => {})
		.catch((e) => log("compact:", (e as Error).message))
		.finally(() => {
			// Judged by the outcome, not by whether compact() threw: a summary pi reports as failed or aborted leaves the
			// chat as big as it was.
			const after = s.getContextUsage()?.tokens;
			const failedBefore = capFailed?.chat === chat ? capFailed.count : 0;
			capFailed = after == null || after > limit ? { chat, tokens: usage.tokens!, count: failedBefore + 1 } : null;
			capping = null;
		});
	await capping;
}

/** Waits while the open chat is being summarized (pi refuses a prompt meanwhile), up to five minutes. */
async function compactionDone(s: AgentSession) {
	if (capping) await capping;
	for (let waited = 0; s.isCompacting && waited < 300_000; waited += 200) await new Promise((r) => setTimeout(r, 200));
}

// ---------------------------------------------------------------------------
// How long turns take, and background jobs calling their chat back

/** When the open chat's running turn began (its first agent_start), or null between turns. */
let turnStartedAt: number | null = null;

/** Session entry type that keeps a turn's duration with the chat. It is not a message: the model never sees it. */
const TURN_TIME = "griphub_turn";

/** Keeps how long the turn took next to its last reply, so the chat shows it again when reopened. */
function recordTurnTime(ms: number) {
	const s = session;
	const last = (s?.messages as any[] | undefined)?.findLast((m) => m.role === "assistant");
	if (!s || !last?.timestamp) return;
	try {
		s.sessionManager.appendCustomEntry(TURN_TIME, { at: last.timestamp, ms });
	} catch (e) {
		log("turn time:", (e as Error).message);
	}
}

/**
 * The open chat's turns that the latest summary replaced, oldest first. pi keeps them in the chat's file but no longer
 * sends them to the model, and `messages` (the model's context) has only the summary in their place: without this
 * they could not be read again, in the app or in an export. Empty for a chat never summarized.
 */
function summarizedMessages(s: AgentSession): any[] {
	const branch = s.sessionManager.getBranch() as any[];
	const last = branch.findLastIndex((e) => e.type === "compaction");
	if (last < 0) return [];
	const out: any[] = [];
	for (const e of branch.slice(0, last)) {
		if (e.id === branch[last].firstKeptEntryId) break;
		// Earlier summaries are left out: the turns they stood for are in the list themselves.
		if (e.type === "message" || e.type === "custom_message") out.push(...sessionEntryToContextMessages(e));
	}
	return out.filter((m) => m.role !== "system");
}

/** What the latest summary of the open chat cost, for the line that stands for it when the chat is opened again. */
function latestSummaryCost(s: AgentSession) {
	const branch = s.sessionManager.getBranch() as any[];
	const at = branch.findLastIndex((e) => e.type === "compaction");
	if (at < 0 || !branch[at].usage) return null;
	// The model it ran on: the chat's, as of the last reply before it.
	const reply = branch.slice(0, at).findLast((e) => e.type === "message" && e.message?.role === "assistant")?.message;
	return summaryCost(branch[at].usage, reply ? { provider: reply.provider, id: reply.model } : s.model);
}

/** Turn durations of the open chat, by the timestamp of each turn's last reply. */
function turnTimes(s: AgentSession): Map<number, number> {
	const out = new Map<number, number>();
	for (const e of s.sessionManager.getBranch() as any[]) {
		if (e.type === "custom" && e.customType === TURN_TIME && typeof e.data?.at === "number") out.set(e.data.at, e.data.ms);
	}
	return out;
}

/** Message type of a job's result in the chat: shown by the app as a notice, read by the model as a message. */
const JOB_MESSAGE = "griphub_job";

/** Jobs that ended and have not called their chat back yet (it was busy, or another chat was open). */
const finishedJobs: JobRecord[] = [];

/** How many turns in a row job callbacks may start with no word from the user; then the results only land in the chat. */
const JOB_CHAIN_LIMIT = 5;

/** Job-callback turns since the user last said something (host.ts "prompt" resets it). */
let jobChain = 0;

/**
 * Whether a deliverJobs is under way. It is called from a job ending, from a turn ending and from a timer, and it
 * awaits in the middle; a job leaves the queue only once sent, so two overlapping runs would send it twice.
 */
let deliveringJobs = false;

/** A call came in while one was under way: the running one goes round once more. */
let deliverAgain = false;

/**
 * Calls the open chat back with the jobs of it that ended, once it is idle: one turn for all of them, with no message
 * from the user. Waits while it works (its turn ends first) and while another chat is open (it is called back when it
 * is opened again). Never past the daily budget, onto a full disk, or past JOB_CHAIN_LIMIT turns with no word from the
 * user: the results are then added without a turn, and the user is told why the agent did not go on.
 */
async function deliverJobs() {
	if (deliveringJobs) {
		// One is under way: it looks again before it ends, so a job that ended just now is not missed.
		deliverAgain = true;
		return;
	}
	deliveringJobs = true;
	try {
		do {
			deliverAgain = false;
			await deliverFinishedJobs();
		} while (deliverAgain);
	} finally {
		deliveringJobs = false;
	}
}

/** The body of [deliverJobs]; it loops until nothing of the open chat is left, so a job that ends meanwhile is sent too. */
async function deliverFinishedJobs() {
	const s = session;
	// While the chat is summarized: capContext delivers when it is done.
	if (!s || s.isStreaming || s.isCompacting || capping || fallbackPending) return;
	const key = s.sessionFile ?? s.sessionId;
	if (!finishedJobs.some((j) => j.sessionFile === key)) return;
	let held = budgetError();
	if (!held) {
		try {
			await health.assertRoom();
		} catch (e) {
			held = (e as Error).message;
		}
	}
	if (!held && jobChain >= JOB_CHAIN_LIMIT) held = `it already went on ${jobChain} times since your last message`;
	// One at a time, each taken off the queue only once it was sent: when a send fails, the rest stay queued and are
	// delivered on the next try (they used to be dropped with it).
	let started = false;
	for (;;) {
		const at = finishedJobs.findIndex((j) => j.sessionFile === key);
		if (at < 0) break;
		const job = finishedJobs[at];
		const lastOne = !finishedJobs.some((j, i) => i > at && j.sessionFile === key);
		try {
			await s.sendCustomMessage(
				{ customType: JOB_MESSAGE, content: jobReport(job), display: true, details: { job: jobWire(job) } },
				{ triggerTurn: lastOne && !held },
			);
		} catch (e) {
			send({ type: "error", message: `Could not continue after the background job: ${(e as Error).message}` });
			return;
		}
		finishedJobs.splice(at, 1);
		if (lastOne && !held) started = true;
	}
	if (started) jobChain++;
	else if (held) send({ type: "notice", message: `The background job ended, but the agent did not continue: ${held}` });
}

function messageText(m: any): string {
	return typeof m?.content === "string"
		? m.content
		: (m?.content ?? []).map((c: any) => (c.type === "text" ? c.text : "")).join("");
}

async function tryFallback(error: string) {
	const chain = integrations.settings.fallbackModels ?? [];
	if (!chain.length || fallbackTried || !session) return;
	if (!/rate|limit|quota|overload|429|5\d\d|unavailable|insufficient|credit|exceeded|timeout/i.test(error)) return;
	const current = `${session.model?.provider}/${session.model?.id}`;
	const next = chain.find((f) => `${f.provider}/${f.model}` !== current);
	const model = next && modelRuntime.getModel(next.provider, next.model);
	if (!model) return;
	// The continuation is a new request, so it needs budget like any other.
	const overBudget = budgetError();
	if (overBudget) return send({ type: "notice", message: overBudget });
	fallbackTried = true;
	fallbackPending = true;
	// The chat that failed. setModel awaits; if another chat opened meanwhile,
	// the global `session` is that other chat, and the fallback used to switch
	// ITS model and send it "Continue where you left off".
	const failed = session;
	try {
		await failed.setModel(model, { persist: false });
		if (session !== failed) return;
		send({ type: "notice", message: `Switched to ${model.name ?? model.id} after an error: ${error.slice(0, 120)}` });
		send({ type: "state", state: state() });
		failed.prompt("Continue where you left off (the previous model failed).").catch(() => {});
	} finally {
		fallbackPending = false;
	}
}

/** Estimated GripHub credits of one pi usage record (rate + floor + cache, see router.ts). */
function estimateUsage(model: string, u: any): number | null {
	return requestEstimate(model, usageOf(u));
}

/**
 * Today's spend in GripHub credits (WIB day): the router's own total from the
 * last refresh (at most a minute old), plus local estimates for this app's
 * requests since that refresh. With no router data yet (offline, no key),
 * the local estimate for the whole day. Refreshes in the background so a
 * prompt never waits on the network.
 */
function spentToday(): { credits: number; real: boolean } {
	void router.refreshToday(60_000).catch(() => {});
	const today = router.today();
	const sessions = join(agentDir, "sessions");
	const day = wibDay(Date.now());
	const local = (from?: number) =>
		usageSummary(sessions, 1, estimateUsage, from)
			.filter((r) => r.day === day)
			.reduce((sum, r) => sum + (r.credits ?? 0), 0);
	// Subagents run on in-memory sessions (no chat file): their spend since the
	// router snapshot is counted from their own running totals.
	const subs = (from: number) =>
		subagents
			.list()
			.filter((r) => (r.finishedAt ?? Date.now()) >= from && r.credits !== null)
			.reduce((sum, r) => sum + (r.credits ?? 0) * subagentShareSince(r, from), 0);
	if (!today) return { credits: local() + subs(Date.parse(`${day}T00:00:00+07:00`)), real: false };
	return { credits: today.credits + local(today.fetchedAt) + subs(today.fetchedAt), real: true };
}

/** The part of a subagent's spend that falls after [from] (linear over its run). */
function subagentShareSince(r: { startedAt?: number; finishedAt?: number }, from: number): number {
	const start = r.startedAt ?? Date.now();
	const end = r.finishedAt ?? Date.now();
	if (start >= from) return 1;
	if (end <= from) return 0;
	return (end - from) / Math.max(1, end - start);
}

/**
 * GripHub's model list, refreshed from /v1/models with the saved key. The
 * open chat keeps its model definition in step (limits, reasoning). Returns
 * what changed; throws without a key or on a network error.
 */
async function refreshGripHubModels() {
	const key = customProviders.key(GRIPHUB_ID);
	if (!key) throw new Error("No GripHub key saved");
	const before = new Set(customProviders.list().find((p) => p.id === GRIPHUB_ID)?.models.map((m) => m.id) ?? []);
	const models = await fetchModels(GRIPHUB_API, GRIPHUB_BASE_URL, key);
	customProviders.save({ id: GRIPHUB_ID, apiKey: "", models }, new Set());
	await modelRuntime.refresh({ allowNetwork: false });
	const s = session;
	if (s?.model?.provider === GRIPHUB_ID) {
		const fresh = modelRuntime.getModel(GRIPHUB_ID, s.model.id);
		if (fresh && !s.isStreaming) {
			const level = s.thinkingLevel;
			await s.setModel(fresh);
			s.setThinkingLevel(level);
		}
	}
	const after = new Set(models.map((m) => m.id));
	return {
		count: models.length,
		added: [...after].filter((id) => !before.has(id)),
		removed: [...before].filter((id) => !after.has(id)),
		refreshedAt: Date.now(),
	};
}

/** Refuses new work once today's spend reaches the configured cap (Settings → Usage). */
function budgetError(): string | null {
	const cap = integrations.settings.dailyBudget ?? 0;
	if (!cap) return null;
	const { credits } = spentToday();
	return credits >= cap
		? `Daily budget of ${cap} credits reached (${credits.toFixed(2)} credits spent today). Raise it in Settings → Usage.`
		: null;
}

/** What the user asked for lately in this chat, newest last, for a commit message to say why. */
function recentAsks(s: AgentSession, n = 3): string[] {
	const out: string[] = [];
	for (const m of s.messages as any[]) {
		if (m.role !== "user") continue;
		const text = typeof m.content === "string" ? m.content : (m.content ?? []).filter((c: any) => c.type === "text").map((c: any) => c.text).join("\n");
		if (text.trim()) out.push(text.trim().slice(0, 600));
	}
	return out.slice(-n);
}

/**
 * A commit message for the project's uncommitted changes, written by the chat's model in one short request (no tools,
 * not part of the chat): a subject in the imperative under 72 characters, then a few lines on what and why, from the
 * diff and what the user asked for. Counts against the daily budget like anything else the model does.
 */
async function commitMessage(s: AgentSession, cwd: string): Promise<string> {
	checkBudget();
	const model = s.model;
	if (!model) throw new Error("Choose a model first.");
	const change = await gitops.changeSummary(cwd);
	if (!change) throw new Error("This folder is not a git repository.");
	if (change.files === 0) throw new Error("There is nothing to commit.");
	const asks = recentAsks(s);
	const prompt = [
		"Write a git commit message for the change below.",
		"First line: what the change does, in the imperative mood, under 72 characters, no trailing period.",
		"Then, only if it helps, a blank line and up to four short lines on what changed and why.",
		"Match the language of the user's requests. Reply with the message only: no quotes, no code fence, no preamble.",
		asks.length ? `\nWhat the user asked for:\n${asks.map((a) => `- ${a.replace(/\s+/g, " ")}`).join("\n")}` : "",
		`\nFiles changed:\n${change.stat || "(none tracked yet)"}`,
		change.untracked.length ? `\nNew files:\n${change.untracked.slice(0, 50).join("\n")}` : "",
		`\nDiff:\n${change.patch}`,
	].join("\n");
	const reply = await (s as any).modelRuntime.completeSimple(
		model,
		{ messages: [{ role: "user", content: [{ type: "text", text: prompt }], timestamp: Date.now() }] },
		{ maxTokens: 400, cacheRetention: "none" },
	);
	if (reply?.stopReason === "error") throw new Error(reply.errorMessage || "The model could not write a message.");
	const text = (reply?.content ?? []).filter((c: any) => c.type === "text").map((c: any) => c.text).join("").trim();
	const message = text.replace(/^```[a-z]*\n?|\n?```$/g, "").replace(/^["']|["']$/g, "").trim();
	if (!message) throw new Error("The model did not write a message.");
	return message;
}

function checkBudget() {
	const error = budgetError();
	if (error) throw new Error(error);
}

/** Mirrors pi's interactive warning: subscription OAuth outside Claude's own apps bills extra usage. */
function billingNotice(): string | null {
	if (session?.model?.provider !== "anthropic" || !modelRuntime.isUsingOAuth("anthropic")) return null;
	if (settingsManager.getWarnings().anthropicExtraUsage === false) return null;
	return "Claude subscription sign-in bills third-party apps like this one per token from extra usage, not your plan limits. Manage it at claude.ai/settings/usage, or use an API key.";
}

/**
 * Rebuilds the active session so tool settings (shell, MCP tools) take effect, in the folder the chat is in. pi writes
 * a chat's file only once it has a message, and opening a file that isn't there yet takes the process's own folder:
 * a new chat reopened that way (MCP coming up after start, a shell change) moved to wherever the host was started, a
 * server daemon's `/` or home, and the agent's files went there.
 */
async function reopenSession() {
	const s = session!;
	if (s.isStreaming) throw new Error("Wait for the agent to finish first");
	const file = s.sessionFile;
	const cwd = s.sessionManager.getCwd();
	await openSession(file ? SessionManager.open(file, undefined, cwd) : SessionManager.create(cwd));
}

/**
 * The guard for a server's background runs, which nobody is watching: risky commands and writes outside the project
 * are refused rather than asked about (guard.ts `deny_risky`). On the phone background runs have no guard, as before.
 */
function unattendedGuard(cwd: string): Guard {
	const g = new Guard({
		send: () => {},
		checkpoint: async (dir, label) => {
			await checkpoints.snapshot(dir, label);
		},
		cwd: () => cwd,
	});
	g.mode = "deny_risky";
	return g;
}

/** A headless session for the background runner. */
async function backgroundSession(cwd: string): Promise<RunSession> {
	let error: string | undefined;
	const { session: bg } = await buildSession(SessionManager.create(cwd || workspace), {
		interactive: false,
		onLimit: (reason) => (error = reason),
		unattended: server ? unattendedGuard(cwd || workspace) : undefined,
	});
	bg.subscribe((e) => {
		const m = (e as any).message;
		if (e.type === "message_end" && m?.role === "assistant" && m.stopReason === "error") error = m.errorMessage;
	});
	return {
		sessionFile: bg.sessionFile,
		prompt: async (text) => {
			checkBudget();
			await health.assertRoom();
			await bg.prompt(text);
		},
		lastText: () => bg.getLastAssistantText(),
		errorText: () => error,
		abort: () => bg.abort(),
		dispose: () => bg.dispose(),
	};
}

/** The agent's shell is the server's box (server only). */
/** The box, briefly, for the health card: is there one, is its image built, do the agent's commands go to it. */
async function boxHealth(): Promise<{ available: boolean; installed: boolean; enabled: boolean }> {
	const s = await box.status(settingsManager.getShellPath());
	return { available: s.available, installed: s.installed, enabled: s.enabled };
}

function boxIsShell(): boolean {
	return server && box.available && integrations?.settings.containerShell !== false;
}

/** Keeps the environment notes current (agents-file.ts), unless the user has taken the file over. */
function ensureAgentsFile() {
	const path = join(agentDir, "AGENTS.md");
	if (existsSync(path) && !isManaged(readFileSync(path, "utf8"))) return;
	writeFileSync(path, agentsFileText({ mode, workspace, box: boxIsShell() }));
}

// ---------------------------------------------------------------------------
// Login bridge: pi's AuthInteraction is forwarded to the app.

let nextAuthId = 1;
const pendingAuth = new Map<number, { resolve: (v: string) => void; reject: (e: Error) => void }>();

async function login(providerId: string, method: "api_key" | "oauth") {
	const controller = new AbortController();
	await modelRuntime.login(providerId, method, {
		signal: controller.signal,
		prompt: (prompt) =>
			new Promise<string>((resolve, reject) => {
				const authId = nextAuthId++;
				pendingAuth.set(authId, { resolve, reject });
				const { signal, ...rest } = prompt;
				signal?.addEventListener("abort", () => {
					pendingAuth.delete(authId);
					send({ type: "auth_dismiss", authId });
					reject(new Error("cancelled"));
				});
				send({ type: "auth_prompt", authId, provider: providerId, prompt: rest });
			}),
		notify: (event) => send({ type: "auth_event", provider: providerId, event }),
	});
}

async function providers() {
	const out = [];
	for (const p of modelRuntime.getProviders()) {
		// Locked build: pi's built-in providers are never surfaced to the app.
		if (!customProviders.ids().has(p.id)) continue;
		const auth = p.auth as any;
		out.push({
			id: p.id,
			name: p.name,
			configured: modelRuntime.hasConfiguredAuth(p.id),
			oauth: modelRuntime.isUsingOAuth(p.id),
			methods: [auth.apiKey?.login ? "api_key" : null, auth.oauth ? "oauth" : null].filter(Boolean),
			models: modelRuntime.getModels(p.id).length,
			custom: customProviders.ids().has(p.id),
		});
	}
	return out;
}

// ---------------------------------------------------------------------------
// Deleting chats and projects

const sessionsDir = () => resolve(agentDir, "sessions");
const within = (path: string, dir: string) => path === dir || path.startsWith(dir + sep);

/** Deletes chat files. The open chat is swapped for a fresh one first, in [cwd] or its own folder. */
async function deleteSessions(paths: string[], cwd?: string) {
	const s = session!;
	const files = paths.map((p) => resolve(p)).filter((p) => within(p, sessionsDir()) && p.endsWith(".jsonl"));
	const current = s.sessionFile ? resolve(s.sessionFile) : undefined;
	if (current && files.includes(current)) {
		if (s.isStreaming) throw new Error("Stop the agent before deleting the open chat");
		await openSession(SessionManager.create(cwd ?? s.sessionManager.getCwd()));
	}
	let deleted = 0;
	for (const f of files) {
		try {
			unlinkSync(f);
			deleted++;
		} catch {
			// Already gone.
		}
	}
	// A deleted chat's jobs die with it: nothing to call back, no records that outlive their chat. Job records carry
	// the session file as the chat gave it, so both sides are resolved before they are compared.
	const gone = new Set(files);
	for (const file of new Set(jobs.list().map((j) => j.sessionFile))) if (gone.has(resolve(file))) jobs.forgetSession(file);
	for (let i = finishedJobs.length - 1; i >= 0; i--) if (gone.has(resolve(finishedJobs[i].sessionFile))) finishedJobs.splice(i, 1);
	// And its subagents stop: their report would reach no one, and one still at work would go on changing files.
	subagents.stopForChats(gone, resolve);
	return { deleted, ...state() };
}

/** A project is a folder directly inside the workspace; nothing else may be deleted. */
function projectDir(path: string) {
	const dir = resolve(path);
	if (dirname(dir) !== resolve(workspace)) throw new Error("Only projects inside the workspace can be deleted");
	if (!existsSync(dir)) throw new Error("The project folder no longer exists");
	return dir;
}

/** What deleting a project would lose, and what stops it right now. */
async function projectDeleteCheck(path: string) {
	const dir = projectDir(path);
	const chats = (await SessionManager.listAll()).filter((i) => i.cwd && within(resolve(i.cwd), dir));
	const git = existsSync(join(dir, ".git"));
	const lines = async (args: string[]) =>
		(await gitRun(args, { cwd: dir }).catch(() => "")).split("\n").filter((l) => l.trim()).length;
	const blockers: string[] = [];
	const s = session!;
	if (s.isStreaming && within(resolve(s.sessionManager.getCwd()), dir)) blockers.push("The agent is working in this project");
	const { runs, schedules } = runner.summary();
	const busyRuns = runs.filter((r) => (r.status === "queued" || r.status === "running") && r.cwd && within(resolve(r.cwd), dir));
	if (busyRuns.length) blockers.push(`${busyRuns.length} background task(s) use this project`);
	const busySchedules = schedules.filter((x) => x.enabled && x.cwd && within(resolve(x.cwd), dir));
	if (busySchedules.length) blockers.push(`${busySchedules.length} schedule(s) use this project`);
	return {
		path: dir,
		chats: chats.length,
		git,
		// Uncommitted files, and commits on local branches that no remote has.
		changes: git ? await lines(["status", "--porcelain"]) : 0,
		unpushed: git ? await lines(["log", "--branches", "--not", "--remotes", "--format=%h"]) : 0,
		blockers,
	};
}

async function deleteProject(path: string, deleteChats: boolean) {
	const check = await projectDeleteCheck(path);
	if (check.blockers.length) throw new Error(check.blockers.join("; "));
	const dir = check.path;
	const s = session!;
	// Leave the project first so nothing keeps working in a folder that is about to vanish.
	if (within(resolve(s.sessionManager.getCwd()), dir)) {
		if (s.isStreaming) throw new Error("Stop the agent before deleting the project it is working in");
		await openSession(SessionManager.create(workspace));
	}
	let deletedChats = 0;
	if (deleteChats) {
		const files = (await SessionManager.listAll()).filter((i) => i.cwd && within(resolve(i.cwd), dir)).map((i) => i.path);
		deletedChats = (await deleteSessions(files, workspace)).deleted;
	}
	try {
		rmSync(dir, { recursive: true, force: true });
	} catch {
		// Tools in the container leave read-only folders (Go and npm caches); make them writable and retry.
		await run("chmod", ["-R", "u+rwX", dir], { cwd: workspace }).catch(() => "");
		rmSync(dir, { recursive: true, force: true });
	}
	checkpoints.forget(dir);
	return { deletedChats, ...state() };
}

// ---------------------------------------------------------------------------
// Backups

/**
 * Where a phone writes a backup that must survive the app: the shared Download folder (synced or copied off the
 * phone, it survives the phone too), or the workspace when Download cannot be written (no "all files" permission).
 */
function sharedBackupDir(): string {
	const shared = "/storage/emulated/0/Download";
	const dir = existsSync(shared) ? join(shared, "GripHub") : join(workspace, "backups");
	try {
		mkdirSync(dir, { recursive: true });
		writeFileSync(join(dir, ".probe"), "");
		unlinkSync(join(dir, ".probe"));
		return dir;
	} catch {
		mkdirSync(join(workspace, "backups"), { recursive: true });
		return join(workspace, "backups");
	}
}

/** The phone's automatic backups go next to the manual ones, in a folder of their own (pruning only ever deletes there). */
function phoneBackupDir(): string {
	return process.env.GRIPHUB_PHONE_BACKUP_DIR ?? join(sharedBackupDir(), "auto");
}

function backupTarget() {
	const stamp = new Date().toISOString().slice(0, 16).replace(/[-:T]/g, "");
	return join(sharedBackupDir(), `griphub-backup-${stamp}.zip`);
}

function createBackup(includeWorkspace: boolean) {
	// Secrets (provider keys, tokens) are left out on purpose: the agent side
	// only ever lists sessions/skills/prompts/settings/runs, and key material
	// lives in the encrypted griphub/ store, which is not listed here.
	const entries = [
		...collectFiles(join(agentDir, "sessions"), agentDir),
		...collectFiles(join(agentDir, "skills"), agentDir),
		...collectFiles(join(agentDir, "prompts"), agentDir),
		// pi's settings.json is NOT backed up: restore refuses it (a crafted file
		// could reconfigure the agent on another phone), so including it only
		// promised something a restore silently dropped.
		...["AGENTS.md", "griphub/runs.json"]
			.filter((f) => existsSync(join(agentDir, f)))
			.map((f) => ({ name: f, data: readFileSync(join(agentDir, f)) })),
	].map((e) => ({ name: `agent/${e.name}`, data: e.data }));
	if (includeWorkspace) {
		for (const e of collectFiles(workspace, workspace, new Set(["node_modules", ".git", "backups", ".venv", "venv"]))) {
			// Dotfiles and dot-dirs never enter a backup: a project .env (or
			// .npmrc, .aws/, ...) would otherwise leak secrets into the zip
			// and break the "keys are not included" promise above.
			if (e.name.split("/").some((s) => s.startsWith("."))) continue;
			entries.push({ name: `workspace/${e.name}`, data: e.data });
		}
	}
	const path = backupTarget();
	writeFileSync(path, writeZip(entries));
	return { path, files: entries.length };
}

/**
 * Agent-side paths a backup may restore. Everything else under agent/ is
 * refused: extensions are code, settings.json can redirect the agent, and
 * state files (mcp.json, custom-providers.json, models.json) would hand an
 * attacker servers, providers or models. The workspace side keeps its old
 * rule (any path without .. segments); project extensions there no longer
 * execute since project trust is off.
 */
const RESTORE_AGENT_ALLOW = [
	(rel: string) => rel === "AGENTS.md",
	(rel: string) => rel === "griphub/runs.json",
	(rel: string) => rel.startsWith("sessions/"),
	(rel: string) => rel.startsWith("skills/"),
	(rel: string) => rel.startsWith("prompts/"),
];

// Named apart from autobackup's restoreBackup (a server backup onto this phone), which host.ts also calls:
// the import used to be shadowed by this declaration, and backup_restore_server restored with the wrong one.
function restoreLocalBackup(path: string) {
	const entries = readZip(readFileSync(path));
	let restored = 0;
	let skipped = 0;
	for (const e of entries) {
		const [root, ...rest] = e.name.split("/");
		const rel = rest.join("/");
		if (!rel || rel.split("/").includes("..")) {
			skipped++;
			continue;
		}
		const base = root === "agent" ? agentDir : root === "workspace" ? workspace : null;
		if (!base) {
			skipped++;
			continue;
		}
		if (root === "agent" && !RESTORE_AGENT_ALLOW.some((f) => f(rel))) {
			skipped++;
			continue;
		}
		const target = join(base, rel);
		mkdirSync(dirname(target), { recursive: true });
		writeFileSync(target, e.data);
		restored++;
	}
	return { restored, skipped };
}

// ---------------------------------------------------------------------------
// Commands

/**
 * Commands that run git against github.com with the token in git's config. A
 * GitHub App sign-in expires every 8 hours, so it is refreshed first if due
 * (a no-op otherwise). API calls refresh on their own (Integrations.github).
 */
const GITHUB_GIT_COMMANDS = new Set(["git_clone", "git_fetch", "git_pull", "git_push", "deploy", "sync_now", "ci_watch", "run_enqueue", "schedule_run"]);

async function handle(cmd: Command): Promise<unknown> {
	// Files and previews need no session, and the app may ask for them while one is being opened.
	if (isFsCommand(cmd.type)) return runFsCommand(fsService, cmd);
	if (cmd.type === "preview_serve") return preview.serve(cmd.dir);
	if (cmd.type === "preview_stop") return { stopped: preview.stop(Number(cmd.port)) };
	const s = session!;
	const cwd = (cmd.dir as string | undefined) ?? s.sessionManager.getCwd();
	if (GITHUB_GIT_COMMANDS.has(cmd.type)) await integrations.githubFresh();
	switch (cmd.type) {
		case "hello":
			return {
				version: VERSION,
				node: process.version,
				agentDir,
				workspace,
				tools: s.getActiveToolNames(),
				mode,
				transport: listenPath ? "daemon" : "stdio",
				protocol: PROTOCOL,
				...state(),
			};
		case "state":
			return state();

		case "prompt": {
			// Remembered before anything can refuse it, so Try again knows what was asked.
			lastPrompt = { text: cmd.text, images: cmd.images, sessionId: s.sessionId };
			// The user spoke: job callbacks may start turns again (deliverJobs).
			jobChain = 0;
			checkBudget();
			// A server with a nearly full disk takes no new work (health.ts); on the phone this never refuses.
			await health.assertRoom();
			fallbackTried = false;
			// Plan mode: ask for a plan first; tools that change things are blocked (guard.ts).
			const text = guard.planMode
				? `${cmd.text}\n\n[Plan mode] Investigate as needed, then reply with a numbered plan only. Do not change files or run commands that modify anything until I approve.`
				: cmd.text;
			// The agent may git push from its shell; don't hold the prompt for it.
			void integrations.githubFresh();
			// The chat is being summarized: pi refuses prompts until it is done, so this one waits for it.
			if (!s.isStreaming) await compactionDone(s);
			// While the agent works, a follow-up waits for the turn's boundary; the
			// app shows it as a waiting bubble and can cancel it (prompt_queue_remove).
			const behavior = s.isStreaming ? (cmd.behavior ?? "followUp") : undefined;
			if (behavior === "followUp") {
				const id = await promptQueue.add(s, text, cmd.text, cmd.images);
				return id ? { queued: id } : null;
			}
			// Don't await the run; progress arrives as events.
			s.prompt(text, { images: cmd.images, streamingBehavior: behavior }).catch((e) =>
				send({ type: "error", message: String(e?.message ?? e) }),
			);
			return null;
		}
		case "retry": {
			// After a failed turn: continue it if the request made it into the history, else send the prompt again.
			if (s.isStreaming) throw new Error("The agent is still working");
			checkBudget();
			const last = (s.messages as any[]).at(-1);
			const failedTurn = last && (last.role === "user" || (last.role === "assistant" && last.stopReason === "error"));
			// The last prompt from this chat that never made it into the history (refused, or failed to start).
			const unsent = lastPrompt && lastPrompt.sessionId === s.sessionId ? lastPrompt : null;
			fallbackTried = false;
			if (unsent) {
				s.prompt(unsent.text, { images: unsent.images }).catch((e) =>
					send({ type: "error", message: String(e?.message ?? e) }),
				);
			} else if (failedTurn) {
				s.prompt("Continue where you left off (the previous request failed).").catch((e) =>
					send({ type: "error", message: String(e?.message ?? e) }),
				);
			} else {
				throw new Error("Nothing to retry");
			}
			return null;
		}
		case "prompt_queue":
			return promptQueue.list();
		case "prompt_queue_remove":
			// "queueId", not "id": every command's id is its request id.
			return promptQueue.remove(s, String(cmd.queueId ?? ""));
		case "steer":
			await s.steer(cmd.text);
			return null;
		case "abort":
			guard.cancelAll();
			await s.abort();
			return null;
		case "session_stats":
			return { ...s.getSessionStats(), context: s.getContextUsage() ?? null };

		// Approvals and plan mode (guard.ts).
		case "approval_reply":
			guard.reply(cmd.approvalId, !!cmd.allow, !!cmd.always, cmd.key);
			return null;
		// What is still waiting for an answer, chat and subagents alike: an app that reconnects shows these again.
		case "approvals_pending":
			return [...guard.pendingApprovals(), ...subagents.pendingApprovals()];

		// Background jobs (jobs.ts): the agent starts them with its `background_job` tool; the app lists and stops them.
		case "job_list":
			return jobs.list(cmd.sessionFile).map((j) => jobWire(j));
		case "job_stop":
			return jobWire(jobs.stop(String(cmd.jobId)));
		case "host_restart":
			if (!listenPath) throw new Error("Restarting is only available when the host runs as a daemon on a server");
			return restartGate.request(cmd.whenIdle !== false);

		// Subagents (subagent.ts). Creation is the parent model's job via the
		// `subagent` tool; these commands are the app's controls for a live
		// one (card, modal, queue, stop). They never create a chat.
		case "subagent_list":
			return subagents.list();
		case "subagent_start":
			return subagents.start(currentParent(cmd.parentTitle), cmd.task ?? cmd.brief ?? "", cmd.profile === "full" ? "full" : "read");
		case "subagent_stop":
			return subagents.stop(cmd.subagentId, !!cmd.force);
		case "subagent_queue":
			return subagents.queueMessage(cmd.subagentId, cmd.text ?? "");
		case "subagent_queue_remove":
			return subagents.removeQueued(cmd.subagentId, cmd.queueId);
		case "subagent_queue_move":
			return subagents.moveQueued(cmd.subagentId, cmd.queueId, cmd.direction === "down" ? "down" : "up");
		case "subagent_approval_reply":
			return subagents.approvalReply(cmd.subagentId, cmd.approvalId, !!cmd.allow, !!cmd.always, cmd.key);
		case "plan_mode":
			guard.planMode = !!cmd.on;
			return state();
		case "plan_approve":
			guard.planMode = false;
			s.prompt(cmd.text || "The plan is approved. Carry it out now, step by step.").catch((e) =>
				send({ type: "error", message: String(e?.message ?? e) }),
			);
			return state();

		// Editing and forking the conversation.
		case "fork_points":
			return s.getUserMessagesForForking();
		case "edit_message": {
			// Moves back to just before that message; the text returns for editing.
			const r = await s.navigateTree(cmd.entryId, {});
			return { text: r.editorText ?? "", cancelled: r.cancelled };
		}
		case "fork_session": {
			const source = s.sessionFile;
			if (!source) throw new Error("Nothing to fork yet");
			assertIdle();
			await openSession(SessionManager.forkFrom(source, s.sessionManager.getCwd()));
			const r = cmd.entryId ? await session!.navigateTree(cmd.entryId, {}) : { editorText: "" };
			return { ...state(), text: r.editorText ?? "" };
		}

		case "providers":
			return providers();
		case "models":
			return (await modelRuntime.getAvailable(cmd.provider)).filter(isChatModel).map(modelInfo);
		case "set_model": {
			const model = modelRuntime.getModel(cmd.provider, cmd.model);
			if (!model) throw new Error(`Unknown model ${cmd.provider}/${cmd.model}`);
			await s.setModel(model, { persist: true });
			return state();
		}
		case "set_thinking":
			s.setThinkingLevel(cmd.level, { persist: true });
			return state();

		case "login":
			await login(cmd.provider, cmd.method ?? "api_key");
			return providers();
		case "auth_reply": {
			const pending = pendingAuth.get(cmd.authId);
			pendingAuth.delete(cmd.authId);
			if (cmd.cancel) pending?.reject(new Error("cancelled"));
			else pending?.resolve(String(cmd.value ?? ""));
			return null;
		}
		case "logout":
			await modelRuntime.logout(cmd.provider);
			return providers();

		// GitHub sync (sync.ts).
		case "sync_status":
			return sync.status();
		case "sync_enable":
			return sync.setEnabled(!!cmd.on);
		case "sync_now":
			// "soon": the app is going to the background; give a running turn a moment to settle.
			if (cmd.soon) {
				sync.schedule(2000);
				return sync.status();
			}
			return sync.syncNow({ confirmDelete: !!cmd.confirmDelete });

		// Custom endpoints (providers.ts).
		case "custom_providers":
			return customProviders.list();
		case "custom_provider_save": {
			const custom = customProviders.ids();
			const builtin = new Set(modelRuntime.getProviders().map((p) => p.id).filter((id) => !custom.has(id)));
			const saved = customProviders.save(cmd.provider ?? {}, builtin);
			await modelRuntime.refresh({ allowNetwork: false });
			// The open chat holds its own copy of the model: swap in the new definition (reasoning, limits) now
			// rather than on the next restart, keeping the chosen thinking level where the model still allows it.
			const current = s.model;
			if (current?.provider === saved.id) {
				const fresh = modelRuntime.getModel(saved.id, current.id);
				if (fresh) {
					const level = s.thinkingLevel;
					await s.setModel(fresh);
					s.setThinkingLevel(level);
				}
			}
			return customProviders.list();
		}
		case "custom_provider_delete":
			customProviders.remove(cmd.providerId);
			await modelRuntime.refresh({ allowNetwork: false });
			return customProviders.list();
		case "custom_provider_fetch_models":
			return fetchModels(GRIPHUB_API, GRIPHUB_BASE_URL, cmd.apiKey || customProviders.key(GRIPHUB_ID));
		// Re-reads GripHub's /v1/models with the saved key and updates the model
		// list (new models appear, retired ones go). Image models stay out of it.
		case "griphub_models_refresh": {
			const r = await refreshGripHubModels();
			return { ...r, providers: customProviders.list() };
		}
		case "griphub_image_models": {
			const key = customProviders.key(GRIPHUB_ID);
			if (!key) throw new Error("No GripHub key saved");
			const models = await listImageModels(GRIPHUB_BASE_URL, key);
			const rates = router.rates();
			return models.map((m) => ({ ...m, credits: rates[m.id]?.credits ?? null, perImage: rates[m.id]?.perImage ?? true, list: rates[m.id]?.list ?? null, promoEndsAt: rates[m.id]?.promoEndsAt ?? null }));
		}
		case "custom_provider_images_generate":
			return {
				b64_json: await generateImage(
					GRIPHUB_BASE_URL,
					customProviders.key(GRIPHUB_ID),
					String(cmd.model ?? ""),
					String(cmd.prompt ?? ""),
					String(cmd.size ?? "1024x1024"),
				),
			};

		case "new_session":
			assertIdle();
			return openSession(SessionManager.create(cmd.cwd ?? workspace));
		case "sessions":
			return (await SessionManager.listAll()).map((info) => ({
				path: info.path,
				id: info.id,
				cwd: info.cwd,
				name: info.name ?? null,
				modified: info.modified.getTime(),
				messageCount: info.messageCount,
				firstMessage: info.firstMessage,
			}));
		case "open_session":
			if (s.sessionFile && resolve(cmd.path) === resolve(s.sessionFile)) return state();
			assertIdle();
			// A chat with no message has no file yet, and opening a file that isn't there takes the process's own folder:
			// the app says which folder the chat was in (cmd.cwd), and a file that exists keeps the one in its header.
			return openSession(
				SessionManager.open(cmd.path, undefined, existsSync(cmd.path) ? undefined : (cmd.cwd as string | undefined) ?? workspace),
			);
		case "rename_session": {
			const name = String(cmd.name ?? "").trim();
			if (!name) throw new Error("Name is empty");
			if (cmd.path === s.sessionFile) s.setSessionName(name);
			else SessionManager.open(cmd.path).appendSessionInfo(name);
			return null;
		}
		case "delete_session":
			return deleteSessions([cmd.path]);
		case "delete_sessions":
			return deleteSessions(cmd.paths ?? []);
		case "project_delete_check":
			return projectDeleteCheck(cmd.path);
		case "delete_project":
			return deleteProject(cmd.path, !!cmd.deleteChats);
		case "messages": {
			// Each turn's last reply carries how long the turn took, when the chat kept it.
			const times = turnTimes(s);
			return s.messages.map((m: any) => {
				const out = withCost(m);
				if (m.role === "compactionSummary") return { ...out, griphubCost: latestSummaryCost(s) };
				const ms = m.role === "assistant" ? times.get(m.timestamp) : undefined;
				return ms === undefined ? out : { ...out, griphubTurnMs: ms };
			});
		}
		case "summarized_messages":
			return summarizedMessages(s).map(withCost);

		// Accounts, repositories, SSH and deploys (integrations.ts).
		case "integrations":
			return integrations.summary();
		case "github_login":
			return integrations.githubLogin(cmd.token);
		case "github_device_start":
			return integrations.githubDeviceStart();
		case "github_device_poll":
			return integrations.githubDevicePoll(cmd.deviceCode);
		case "github_device_status":
			return integrations.githubDeviceStatus();
		case "github_device_cancel":
			return integrations.githubDeviceCancel();
		case "github_logout":
			return integrations.githubLogout();
		case "github_repos":
			return integrations.repos();
		case "git_clone":
			return integrations.clone(cmd.repo, taskLog(cmd));
		case "projects":
			return integrations.projects();
		case "ssh_key":
			return integrations.sshKey();
		case "ssh_host_save":
			return integrations.saveSshHost(cmd.host);
		case "ssh_host_delete":
			return integrations.deleteSshHost(cmd.hostId);
		case "ssh_test":
			return integrations.sshTest(cmd.hostId, taskLog(cmd));
		case "vercel_login":
			return integrations.vercelLogin(cmd.token);
		case "vercel_logout":
			return integrations.vercelLogout();
		case "cloudflare_login":
			return integrations.cloudflareLogin(cmd.token);
		case "cloudflare_account":
			return integrations.cloudflareSelectAccount(cmd.accountId);
		case "cloudflare_logout":
			return integrations.cloudflareLogout();
		case "ci_watch":
			return integrations.watchProject(cwd, taskLog(cmd));
		case "deploy":
			return integrations.deploy(cmd.target, cwd, cmd.options ?? {}, taskLog(cmd));
		case "deploy_plan":
			return integrations.deployPlan(cmd.target, cwd, cmd.options ?? {});

		// Git for the project folder (gitops.ts).
		case "git_status":
			return gitops.status(cwd);
		case "git_diff":
			return gitops.diff(cwd, cmd.file, !!cmd.staged);
		case "git_review":
			return gitops.review(cwd);
		case "git_commit_message":
			return { message: await commitMessage(s, cwd) };
		case "git_stage":
			await gitops.stage(cwd, cmd.paths ?? "all");
			return gitops.status(cwd);
		case "git_unstage":
			await gitops.unstage(cwd, cmd.paths ?? "all");
			return gitops.status(cwd);
		case "git_discard":
			await gitops.discard(cwd, cmd.paths ?? []);
			return gitops.status(cwd);
		case "git_commit":
			return { commit: await gitops.commit(cwd, String(cmd.message ?? "").trim() || "Update", !!cmd.all) };
		case "git_log":
			return gitops.log(cwd, cmd.limit ?? 40);
		case "git_branches":
			return gitops.branches(cwd);
		case "git_checkout":
			await gitops.checkout(cwd, cmd.branch, !!cmd.create);
			return gitops.status(cwd);
		case "git_fetch":
			await gitops.fetch(cwd);
			return gitops.status(cwd);
		case "git_pull":
			await gitops.pull(cwd, taskLog(cmd));
			return gitops.status(cwd);
		case "git_push":
			await gitops.push(cwd, taskLog(cmd));
			return gitops.status(cwd);
		case "github_pr_create": {
			const st = await gitops.status(cwd);
			const slug = st.repo ? gitops.githubSlug(st.remote) : null;
			if (!st.repo || !slug) throw new Error("This folder has no GitHub remote");
			if (st.ahead > 0 || !st.upstream) await gitops.push(cwd, () => {});
			const repo = await integrations.githubApi(`/repos/${slug}`);
			const pr = await integrations.githubApi(`/repos/${slug}/pulls`, {
				method: "POST",
				body: JSON.stringify({ title: cmd.title, body: cmd.body ?? "", head: st.branch, base: cmd.base || repo.default_branch }),
			});
			return { url: pr.html_url, number: pr.number };
		}
		case "github_issues": {
			const st = await gitops.status(cwd);
			const slug = cmd.repo ?? (st.repo ? gitops.githubSlug(st.remote) : null);
			if (!slug) throw new Error("This folder has no GitHub remote");
			const list = await integrations.githubApi(`/repos/${slug}/issues?state=${cmd.state ?? "open"}&per_page=50`);
			return {
				repo: slug,
				issues: (list as any[]).map((i) => ({
					number: i.number,
					title: i.title,
					body: i.body ?? "",
					url: i.html_url,
					author: i.user?.login,
					labels: (i.labels ?? []).map((l: any) => l.name),
					comments: i.comments,
					isPr: !!i.pull_request,
					updatedAt: Date.parse(i.updated_at),
				})),
			};
		}

		// Checkpoints (checkpoints.ts).
		case "checkpoints":
			return checkpoints.list(cwd);
		case "checkpoint_create":
			return checkpoints.snapshot(cwd, cmd.label || "Manual checkpoint");
		case "checkpoint_diff":
			return checkpoints.diff(cwd, cmd.checkpoint, cmd.file);
		case "checkpoint_restore_plan":
			return checkpoints.restorePlan(cwd, cmd.checkpoint);
		case "checkpoint_restore":
			if (s.isStreaming) throw new Error("Stop the agent before restoring");
			return checkpoints.restore(
				cwd,
				cmd.checkpoint,
				Array.isArray(cmd.keep) ? cmd.keep.filter((k: unknown): k is string => typeof k === "string") : [],
			);

		// Project tools (workbench.ts).
		case "search":
			return search(cwd, String(cmd.query ?? ""), { regex: !!cmd.regex, caseSensitive: !!cmd.caseSensitive, glob: cmd.glob });
		case "files_find":
			return findFiles(cwd, String(cmd.query ?? ""), Number(cmd.limit ?? 30));
		case "db_tables":
			return dbTables(cmd.path);
		case "db_query":
			return dbQuery(cmd.path, String(cmd.sql ?? ""), cmd.limit ?? 200);
		case "tests_detect":
			return detectTests(cwd);
		case "tunnel_start":
			return {
				url: await tunnels.start(Number(cmd.port), (u) => send({ type: "tunnel", ...u })),
			};
		case "tunnel_stop":
			tunnels.stop(Number(cmd.port));
			return tunnels.list();
		case "tunnels":
			return tunnels.list();
		case "usage":
			return usageSummary(join(agentDir, "sessions"), cmd.days ?? 30, estimateUsage);

		// Prompt templates: slash commands pi expands.
		case "templates":
			return templates.list();
		case "template_save": {
			const name = templates.save(cmd.name, cmd.description ?? "", cmd.body ?? "", cmd.argumentHint);
			await s.reload();
			return { name, templates: templates.list() };
		}
		case "template_delete":
			templates.remove(cmd.name);
			await s.reload();
			return templates.list();
		case "slash_commands":
			return {
				templates: templates.list().map((t) => ({ name: t.name, description: t.description, hint: t.argumentHint })),
				skills: skills.list().map((k) => ({ name: `skill:${k.name}`, description: k.description, hint: null })),
			};

		// Background runs, queue and schedules (runs.ts).
		case "runs":
			return runner.summary();
		case "run_enqueue":
			checkBudget();
			return runner.enqueue(String(cmd.prompt ?? ""), cwd, cmd.title);
		case "run_cancel":
			await runner.cancel(cmd.runId);
			return runner.summary();
		case "runs_clear":
			runner.clearFinished();
			return runner.summary();
		case "run_delete": {
			const removed = runner.delete(cmd.runId);
			return { ...runner.summary(), removed };
		}
		case "run_restore":
			runner.restore(cmd.run, cmd.index);
			return runner.summary();
		case "runs_concurrency":
			runner.setConcurrency(cmd.n);
			return runner.summary();
		case "schedule_save":
			runner.saveSchedule({ ...cmd.schedule, cwd: cmd.schedule?.cwd || cwd });
			return runner.summary();
		case "schedule_delete":
			runner.deleteSchedule(cmd.scheduleId);
			return runner.summary();
		case "schedule_run":
			runner.runScheduleNow(cmd.scheduleId);
			return runner.summary();

		// MCP servers (mcp.ts). Tools refresh on the next session rebuild.
		case "mcp_servers":
			return mcp.summary();
		case "mcp_save": {
			const out = await mcp.upsert(cmd.server ?? {});
			if (!s.isStreaming) await reopenSession();
			return out;
		}
		case "mcp_delete": {
			const out = await mcp.remove(cmd.serverId);
			if (!s.isStreaming) await reopenSession();
			return out;
		}

		// Backups.
		// Automatic backups (autobackup.ts): the app turns them on with a key it makes, on a server or on the phone.
		case "auto_backup_status":
			return autoBackup?.status() ?? { enabled: false, available: false, backups: [] };
		case "auto_backup_configure":
			if (!autoBackup) throw new Error("The host is still starting; try again");
			return autoBackup.configure(cmd.key ?? null);
		case "auto_backup_now": {
			if (!autoBackup) throw new Error("The host is still starting; try again");
			const made = await autoBackup.tick(cmd.force !== false);
			return { made, ...autoBackup.status() };
		}
		// The phone's own backups are restored with the same door the server's are: decrypt with the key, put in place.
		// The key comes back as a recovery code only on the phone's own host (see recoveryKey), for the app to show once.
		case "auto_backup_key":
			if (server) throw new Error("A server never tells its backup key; the phone that made it has it");
			return { key: autoBackup?.recoveryKey() ?? null };
		// A server's backup, on this phone: decrypted with the phone's key, then put in place. The app restarts the host
		// afterwards, so every part reads what was restored.
		case "backup_restore_server": {
			if (session?.isStreaming) throw new Error("Stop the agent before restoring");
			const tmp = join(stateDir, `restore-${Date.now()}.zip`);
			try {
				decryptBackup(String(cmd.path), String(cmd.key ?? ""), tmp);
				return restoreBackup(tmp, { agentDir, workspace, home: process.env.HOME ?? agentDir });
			} finally {
				rmSync(tmp, { force: true });
			}
		}
		case "backup_create":
			return createBackup(!!cmd.includeWorkspace);
		case "backup_restore":
			return restoreLocalBackup(cmd.path);

		// Linux container. On the phone: container.ts (proot). On a server: the rootless Podman box (podmanbox.ts), which
		// the setup script builds; the same commands serve both, so the screens do not need to know which one they talk to.
		case "container_status":
			return server ? box.status(settingsManager.getShellPath()) : container.status(settingsManager.getShellPath());
		case "container_install": {
			if (server) {
				// "Install" on a server means building the image again.
				guardBoxWork(cmd);
				await box.rebuildImage(taskLog(cmd));
				return box.status(settingsManager.getShellPath());
			}
			await container.install(cmd.distro as Distro, taskLog(cmd), integrations.settings.dns);
			// On by default once installed, unless the user turned it off before.
			if (integrations.settings.containerShell !== false) {
				settingsManager.setShellPath(container.shellPath);
				await settingsManager.flush();
				await reopenSession().catch(() => {});
			}
			return container.status(settingsManager.getShellPath());
		}
		case "container_remove":
			if (server) {
				// "Remove" on a server throws the container away; the image and the box's home stay, and the next command
				// makes a new one.
				guardBoxWork(cmd);
				await box.reset();
				return box.status(settingsManager.getShellPath());
			}
			if (settingsManager.getShellPath() === container.shellPath) settingsManager.setShellPath(undefined);
			container.remove();
			await reopenSession();
			return container.status(settingsManager.getShellPath());
		case "container_enable":
			if (server) {
				if (cmd.on && !box.available) throw new Error("There is no box on this server");
				settingsManager.setShellPath(cmd.on ? boxScript : undefined);
				integrations.updateSettings({ containerShell: !!cmd.on });
				ensureAgentsFile(); // the notes tell the agent where its commands run
				await settingsManager.flush();
				await reopenSession();
				return box.status(settingsManager.getShellPath());
			}
			if (cmd.on && !container.status(undefined).installed) throw new Error("Install the container first");
			settingsManager.setShellPath(cmd.on ? container.shellPath : undefined);
			integrations.updateSettings({ containerShell: !!cmd.on });
			await settingsManager.flush();
			await reopenSession();
			return container.status(settingsManager.getShellPath());
		// Server only: the box.
		case "box_check":
			if (!server) throw new Error("Only a server has a box");
			return box.check();
		case "box_stop":
			guardBoxWork(cmd);
			await box.stop();
			return box.status(settingsManager.getShellPath());
		case "box_wipe_home":
			guardBoxWork(cmd);
			return { ...(await box.wipeHome()), status: await box.status(settingsManager.getShellPath()) };

		// Disk, memory, and what is running: for the app's server screen.
		// Server only: the phone's UTC offset, for schedules. Whole hours map to Etc/GMT zones (Indonesia's are); other
		// offsets leave the server's own zone.
		case "timezone_set": {
			if (!server) return { timeZone: null };
			const minutes = Number(cmd.offsetMinutes);
			if (!Number.isInteger(minutes) || Math.abs(minutes) > 14 * 60) throw new Error("offsetMinutes must be a whole number of minutes");
			const zone = minutes === 0 ? "UTC" : minutes % 60 === 0 ? `Etc/GMT${minutes > 0 ? "-" : "+"}${Math.abs(minutes) / 60}` : null;
			if (zone && zone !== integrations.settings.timeZone) {
				integrations.updateSettings({ timeZone: zone });
				process.env.TZ = zone;
			}
			return { timeZone: integrations.settings.timeZone ?? null };
		}
		case "health": {
			const snap = await health.check();
			const runs = runner.summary();
			return {
				...snap,
				mode,
				transport: listenPath ? "daemon" : "stdio",
				epoch: hub.epoch,
				uptimeSec: Math.round(process.uptime()),
				node: process.version,
				runs: { running: runs.running, queued: runs.runs.filter((r) => r.status === "queued").length },
				subagents: subagents.busy(),
				clientInBackground: hub.clientInBackground(),
				// An update is copied and the host is waiting for the work in flight to end before it restarts.
				restartPending: restartGate.pending,
				bundleStamp: runningStamp ?? null,
				// Where the agent's commands run: the app shows a box that is not built (commands then fail) as a problem.
				...(server ? { box: await boxHealth() } : {}),
				// The zone schedules run in (timezone_set), as an offset the app can compare with the phone's.
				clock: { timeZone: process.env.TZ ?? null, offsetMinutes: -new Date().getTimezoneOffset() },
			};
		}

		// GripHub Router account data (router.ts), with the saved GripHub key.
		case "router_account": {
			const [account] = await Promise.all([
				router.refreshAccount(cmd.force ? 0 : 30_000),
				router.refreshToday(cmd.force ? 0 : 30_000).catch(() => null),
				router.refreshRequests().catch(() => null),
			]);
			const spent = spentToday();
			return { ...router.snapshot(), account, spentToday: spent.credits, spentTodayReal: spent.real };
		}
		case "router_snapshot":
			return router.snapshot();
		case "griphub_credits": {
			// Older app builds: the trimmed summary the first Usage card used.
			const a = await router.refreshAccount(30_000);
			const nearest = a.batches.find((b) => b.expiresAt) ?? null;
			return {
				remaining: a.balance,
				used: a.used,
				limit: a.granted,
				suspended: a.suspended,
				suspendedUntil: a.suspendedUntil,
				nearestExpiry: nearest ? { credits: nearest.credits, expiresAt: nearest.expiresAt } : null,
				topModels: a.byModel.slice(0, 5).map((m) => ({ model: m.model, creditsUsed: m.credits })),
			};
		}
		// App settings: DNS, search keys, approvals, fallbacks, budget.
		// Settings > Server agent > Send a test notification: goes out even with the app open.
		case "notify_test":
			if (!server) throw new Error("Notifications through ntfy are for a server agent.");
			return notifier.test();
		case "settings_get":
			return integrations.publicSettings();
		case "settings_set": {
			const out = integrations.updateSettings(cmd.settings ?? {});
			if (!server) container.setNameservers(integrations.settings.dns);
			guard.mode = integrations.settings.approvalMode ?? "ask_risky";
			return out;
		}
		case "search_keys_add":
			return integrations.addSearchKeys(cmd.service, String(cmd.text ?? ""));
		case "search_key_remove":
			return integrations.removeSearchKey(cmd.service, Number(cmd.index));
		case "s1_usage":
			return s1Usage(integrations.searchKeys().s1);

		// Agent skills (skills.ts). pi rescans them on reload.
		case "skills_list":
			return skills.list();
		case "skills_search":
			return skills.search(cmd.query ?? "");
		case "skills_browse":
			return skills.browse(cmd.spec);
		case "skills_install": {
			const added = await skills.install(cmd.spec, taskLog(cmd));
			await s.reload();
			return added;
		}
		case "skills_remove":
			skills.remove(cmd.path);
			await s.reload();
			return skills.list();

		default:
			throw new Error(`Unknown command: ${cmd.type}`);
	}
}

/** Streams a long command's output to the app as `task` records. */
function taskLog(cmd: Command): Log {
	const taskId = cmd.taskId ?? cmd.id;
	const log: Log = (line: string) => send({ type: "task", taskId, line });
	log.ci = (ci) => send({ type: "task", taskId, ci });
	return log;
}

/**
 * Nothing is in flight: no reply being written, no background run queued or running, no subagent waiting, working or
 * stopping, and no approval waiting (chat or subagent). GripHub's subagents outlive the turn that started them, so the
 * chat alone is not enough: restarting then would kill them (server_agent.md 4.9).
 */
function isIdle(): boolean {
	const runs = runner?.summary();
	return (
		!session?.isStreaming &&
		guard.pendingApprovals().length === 0 &&
		!subagents?.busy() &&
		!jobs?.busy() &&
		!runs?.running &&
		!runs?.runs.some((r) => r.status === "queued")
	);
}

/** Changing the box kills whatever is running in it. Refuse while the agent is, unless the app says it is meant. */
function guardBoxWork(cmd: Command) {
	if (!server) throw new Error("Only a server has a box");
	if (cmd.force === true) return;
	const working = session?.isStreaming
		? "The agent is working in the box right now."
		: runner?.summary().running
			? "A background task is running in the box."
			: subagents?.busy()
				? "A subagent is working in the box."
				: null;
	if (working) throw Object.assign(new Error(`${working} Stop it first, or do it anyway.`), { code: "busy" });
}

let shuttingDown = false;
/** Ends the host. Subagents are stopped first, so each keeps a partial report instead of vanishing. */
async function shutdown(code = 0) {
	if (shuttingDown) return;
	shuttingDown = true;
	tunnels.stopAll();
	jobs?.stopAll();
	autoBackup?.stop();
	health.stop();
	preview?.stopAll();
	// The phone's app force-kills the host 1.5 s after closing stdin (AgentRuntime.stop), so it only waits long enough for
	// the subagents' "stopped" records to leave; a daemon has time for their partial reports.
	await subagents?.stopAll(listenPath ? 5000 : 500).catch(() => {});
	runner?.dispose();
	void mcp?.dispose();
	session?.dispose();
	hub.close();
	if (listenPath) {
		rmSync(listenPath, { force: true });
		rmSync(runningMarker, { force: true });
	}
	process.exit(code);
}

const restartGate = new RestartGate({ isIdle, exit: () => void shutdown(0) });

// ---------------------------------------------------------------------------
// Startup

async function main() {
	// A rejected promise must never kill the host (and, with it, the chat):
	// log it and keep running. Features still handle their own errors.
	process.on("unhandledRejection", (reason) => {
		console.error("[host] unhandled rejection (kept alive):", reason);
	});
	// A state file that could not be read is set aside and reported (state.ts), never taken for an empty one: the person
	// is told here, in the chat, as soon as an app connects.
	onStoreProblem((p) => {
		log("store problem:", storeProblemMessage(p));
		send({ type: "notice", message: storeProblemMessage(p) });
	});
	// A server host stuck in one loop never answers and never exits, so the service manager has nothing to restart:
	// a watchdog thread kills it after two minutes without a sign of life (watchdog.ts).
	if (server) startWatchdog({ staleMs: Number(process.env.GRIPHUB_WATCHDOG_MS) || 120_000 });
	// A public tunnel (ssh -R) outlives its parent process: stop tunnels on
	// every shutdown path, not just stdin end. (A SIGKILL orphan cannot be
	// reaped by the app — the OS or user must kill that ssh.)
	for (const signal of ["SIGTERM", "SIGINT"] as const) process.on(signal, () => void shutdown(0));
	process.on("exit", () => tunnels.stopAll());
	mkdirSync(agentDir, { recursive: true });
	mkdirSync(workspace, { recursive: true });
	mkdirSync(stateDir, { recursive: true });
	// A decrypted server backup (backup_restore_server) is a plain-text zip for a moment; a host that died mid-restore
	// would leave it behind, so it is swept here.
	for (const f of readdirSync(stateDir)) {
		if (/^restore-\d+\.zip$/.test(f)) rmSync(join(stateDir, f), { force: true });
	}

	// Route every lookup through DNS-over-HTTPS (configurable in settings; a server defaults to its own resolver).
	installDohLookup();
	integrations = new Integrations(agentDir, workspace, { server, boxScript: () => (box.available ? boxScript : null) });
	// After the settings: on a server they say whether bash runs in the box, which the notes describe.
	ensureAgentsFile();
	integrations.onChange = () => send({ type: "integrations", summary: integrations.summary() });
	// Keeps a GitHub App sign-in (8-hour tokens) fresh for git and the agent's shell, which read
	// the token from git's config and $GITHUB_TOKEN rather than asking for it.
	setInterval(() => void integrations.githubFresh(), 10 * 60_000).unref();
	void integrations.githubFresh();
	guard.mode = integrations.settings.approvalMode ?? "ask_risky";
	skills = new Skills(agentDir, join(fileURLToPath(new URL(".", import.meta.url)), "skills"), () => process.env.GITHUB_TOKEN);
	skills.seed();
	templates = new Templates(agentDir);
	templates.seed(join(stateDir, "seeded-templates.json"));
	checkpoints = new Checkpoints(join(stateDir, "checkpoints"));
	container = new Container(process.env.GRIPHUB_FILES ?? join(agentDir, "..", "..", ".."));
	mcp = new Mcp(
		join(stateDir, "mcp.json"),
		() => send({ type: "mcp", servers: mcp.summary() }),
		server ? { shell: "/bin/sh", box: () => (box.available ? boxScript : "/bin/sh") } : undefined,
	);
	// Automatic backups on both sides, differently placed (autobackup.ts): a server keeps its own in ~/.griphub and
	// the app fetches the newest to the phone; the phone writes its own straight into the shared Download folder, the
	// one place that survives the app (and, synced or copied off the phone, the phone itself). Secrets stay out there,
	// and the key is shown once as a recovery code: a backup must not need the phone it was made on.
	autoBackup = new AutoBackup({
		dir: server ? join(griphubDir, "backups") : phoneBackupDir(),
		configFile: join(stateDir, "auto-backup.json"),
		agentDir,
		workspace,
		home: process.env.HOME ?? agentDir,
		intervalMs: Number(process.env.GRIPHUB_BACKUP_MS) || undefined,
		noSecrets: !server,
		log: (m) => log(m),
	});
	// The app's view of files on this machine (fs_*), and pages served from them (preview_*). A server's app cannot
	// read its disk any other way; on the phone the same commands work too, inside the same folders.
	// On a server the app also fetches the automatic backups from here (read-only).
	fsService = new Fs([
		{ path: workspace },
		{ path: join(agentDir, "skills"), readOnly: true },
		...(server ? [{ path: join(griphubDir, "backups"), readOnly: true }] : []),
	]);
	preview = new Preview({ roots: [workspace], idleMs: Number(process.env.GRIPHUB_PREVIEW_IDLE_MS) || undefined });
	customProviders = new CustomProviders(join(stateDir, "custom-providers.json"), join(agentDir, "models.json"));
	customProviders.applyEnv();
	router = new Router({
		key: () => customProviders?.key(GRIPHUB_ID) ?? "",
		cacheFile: join(stateDir, "router-cache.json"),
		fallbackRates: FALLBACK_RATES,
	});
	usePricingRouter(router);
	modelRuntime = await ModelRuntime.create();
	// Never auto-trust project code: a cloned repo's .pi/extensions/*.ts
	// would otherwise run inside the host with the user's tokens on merely
	// opening the project. Project settings are not loaded while untrusted
	// either (see SettingsManager); the app's own inline extension is
	// unaffected, it is not a project extension.
	settingsManager = SettingsManager.create(workspace, agentDir, { projectTrusted: false });
	// pi keeps the prompt cache warm with extra 1-token requests. On GripHub
	// each re-reads the whole cached prompt at the full rate (one opus warm-up
	// cost ~1.3 credits), so they cost more than the cache saves. Off unless
	// the user turned it on themselves.
	if ((settingsManager as any).globalSettings?.cacheWarming === undefined) {
		settingsManager.setCacheWarmingMode("off");
		await settingsManager.flush();
	}
	// Subagents are created after boot, but the manager must exist before the
	// first interactive session is built (buildSession registers its tool).
	subagents = new SubagentManager({
		send: (r) => send(r),
		wireEvent: (e) => wireEvent(e),
		createSession: (opts) => buildSubagentSession(opts),
		limits: () => {
			const st = integrations.settings;
			return {
				creditLimit: st.subagentCreditLimit ?? 50,
				minutesLimit: st.subagentMinutesLimit ?? 30,
				approvalMode: st.subagentApprovalMode ?? st.approvalMode ?? "ask_risky",
			};
		},
	});
	jobs = new Jobs({
		send: (r) => send(r),
		shellPath: () => settingsManager.getShellPath(),
		finished: (job) => {
			finishedJobs.push(job);
			void deliverJobs();
		},
	});
	// On a server, bash runs inside the rootless container once it has been set up (server/box/box), unless the user
	// turned that off. If the launcher went away, stop pointing at it.
	// A server runs on UTC as a rule; the app tells it the phone's time zone (timezone_set), so "every day at 09:00"
	// means the user's 09:00.
	if (server && integrations.settings.timeZone) process.env.TZ = integrations.settings.timeZone;
	// The app's update copies this host's folder only; the box launcher and its files come in it and are put in place here.
	if (server) {
		const replaced = syncLauncher({ hostDir, griphubDir, warn: (m) => log("launcher:", m) });
		if (replaced.length) log("launcher updated:", replaced.join(", "));
	}
	if (server) {
		const shell = settingsManager.getShellPath();
		if (box.available && integrations.settings.containerShell !== false && shell !== boxScript) {
			settingsManager.setShellPath(boxScript);
			await settingsManager.flush();
		} else if (shell === boxScript && !box.available) {
			settingsManager.setShellPath(undefined);
			await settingsManager.flush();
		}
	}
	// Linux container is the agent's shell by default once installed.
	else if (
		container.status(undefined).installed &&
		integrations.settings.containerShell !== false &&
		settingsManager.getShellPath() !== container.shellPath
	) {
		settingsManager.setShellPath(container.shellPath);
		await settingsManager.flush();
	}
	await openSession(SessionManager.continueRecent(workspace));
	// Account data and live rates in the background; the model list once a day
	// (new GripHub models show up without re-entering the key).
	if (customProviders.key(GRIPHUB_ID)) {
		void router.refreshAccount().catch((e) => log("router account:", (e as Error).message));
		void router.refreshRequests().catch(() => {});
		const stamp = join(stateDir, "models-refreshed");
		const last = existsSync(stamp) ? Number(readFileSync(stamp, "utf8")) || 0 : 0;
		if (Date.now() - last > 24 * 3600_000) {
			void refreshGripHubModels()
				.then((r) => {
					writeFileSync(stamp, String(r.refreshedAt));
					if (r.added.length || r.removed.length) send({ type: "models_changed", ...r });
				})
				.catch((e) => log("models refresh:", (e as Error).message));
		}
	}
	sync = new GitHubSync({
		agentDir,
		workspace,
		stateDir,
		integrations,
		providers: customProviders,
		activeSession: () => session?.sessionFile,
		busy: () => !!session?.isStreaming || (runner?.summary().running ?? 0) > 0,
		providersChanged: async () => {
			await modelRuntime.refresh({ allowNetwork: false });
		},
		notify: (status) => send({ type: "sync", status }),
		unavailable: server
			? "GitHub sync is off on a server agent: the server keeps the one copy of the chats and projects. Move data between the phone and the server with a backup."
			: undefined,
	});
	// Pick up what other phones synced while this one was off.
	sync.schedule(20_000);
	runner = new Runner(join(stateDir, "runs.json"), backgroundSession, send, (p) => integrations.githubApi(p), (summary, reason) =>
		guard.askApproval("issue_run", summary, reason),
	);

	// Starter skills and MCP connections come up in the background; the chat
	// session is rebuilt afterwards (when idle) so it sees them.
	void Promise.allSettled([skills.installStarter((line) => log("skills:", line)), mcp.connectAll()]).then(() => {
		if (session && !session.isStreaming) return reopenSession().catch(() => {});
	});

	const readyRecord = { type: "ready", version: VERSION };
	if (listenPath) {
		// A daemon that was killed leaves its marker behind; finding it means the last run did not end cleanly.
		mkdirSync(griphubDir, { recursive: true, mode: 0o700 });
		if (existsSync(runningMarker)) {
			send({ type: "notice", message: "The host was restarted unexpectedly (it was stopped without shutting down)." });
			void notifier.send("restarted", "Host restarted unexpectedly", { priority: 4, tags: ["warning"] });
		}
		writeFileSync(runningMarker, `${process.pid} ${new Date().toISOString()}\n`, { mode: 0o600 });
		// Listen last: a client that connects now finds everything above in place. stdin is not read at all (systemd
		// gives the daemon /dev/null, whose end must not stop it).
		hub.setReady(readyRecord);
		await listenOnSocket(hub, listenPath);
		log(`listening on ${listenPath}`);
	} else {
		// Split on LF only; readline would also split on U+2028/U+2029.
		const lines = new LineBuffer();
		process.stdin.setEncoding("utf8");
		process.stdin.on("data", (chunk: string) => {
			for (const line of lines.push(chunk)) stdio?.receive(line);
		});
		// The app closed our stdin: it is done with us.
		process.stdin.on("end", () => void shutdown(0));
		hub.setReady(readyRecord);
	}
	// A server is watched for a filling disk; a phone's storage is the user's business (the `health` command still
	// answers there).
	if (server) health.start();
	autoBackup?.start();
}

main().catch((e) => {
	log("fatal:", e?.stack ?? e);
	send({ type: "fatal", message: String(e?.message ?? e) });
	process.exit(1);
});
