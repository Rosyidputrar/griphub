/**
 * GripHub AI Agent agent host.
 *
 * Runs inside the bundled Node runtime on the device and exposes the pi SDK to
 * the Flutter app over JSONL on stdin/stdout:
 *
 *   app  -> host   {"id": 1, "type": "prompt", "text": "..."}
 *   host -> app    {"type": "response", "id": 1, "ok": true, "data": ...}
 *   host -> app    {"type": "event", "event": <pi session event>}
 *   host -> app    {"type": "auth_prompt" | "approval" | "task" | "runs" | ...}
 *
 * stdout is reserved for protocol records; logs go to stderr.
 */

import { existsSync, mkdirSync, readFileSync, rmSync, unlinkSync, writeFileSync } from "node:fs";
import { dirname, join, resolve, sep } from "node:path";
import { fileURLToPath } from "node:url";
import {
	type AgentSession,
	type AgentSessionEvent,
	createAgentSession,
	DefaultResourceLoader,
	getAgentDir,
	ModelRuntime,
	SessionManager,
	SettingsManager,
	VERSION,
} from "@earendil-works/pi-coding-agent";
import { Checkpoints } from "./checkpoints.js";
import { Container, type Distro } from "./container.js";
import { installDohLookup } from "./dns.js";
import * as gitops from "./gitops.js";
import { Guard } from "./guard.js";
import { Integrations, type Log, run } from "./integrations.js";
import { installLenientTools } from "./lenient.js";
import { BASH_TIMEOUT_SECONDS, limitsExtension } from "./limits.js";
import { Mcp } from "./mcp.js";
import { CustomProviders, fetchModels, generateImage, GRIPHUB_API, GRIPHUB_BASE_URL, GRIPHUB_ID, listImageModels } from "./providers.js";
import { type RunSession, Runner } from "./runs.js";
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
	Templates,
	Tunnels,
	usageSummary,
	wibDay,
	writeZip,
} from "./workbench.js";
import { FALLBACK_RATES, messageCost, requestEstimate, usageOf, usePricingRouter } from "./pricing.js";
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
let router: Router;
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

/** Where the host keeps its own small files on a server (`running` marker; later the box and ntfy settings). */
const griphubDir = process.env.GRIPHUB_DIR ?? join(process.env.HOME ?? agentDir, ".griphub");
/** Exists while the daemon runs and is removed by a clean shutdown; finding it at start means the last one crashed. */
const runningMarker = join(griphubDir, "running");

/**
 * Sends the host's records to the app. On the phone that is stdout, as always (no numbering, no buffer). As a daemon
 * the hub numbers what is worth replaying and keeps it, so an app that lost its connection gets exactly what it
 * missed (transport.ts).
 */
const hub = new Hub({
	replay: !!listenPath,
	mode,
	hostVersion: VERSION,
	handle: (cmd) => handle(cmd as Command),
	// Only tests shorten these.
	pingIntervalMs: Number(process.env.GRIPHUB_PING_MS) || undefined,
	idleTimeoutMs: Number(process.env.GRIPHUB_IDLE_MS) || undefined,
});
// The app that spawned us is connected from the first byte, so early records reach it.
const stdio = listenPath ? undefined : hub.attach(stdioConn());

function send(record: object) {
	hub.emit(record);
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

/** Drop cumulative snapshots from streaming updates, like pi's JSON mode. */
function wireEvent(event: AgentSessionEvent): object {
	if (event.type === "message_end") return { ...event, message: withCost((event as any).message) };
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
	};
}

/** Every session (chat or background run) is built the same way. */
async function buildSession(sessionManager: SessionManager, opts: { interactive: boolean; onLimit: (reason: string) => void }) {
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
		tools: [...TOOLS, ...(opts.interactive ? ["subagent"] : []), ...mcpTools.map((t) => t.name)],
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

async function openSession(sessionManager: SessionManager) {
	unsubscribe?.();
	guard.cancelAll();
	session?.dispose();
	const result = await buildSession(sessionManager, {
		interactive: true,
		onLimit: (reason) => send({ type: "notice", message: reason }),
	});
	session = result.session;
	unsubscribe = session.subscribe((event) => {
		send({ type: "event", event: wireEvent(event) });
		onSessionEvent(event);
	});
	if (result.modelFallbackMessage) send({ type: "notice", message: result.modelFallbackMessage });
	return state();
}

/** Hooks on the active chat: model fallback and "done" notifications. */
function onSessionEvent(event: AgentSessionEvent) {
	if (event.type === "message_start" && lastPrompt) {
		const m = (event as any).message;
		if (m?.role === "user" && messageText(m).includes(lastPrompt.text)) lastPrompt = null;
	}
	if (event.type === "message_end") {
		const m = (event as any).message;
		if (m?.role === "assistant" && m.stopReason === "error") void tryFallback(String(m.errorMessage ?? ""));
	}
	if (event.type === "agent_end" || (event as any).type === "agent_settled") {
		const text = session?.getLastAssistantText?.() ?? "";
		send({
			type: "agent_done",
			sessionFile: session?.sessionFile ?? null,
			preview: text.slice(0, 200),
			// A fallback model is taking over (or already running): not finished, and not failed.
			retrying: fallbackPending || !!session?.isStreaming,
		});
		// Sync a little after the turn, so a quick follow-up doesn't cause two pushes.
		sync?.schedule(90_000);
	}
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

/** Rebuilds the active session so tool settings (shell, MCP tools) take effect. */
async function reopenSession() {
	const s = session!;
	if (s.isStreaming) throw new Error("Wait for the agent to finish first");
	const file = s.sessionFile;
	await openSession(file ? SessionManager.open(file) : SessionManager.create(s.sessionManager.getCwd()));
}

/** A headless session for the background runner. */
async function backgroundSession(cwd: string): Promise<RunSession> {
	let error: string | undefined;
	const { session: bg } = await buildSession(SessionManager.create(cwd || workspace), {
		interactive: false,
		onLimit: (reason) => (error = reason),
	});
	bg.subscribe((e) => {
		const m = (e as any).message;
		if (e.type === "message_end" && m?.role === "assistant" && m.stopReason === "error") error = m.errorMessage;
	});
	return {
		sessionFile: bg.sessionFile,
		prompt: async (text) => {
			checkBudget();
			await bg.prompt(text);
		},
		lastText: () => bg.getLastAssistantText(),
		errorText: () => error,
		abort: () => bg.abort(),
		dispose: () => bg.dispose(),
	};
}

const AGENTS_MARKER = "<!-- griphub:managed (delete this line to keep your own edits) -->";

/** Keeps the environment notes current, unless the user has taken the file over. */
function ensureAgentsFile() {
	const path = join(agentDir, "AGENTS.md");
	if (existsSync(path)) {
		const current = readFileSync(path, "utf8");
		const ours = current.includes(AGENTS_MARKER) || current.startsWith("# Environment\n\nYou are running inside GripHub AI Agent");
		if (!ours) return;
	}
	writeFileSync(
		path,
		`${AGENTS_MARKER}
# Environment

You are running inside GripHub AI Agent, an Android app, on the user's phone.

- The shell is Android's /system/bin/sh (mksh) with toybox utilities, not bash.
  Prefer POSIX sh syntax. There is no sudo, apt or pkg.
- On PATH: \`node\`, \`git\`, \`ssh\`, \`ssh-keygen\`, \`scp\`, \`rsync\`, \`curl\`, \`rg\`, \`fd\`.
  With scp, pass \`-S ssh\`.
- The workspace directory is ${workspace}. Projects live in subfolders of it.
  Keep files inside it unless asked otherwise.
- When the user has connected accounts in the app:
  - GitHub: \`$GITHUB_TOKEN\` is set and git is already authenticated for
    https://github.com (clone, pull, push work directly). Use the REST API
    with curl for everything else (issues, PRs, repos).
  - Vercel: \`$VERCEL_TOKEN\` is set for the Vercel REST API.
  - Cloudflare: \`$CLOUDFLARE_API_TOKEN\` and \`$CLOUDFLARE_ACCOUNT_ID\` are set,
    so wrangler in the Linux container works without logging in
    (\`box -c 'npx wrangler deploy'\`, D1/KV/R2 commands), as does the REST API.
  - SSH: saved servers are aliases in ~/.ssh/config, so \`ssh <name>\` works.
    The device key is ~/.ssh/id_ed25519.
- Linux container: when the user has installed one (Debian or Alpine, via
  proot), \`box -c '<command>'\` runs a command inside it, and \`box\` alone opens
  a shell. When it is enabled as your shell, every command already runs inside:
  use \`apt-get install -y\` (Debian) or \`apk add\` (Alpine) to get Python,
  Node.js, compilers and anything else. The home folder and workspace are the
  same paths inside and out.
- You have \`web_search\` and \`web_fetch\` tools. Use them before guessing how
  to install or use something, and to look up unfamiliar errors. With a
  Search1API key you also have \`web_screenshot\`, to see how a page looks
  (e.g. to check a site you built after deploying it).
- For tasks with three or more steps, call \`todo_write\` with your plan before
  starting, and keep it current (one step in_progress, each marked completed
  as soon as it is done). The user follows it in the app. In plan mode, write
  the plan as text first; call \`todo_write\` once it is approved.
- \`bash\` commands stop after ${BASH_TIMEOUT_SECONDS / 60} minutes unless you pass \`timeout\`
  (in seconds); pass a longer one for slow installs or builds.
- Dev servers: run them in the background (\`nohup npm run dev > dev.log 2>&1 &\`)
  and print the URL (e.g. http://localhost:5173); the app offers a live
  preview and a public link for any localhost port it sees.
- Some actions need the user's approval in the app; if one is declined, ask
  what they want instead rather than retrying.
- There is no display server; do not try to open GUIs or browsers. The app can
  preview HTML files you write.
- Files listed after "Attached files:" in a message are part of it. A
  \`pasted-text.txt\` there is text the user pasted into the message (the app
  attaches long pastes as files): read it before you answer.
`,
	);
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
		(await run("git", args, { cwd: dir }).catch(() => "")).split("\n").filter((l) => l.trim()).length;
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

function backupTarget() {
	const stamp = new Date().toISOString().slice(0, 16).replace(/[-:T]/g, "");
	const shared = "/storage/emulated/0/Download";
	const dir = existsSync(shared) ? join(shared, "GripHub") : join(workspace, "backups");
	try {
		mkdirSync(dir, { recursive: true });
		writeFileSync(join(dir, ".probe"), "");
		unlinkSync(join(dir, ".probe"));
		return join(dir, `griphub-backup-${stamp}.zip`);
	} catch {
		mkdirSync(join(workspace, "backups"), { recursive: true });
		return join(workspace, "backups", `griphub-backup-${stamp}.zip`);
	}
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

function restoreBackup(path: string) {
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
			checkBudget();
			fallbackTried = false;
			// Plan mode: ask for a plan first; tools that change things are blocked (guard.ts).
			const text = guard.planMode
				? `${cmd.text}\n\n[Plan mode] Investigate as needed, then reply with a numbered plan only. Do not change files or run commands that modify anything until I approve.`
				: cmd.text;
			// The agent may git push from its shell; don't hold the prompt for it.
			void integrations.githubFresh();
			// Don't await the run; progress arrives as events.
			s.prompt(text, {
				images: cmd.images,
				streamingBehavior: s.isStreaming ? (cmd.behavior ?? "followUp") : undefined,
			}).catch((e) => send({ type: "error", message: String(e?.message ?? e) }));
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
			return openSession(SessionManager.open(cmd.path));
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
		case "messages":
			return s.messages.map(withCost);

		// Accounts, repositories, SSH and deploys (integrations.ts).
		case "integrations":
			return integrations.summary();
		case "github_login":
			return integrations.githubLogin(cmd.token);
		case "github_device_start":
			return integrations.githubDeviceStart();
		case "github_device_poll":
			return integrations.githubDevicePoll(cmd.deviceCode);
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
		case "backup_create":
			return createBackup(!!cmd.includeWorkspace);
		case "backup_restore":
			return restoreBackup(cmd.path);

		// Linux container (container.ts).
		case "container_status":
			return container.status(settingsManager.getShellPath());
		case "container_install": {
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
			if (settingsManager.getShellPath() === container.shellPath) settingsManager.setShellPath(undefined);
			container.remove();
			await reopenSession();
			return container.status(settingsManager.getShellPath());
		case "container_enable":
			if (cmd.on && !container.status(undefined).installed) throw new Error("Install the container first");
			settingsManager.setShellPath(cmd.on ? container.shellPath : undefined);
			integrations.updateSettings({ containerShell: !!cmd.on });
			await settingsManager.flush();
			await reopenSession();
			return container.status(settingsManager.getShellPath());

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
		case "settings_get":
			return integrations.publicSettings();
		case "settings_set": {
			const out = integrations.updateSettings(cmd.settings ?? {});
			container.setNameservers(integrations.settings.dns);
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
		!runs?.running &&
		!runs?.runs.some((r) => r.status === "queued")
	);
}

let shuttingDown = false;
/** Ends the host. Subagents are stopped first, so each keeps a partial report instead of vanishing. */
async function shutdown(code = 0) {
	if (shuttingDown) return;
	shuttingDown = true;
	tunnels.stopAll();
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
	// A public tunnel (ssh -R) outlives its parent process: stop tunnels on
	// every shutdown path, not just stdin end. (A SIGKILL orphan cannot be
	// reaped by the app — the OS or user must kill that ssh.)
	for (const signal of ["SIGTERM", "SIGINT"] as const) process.on(signal, () => void shutdown(0));
	process.on("exit", () => tunnels.stopAll());
	mkdirSync(agentDir, { recursive: true });
	mkdirSync(workspace, { recursive: true });
	mkdirSync(stateDir, { recursive: true });
	ensureAgentsFile();

	// Route every lookup through DNS-over-HTTPS (configurable in settings).
	installDohLookup();
	integrations = new Integrations(agentDir, workspace);
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
	mcp = new Mcp(join(stateDir, "mcp.json"), () => send({ type: "mcp", servers: mcp.summary() }));
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
	// Linux container is the agent's shell by default once installed.
	if (
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
}

main().catch((e) => {
	log("fatal:", e?.stack ?? e);
	send({ type: "fatal", message: String(e?.message ?? e) });
	process.exit(1);
});
