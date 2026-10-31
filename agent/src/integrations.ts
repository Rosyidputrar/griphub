/**
 * Accounts, repositories, SSH and deploy targets for the GripHub AI Agent app.
 *
 * Credentials live in <agentDir>/griphub/integrations.json (app-private
 * storage) and are exported into the host's environment, so the agent's own
 * shell can use them too (git push, curl the GitHub API, deploy).
 */

import { spawn } from "node:child_process";
import { createHash, randomUUID } from "node:crypto";
import { copyFileSync, existsSync, lstatSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { basename, dirname, join, relative } from "node:path";
import { Cloudflare, type CloudflareAccount } from "./cloudflare.js";
import { configureDns, validateCustomDohUrl, type DnsMode } from "./dns.js";
import { maskKey, parseKeys } from "./keyring.js";
import { checkConfig, type NotifyConfig } from "./notify.js";
import { readSecureJson, writeSecureJson } from "./secure.js";

export interface SshHost {
	id: string;
	name: string;
	host: string;
	port: number;
	user: string;
	/** Default remote directory for deploys. */
	path?: string;
}

/**
 * A GitHub sign-in. Device-flow tokens from a GitHub App expire (8 hours) and
 * come with a refresh token (6 months); OAuth App tokens and pasted tokens
 * carry no expiry here. `expired` is set when GitHub rejected the token and it
 * could not be refreshed: the account stays listed so the app can ask the
 * user to sign in again instead of failing with a bare 401.
 */
interface GithubAccount {
	token: string;
	login: string;
	name: string | null;
	email: string;
	avatarUrl: string;
	refreshToken?: string;
	/** Epoch ms; absent when the token does not expire. */
	expiresAt?: number;
	refreshExpiresAt?: number;
	/** The Client ID the token was issued to; refreshing must use the same one. */
	clientId?: string;
	expired?: boolean;
}

/** What the device flow's token endpoint returns besides the access token. */
interface GithubGrant {
	refresh_token?: unknown;
	expires_in?: unknown;
	refresh_token_expires_in?: unknown;
}

/** Refresh this long before the access token runs out, so a long git push never starts on a dying token. */
const GITHUB_REFRESH_MARGIN_MS = 30 * 60_000;

/** Raised when GitHub no longer accepts the sign-in; the app shows "sign in again". */
export class GithubAuthError extends Error {
	readonly code = "github_auth_expired";
	constructor() {
		super("GitHub sign-in expired or was revoked. Sign in to GitHub again in Accounts.");
	}
}

interface Store {
	github?: GithubAccount;
	vercel?: { token: string; username: string };
	cloudflare?: { token: string; accounts: CloudflareAccount[]; accountId: string };
	sshHosts: SshHost[];
	settings?: AppSettings;
}

export interface AppSettings {
	dns: DnsMode;
	dnsUrl?: string;
	/** Search API keys, one per line (several are used in turn). */
	braveKey?: string;
	tavilyKey?: string;
	s1Key?: string;
	/** Which Search1API features the agent uses; unset means on. */
	s1Search?: boolean;
	s1Crawl?: boolean;
	s1Screenshot?: boolean;
	/** TinyFish Search key; unset means the engine is skipped, never an error. */
	tinyfishKey?: string;
	/** Whether the agent uses TinyFish Search; unset means on. */
	tinyfishSearch?: boolean;
	/** GripHub Router search backends (OpenAI Responses + Anthropic Messages); unset means on. */
	openaiSearch?: boolean;
	anthropicSearch?: boolean;
	/** Dedicated search models for the router backends; unset means the defaults below. */
	openaiSearchModel?: string;
	anthropicSearchModel?: string;
	/** Per-project web_search toggle, keyed by project path; absent means on. */
	projectSearch?: Record<string, boolean>;
	/** Per-backend switches for the keyed search tools; unset means on. */
	braveSearch?: boolean;
	tavilySearch?: boolean;
	/** Agent shell in the Linux container; unset means on whenever it is installed. */
	containerShell?: boolean;
	/** Server only: the phone's time zone ("Etc/GMT-7"), so schedules run at the user's hours, not the server's (UTC). */
	timeZone?: string | null;
	/** When the agent must ask before acting (see guard.ts). */
	approvalMode?: "ask_all" | "ask_risky" | "auto";
	/** Subagent limits, global for all subagents (see subagent.ts); 0 = no limit. */
	subagentCreditLimit?: number;
	subagentMinutesLimit?: number;
	/** Approval mode for subagents; unset = follow the chat's approvalMode. */
	subagentApprovalMode?: "ask_all" | "ask_risky" | "auto";
	/** Subagent notification toggles; unset = on. */
	subagentNotifyDone?: boolean;
	subagentNotifyFailed?: boolean;
	subagentNotifyApproval?: boolean;
	/** Ongoing "subagent running" notification while subagents of other chats work; unset = on. */
	subagentNotifyRunning?: boolean;
	/**
	 * Push notifications through ntfy while the app is closed (server agent only; notify.ts). Off until the user turns
	 * them on; the app makes the random topic. An empty url means https://ntfy.sh.
	 */
	notify?: { enabled?: boolean; url?: string; topic?: string };
	/** Tried in order when the current model errors out (rate limits, outages). */
	fallbackModels?: { provider: string; model: string }[];
	/** Daily spend cap in GripHub credits; prompts are refused once reached. 0 or unset = none. */
	dailyBudget?: number;
	/**
	 * Summarize the chat once its context passes this many tokens (host.ts capContext), on models whose own limit is
	 * larger: every request re-reads the whole context, so a 1M-token model would otherwise pay for ~850k tokens a
	 * request before pi compacts it. Unset means the default share of the model's window (COMPACT_AT_SHARE, but never
	 * under COMPACT_AT_DEFAULT); 0 leaves it to pi (near the model's limit).
	 */
	compactAt?: number;
	/**
	 * GitHub OAuth App Client ID for the device flow, entered in
	 * Settings (Accounts). Sets the Client ID without a rebuild:
	 * create your own OAuth App (Device Flow enabled) and paste its
	 * Client ID here. The ID is public; there is no secret. Empty
	 * means GitHub login is not configured.
	 */
	githubClientId?: string;
}

const DEFAULT_SETTINGS: AppSettings = { dns: "cloudflare" };
/** A server resolves names itself: no ISP block pages to get around, and DoH would only add a hop. */
const SERVER_DEFAULT_SETTINGS: AppSettings = { dns: "system" };

/**
 * With no limit set, a chat is summarized once it fills this share of the model's window (host.ts capContext): room
 * enough that a summary is rarely met, while a request never re-reads the better part of a very large window.
 */
export const COMPACT_AT_SHARE = 0.65;

/**
 * The least a default limit can be, in tokens (and the default itself when the model's window is unknown). A flat
 * share alone would summarize a 200k model at 130k, more eagerly than before this default followed the window; under
 * this floor the chat is left to pi, which compacts near the model's own limit anyway.
 */
export const COMPACT_AT_DEFAULT = 300_000;

/**
 * The context limit in force for a model whose window is [contextWindow] tokens: the user's own ([compactAt]; 0 turns
 * the host's summaries off), or the default share of the window, never under the floor. Models at or under the floor
 * are left to pi either way: capContext only acts when the window is larger than the limit.
 */
export function compactLimit(compactAt: number | undefined, contextWindow: number | undefined): number {
	if (typeof compactAt === "number" && compactAt >= 0) return compactAt;
	return Math.max(COMPACT_AT_DEFAULT, Math.round(((contextWindow ?? 0) * COMPACT_AT_SHARE) / 1_000) * 1_000);
}

/** Where pushes go when the user turned them on without naming a server. */
export const NTFY_DEFAULT_URL = "https://ntfy.sh";

export interface IntegrationsOptions {
	/** The host runs as a server agent (server_agent.md). */
	server?: boolean;
	/** On a server: the `box` launcher when the rootless container is set up, else null (commands run on the server). */
	boxScript?: () => string | null;
}

/** Optional build-time override for the GitHub OAuth App Client ID (device flow enabled). Public by design; no secret is used. Empty means not configured. */
const GITHUB_CLIENT_ID = process.env.GRIPHUB_GITHUB_CLIENT_ID ?? "";

/** Line output, plus an optional channel for structured CI progress. */
export type Log = ((line: string) => void) & { ci?: (snapshot: CiSnapshot) => void };

export interface CiStep {
	name: string;
	status: string;
	conclusion: string | null;
}
export interface CiJob extends CiStep {
	steps: CiStep[];
}
export interface CiRun extends CiStep {
	id: string;
	url: string | null;
	jobs: CiJob[];
}
export interface CiSnapshot {
	provider: "github" | "vercel" | "cloudflare";
	runs: CiRun[];
}

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
const FAILED = new Set(["failure", "cancelled", "timed_out", "startup_failure", "action_required"]);

export type KeyService = "brave" | "tavily" | "s1" | "tinyfish";
const KEY_FIELD = { brave: "braveKey", tavily: "tavilyKey", s1: "s1Key", tinyfish: "tinyfishKey" } as const;

export class Integrations {
	private store: Store = { sshHosts: [] };
	private readonly file: string;
	private readonly home: string;

	constructor(
		agentDir: string,
		private readonly workspace: string,
		private readonly options: IntegrationsOptions = {},
	) {
		const dir = join(agentDir, "griphub");
		mkdirSync(dir, { recursive: true });
		this.file = join(dir, "integrations.json");
		this.home = process.env.HOME ?? agentDir;
		// Encrypted at rest when the Keystore key is available (see secure.ts).
		this.store = { sshHosts: [], ...readSecureJson<Partial<Store>>(this.file, {}) };
		this.exportEnv();
		this.applySettings();
	}

	get settings(): AppSettings {
		return { ...(this.options.server ? SERVER_DEFAULT_SETTINGS : DEFAULT_SETTINGS), ...this.store.settings };
	}

	/** Where to send pushes, or null while they are off or not set up. */
	notifyConfig(): NotifyConfig | null {
		const n = this.settings.notify;
		if (n?.enabled !== true || !n.topic) return null;
		return { url: n.url || NTFY_DEFAULT_URL, topic: n.topic };
	}

	/** Keys are write-only from the app's point of view: it only sees their last four characters. */
	publicSettings() {
		const { dns, dnsUrl, braveKey, tavilyKey, s1Key, tinyfishKey, approvalMode, fallbackModels, dailyBudget, subagentCreditLimit, subagentMinutesLimit, subagentApprovalMode, subagentNotifyDone, subagentNotifyFailed, subagentNotifyApproval, subagentNotifyRunning } = this.settings;
		const masked = (text?: string) => parseKeys(text).map(maskKey);
		return {
			dns,
			dnsUrl: dnsUrl ?? null,
			braveKey: !!braveKey,
			tavilyKey: !!tavilyKey,
			keys: { brave: masked(braveKey), tavily: masked(tavilyKey), s1: masked(s1Key), tinyfish: masked(tinyfishKey) },
			s1Search: this.settings.s1Search ?? true,
			s1Crawl: this.settings.s1Crawl ?? true,
			s1Screenshot: this.settings.s1Screenshot ?? true,
			tinyfishSearch: this.settings.tinyfishSearch ?? true,
			openaiSearch: this.settings.openaiSearch ?? true,
			anthropicSearch: this.settings.anthropicSearch ?? true,
			openaiSearchModel: this.settings.openaiSearchModel ?? "gpt-5.6-luna",
			anthropicSearchModel: this.settings.anthropicSearchModel ?? "claude-haiku-5.5",
			projectSearch: this.settings.projectSearch ?? {},
			braveSearch: this.settings.braveSearch ?? true,
			tavilySearch: this.settings.tavilySearch ?? true,
			approvalMode: approvalMode ?? "ask_risky",
			fallbackModels: fallbackModels ?? [],
			dailyBudget: dailyBudget ?? 0,
			// Null while the user set nothing: the limit then follows the open chat's model (compactLimit). An app too old
			// to know the share shows its old default instead, which only mislabels the row. The floor is the fallback.
			compactAt: this.settings.compactAt ?? null,
			compactAtShare: COMPACT_AT_SHARE,
			compactAtFloor: COMPACT_AT_DEFAULT,
			// Public by design (an OAuth App's Client ID is no secret). It was left out, so the app never showed the one
			// saved, and said "built-in" for a build that has none.
			githubClientId: (this.settings.githubClientId ?? "").trim(),
			githubClientIdBuiltIn: !!GITHUB_CLIENT_ID,
			subagentCreditLimit: subagentCreditLimit ?? 50,
			subagentMinutesLimit: subagentMinutesLimit ?? 30,
			subagentApprovalMode: subagentApprovalMode ?? approvalMode ?? "ask_risky",
			// False while subagents follow the chat's approval mode (no override saved).
			subagentApprovalOverride: subagentApprovalMode != null,
			subagentNotifyDone: subagentNotifyDone ?? true,
			subagentNotifyFailed: subagentNotifyFailed ?? true,
			subagentNotifyApproval: subagentNotifyApproval ?? true,
			subagentNotifyRunning: subagentNotifyRunning ?? true,
			// The topic is shown to its owner so they can subscribe to it; it is not a credential for anything else.
			notify: { enabled: this.settings.notify?.enabled === true, url: this.settings.notify?.url || NTFY_DEFAULT_URL, topic: this.settings.notify?.topic ?? null },
		};
	}

	updateSettings(patch: Partial<AppSettings>) {
		if (patch.notify) {
			const merged = { ...this.settings.notify, ...patch.notify };
			const problem = checkConfig({ url: merged.url || NTFY_DEFAULT_URL, topic: merged.topic });
			// Turning them off never needs a valid address.
			if (merged.enabled === true && problem) throw new Error(`Notifications: ${problem}`);
			patch = { ...patch, notify: merged };
		}
		const next: AppSettings = { ...this.settings };
		for (const [k, v] of Object.entries(patch)) {
			if (v === undefined) continue;
			(next as any)[k] = v === "" || v === null ? undefined : v;
		}
		// Validate a custom DoH URL before it is saved: a malformed URL must
		// be rejected with an error here, not stored and then silently
		// ignored (or worse, crash the host) on the next boot.
		if (patch.dns !== undefined || patch.dnsUrl !== undefined) {
			if (next.dns === "custom") {
				const err = validateCustomDohUrl(next.dnsUrl ?? "");
				if (err) throw new Error(`Invalid custom DoH URL: ${err}`);
			}
		}
		// Subagent limits: 0 means no limit; anything else must be a positive number
		// (whole minutes). A bad value would otherwise stop every subagent at once.
		const limit = (v: unknown, whole: boolean) =>
			typeof v === "number" && Number.isFinite(v) && v >= 0 && (!whole || Number.isInteger(v));
		if (next.subagentCreditLimit !== undefined && !limit(next.subagentCreditLimit, false)) {
			throw new Error("The subagent cost limit must be 0 (no limit) or a positive number");
		}
		if (next.subagentMinutesLimit !== undefined && !limit(next.subagentMinutesLimit, true)) {
			throw new Error("The subagent time limit must be 0 (no limit) or a whole number of minutes");
		}
		// 0 turns the host's summaries off (pi's own stay); anything else must be a sane token count.
		if (next.compactAt !== undefined && !(typeof next.compactAt === "number" && Number.isInteger(next.compactAt) && next.compactAt >= 0)) {
			throw new Error("The context limit must be 0 (the model's own limit) or a whole number of tokens");
		}
		this.store.settings = next;
		this.save();
		this.applySettings();
		return this.publicSettings();
	}

	private applySettings() {
		const s = this.settings;
		configureDns(s.dns, s.dnsUrl);
	}

	searchKeys() {
		const s = this.settings;
		return {
			brave: parseKeys(s.braveKey),
			tavily: parseKeys(s.tavilyKey),
			s1: parseKeys(s.s1Key),
			tinyfish: parseKeys(s.tinyfishKey),
			s1Search: s.s1Search ?? true,
			s1Crawl: s.s1Crawl ?? true,
			s1Screenshot: s.s1Screenshot ?? true,
			tinyfishSearch: s.tinyfishSearch ?? true,
			openaiSearch: s.openaiSearch ?? true,
			anthropicSearch: s.anthropicSearch ?? true,
			openaiSearchModel: s.openaiSearchModel ?? "gpt-5.6-luna",
			anthropicSearchModel: s.anthropicSearchModel ?? "claude-haiku-5.5",
			projectSearch: s.projectSearch ?? {},
			braveSearch: s.braveSearch ?? true,
			tavilySearch: s.tavilySearch ?? true,
		};
	}

	/** Adds the keys found in pasted text (one per line) to a service's keys; returns how many were new. */
	addSearchKeys(service: KeyService, text: string) {
		const field = KEY_FIELD[service];
		if (!field) throw new Error(`Unknown service: ${service}`);
		const have = parseKeys(this.settings[field]);
		const fresh = parseKeys(text).filter((k) => !have.includes(k));
		if (fresh.length) this.updateSettings({ [field]: [...have, ...fresh].join("\n") });
		return { added: fresh.length, settings: this.publicSettings() };
	}

	/** Removes a service's key by its position in the list publicSettings shows. */
	removeSearchKey(service: KeyService, index: number) {
		const field = KEY_FIELD[service];
		if (!field) throw new Error(`Unknown service: ${service}`);
		const keys = parseKeys(this.settings[field]);
		keys.splice(index, 1);
		return this.updateSettings({ [field]: keys.join("\n") });
	}

	private save() {
		writeSecureJson(this.file, this.store);
		this.exportEnv();
	}

	/** Tokens become env vars for everything the agent runs. */
	private exportEnv() {
		const gh = this.store.github?.token;
		for (const key of ["GITHUB_TOKEN", "GH_TOKEN"]) {
			if (gh) process.env[key] = gh;
			else delete process.env[key];
		}
		if (this.store.vercel) process.env.VERCEL_TOKEN = this.store.vercel.token;
		else delete process.env.VERCEL_TOKEN;
		// What wrangler reads, so the agent can use it without logging in.
		const cf = this.store.cloudflare;
		if (cf) {
			process.env.CLOUDFLARE_API_TOKEN = cf.token;
			process.env.CLOUDFLARE_ACCOUNT_ID = cf.accountId;
		} else {
			delete process.env.CLOUDFLARE_API_TOKEN;
			delete process.env.CLOUDFLARE_ACCOUNT_ID;
		}
	}

	summary() {
		const { github, vercel, cloudflare, sshHosts } = this.store;
		const pub = join(this.home, ".ssh", "id_ed25519.pub");
		return {
			github: github ? { login: github.login, name: github.name, avatarUrl: github.avatarUrl, expired: !!github.expired } : null,
			vercel: vercel ? { username: vercel.username } : null,
			cloudflare: cloudflare ? { accounts: cloudflare.accounts, accountId: cloudflare.accountId } : null,
			ssh: { publicKey: existsSync(pub) ? readFileSync(pub, "utf8").trim() : null, hosts: sshHosts },
		};
	}

	// -------------------------------------------------------------------------
	// GitHub

	/**
	 * Calls the GitHub REST API with the stored sign-in, refreshing it first when
	 * it is about to expire. A 401 refreshes once and retries; when that is not
	 * possible the account is marked expired and a GithubAuthError is thrown.
	 * An explicit [token] (signing in) is used as is.
	 */
	private async github(path: string, init: RequestInit = {}, token?: string): Promise<any> {
		if (token) return this.githubRequest(path, init, token);
		if (!this.store.github) throw new Error("Not signed in to GitHub");
		const fresh = await this.githubToken();
		try {
			return await this.githubRequest(path, init, fresh);
		} catch (e) {
			if ((e as any)?.status !== 401) throw e;
			// Rejected before its expiry (revoked, or the clock is off): one refresh, one retry.
			const again = await this.githubToken(true);
			try {
				return await this.githubRequest(path, init, again);
			} catch (e2) {
				if ((e2 as any)?.status === 401) this.markGithubExpired();
				throw (e2 as any)?.status === 401 ? new GithubAuthError() : e2;
			}
		}
	}

	private async githubRequest(path: string, init: RequestInit, token: string) {
		const res = await fetch(`https://api.github.com${path}`, {
			...init,
			signal: init.signal ?? AbortSignal.timeout(30_000),
			headers: {
				Accept: "application/vnd.github+json",
				Authorization: `Bearer ${token}`,
				"X-GitHub-Api-Version": "2022-11-28",
				...(init.body ? { "Content-Type": "application/json" } : {}),
				...init.headers,
			},
		});
		const body = res.status === 204 ? null : await res.json().catch(() => null);
		if (!res.ok) {
			const message = (body as any)?.message ?? res.statusText;
			const err = new Error(`GitHub: ${message} (${res.status})`) as Error & { status?: number };
			err.status = res.status;
			throw err;
		}
		return body as any;
	}

	/** GitHub REST call with the stored token, for other modules. */
	githubApi(path: string, init: RequestInit = {}) {
		return this.github(path, init);
	}

	async githubLogin(token: string, grant?: GithubGrant & { clientId?: string }) {
		token = token.trim();
		const user = await this.github("/user", {}, token);
		this.store.github = {
			token,
			login: user.login,
			name: user.name ?? null,
			email: user.email ?? `${user.id}+${user.login}@users.noreply.github.com`,
			avatarUrl: user.avatar_url,
			...this.grantFields(grant, grant?.clientId),
		};
		this.save();
		await this.configureGit();
		return this.summary();
	}

	/** Expiry and refresh fields from a token response; empty for tokens that do not expire. */
	private grantFields(grant: GithubGrant | undefined, clientId: string | undefined): Partial<GithubAccount> {
		const now = Date.now();
		const secs = (v: unknown) => (typeof v === "number" && v > 0 ? v : typeof v === "string" && Number(v) > 0 ? Number(v) : 0);
		const expiresIn = secs(grant?.expires_in);
		const refreshToken = typeof grant?.refresh_token === "string" && grant.refresh_token ? grant.refresh_token : undefined;
		return {
			refreshToken,
			expiresAt: expiresIn ? now + expiresIn * 1000 : undefined,
			refreshExpiresAt: secs(grant?.refresh_token_expires_in) ? now + secs(grant?.refresh_token_expires_in) * 1000 : undefined,
			clientId: refreshToken ? clientId : undefined,
			expired: false,
		};
	}

	private refreshing?: Promise<string>;

	/**
	 * The current access token, refreshed when it expires within the margin (or
	 * now, with [force]). Single-flight: GitHub rotates the refresh token on use,
	 * so two refreshes at once would sign the user out.
	 */
	async githubToken(force = false): Promise<string> {
		const gh = this.store.github;
		if (!gh) throw new Error("Not signed in to GitHub");
		if (gh.expired) throw new GithubAuthError();
		const due = gh.expiresAt !== undefined && Date.now() >= gh.expiresAt - GITHUB_REFRESH_MARGIN_MS;
		if (!force && !due) return gh.token;
		if (!gh.refreshToken || !gh.clientId) {
			// Nothing to refresh with: a token that has already expired is dead; otherwise try it.
			if (gh.expiresAt !== undefined && Date.now() >= gh.expiresAt) {
				this.markGithubExpired();
				throw new GithubAuthError();
			}
			if (force) {
				this.markGithubExpired();
				throw new GithubAuthError();
			}
			return gh.token;
		}
		this.refreshing ??= this.refreshGithub(gh).finally(() => {
			this.refreshing = undefined;
		});
		return this.refreshing;
	}

	private async refreshGithub(gh: GithubAccount): Promise<string> {
		if (gh.refreshExpiresAt !== undefined && Date.now() >= gh.refreshExpiresAt) {
			this.markGithubExpired();
			throw new GithubAuthError();
		}
		// Device-flow tokens refresh without a client secret (GitHub docs, "Refreshing user access tokens").
		// A network failure throws here without touching the account, so the next call tries again.
		const r = await this.githubOAuth("/login/oauth/access_token", {
			client_id: gh.clientId!,
			grant_type: "refresh_token",
			refresh_token: gh.refreshToken!,
		});
		if (typeof r.access_token !== "string" || !r.access_token) {
			// bad_refresh_token, unauthorized_client, ...: only a new sign-in helps.
			this.markGithubExpired();
			throw new GithubAuthError();
		}
		// Signed out or re-signed in meanwhile: leave the newer account alone. (Not githubToken():
		// this promise is still the in-flight refresh, so that would wait on itself.)
		if (this.store.github !== gh) {
			if (!this.store.github) throw new Error("Not signed in to GitHub");
			return this.store.github.token;
		}
		const fields = this.grantFields(r, gh.clientId);
		// GitHub rotates the refresh token on every use; should a response lack one, keep the old one.
		if (!fields.refreshToken) {
			delete fields.refreshToken;
			delete fields.refreshExpiresAt;
			delete fields.clientId;
		}
		Object.assign(gh, { token: r.access_token, ...fields });
		this.save();
		await this.configureGit();
		return gh.token;
	}

	/** Refreshes the token if it is due, for callers about to run git; never throws. */
	async githubFresh() {
		if (!this.store.github || this.store.github.expired) return;
		await this.githubToken().catch(() => {});
	}

	private markGithubExpired() {
		const gh = this.store.github;
		if (!gh || gh.expired) return;
		gh.expired = true;
		this.save();
		this.onChange?.();
	}

	/** Called when the account summary changes on its own (a sign-in expiring), so the app can redraw. */
	onChange?: () => void;

	/**
	 * The OAuth App Client ID for the device flow: the one entered in
	 * Settings wins, then the build-time env var. There is deliberately
	 * no built-in default: the upstream template's OAuth App ID must
	 * never be used, so an empty result means "not configured".
	 */
	private get githubClientId() {
		return (this.settings.githubClientId ?? "").trim() || GITHUB_CLIENT_ID;
	}

	/**
	 * GitHub device flow: the user types a short code at github.com/login/device
	 * instead of creating and pasting a token. Needs the Client ID of an OAuth
	 * App with "Enable Device Flow" ticked (the ID is public; there is no secret).
	 */
	async githubDeviceStart() {
		if (!this.githubClientId) {
			throw new Error("Sign-in with a code needs a GitHub OAuth Client ID. Paste one under Advanced, or sign in with a token.");
		}
		const r = await this.githubOAuth("/login/device/code", { client_id: this.githubClientId, scope: "repo workflow read:org" });
		if (r.error || !r.device_code) {
			// "device_flow_disabled" means the OAuth App exists but the Device Flow box is not ticked.
			throw new Error((r.error_description as string) ?? (r.error as string) ?? "GitHub did not return a device code");
		}
		return {
			deviceCode: r.device_code as string,
			userCode: r.user_code as string,
			verificationUri: (r.verification_uri as string) ?? "https://github.com/login/device",
			expiresIn: (r.expires_in as number) ?? 900,
			interval: (r.interval as number) ?? 5,
		};
	}

	/** One poll of the device flow. The app calls this every `interval` seconds until it is not pending. */
	async githubDevicePoll(deviceCode: string) {
		const r = await this.githubOAuth("/login/oauth/access_token", {
			client_id: this.githubClientId,
			device_code: deviceCode,
			grant_type: "urn:ietf:params:oauth:grant-type:device_code",
		});
		if (r.access_token) {
			return { status: "done", state: await this.githubLogin(r.access_token as string, { ...r, clientId: this.githubClientId }) };
		}
		switch (r.error) {
			case "authorization_pending":
				return { status: "pending" };
			case "slow_down":
				return { status: "slow_down", interval: r.interval as number | undefined };
			case "expired_token":
				return { status: "expired" };
			case "access_denied":
				return { status: "denied" };
			default:
				throw new Error((r.error_description as string) ?? (r.error as string) ?? "GitHub login failed");
		}
	}

	private async githubOAuth(path: string, body: Record<string, string>) {
		const res = await fetch(`https://github.com${path}`, {
			method: "POST",
			signal: AbortSignal.timeout(30_000),
			headers: { Accept: "application/json", "Content-Type": "application/json", "User-Agent": "GripHub AI Agent" },
			body: JSON.stringify(body),
		});
		const text = await res.text();
		let json: Record<string, unknown>;
		try {
			json = JSON.parse(text);
		} catch {
			throw new Error(`GitHub answered ${res.status}: ${text.slice(0, 200)}`);
		}
		if (!res.ok && !json.error) throw new Error(`GitHub answered ${res.status}`);
		return json;
	}

	async githubLogout() {
		delete this.store.github;
		this.save();
		await this.configureGit();
		return this.summary();
	}

	/**
	 * Commit identity plus an auth header for github.com. A header rather than
	 * a credential helper: helpers run through git's compiled-in shell path,
	 * which does not exist on Android.
	 */
	private async configureGit() {
		const gh = this.store.github;
		const key = "http.https://github.com/.extraheader";
		await run("git", ["config", "--global", "--unset-all", key], { cwd: this.home }).catch(() => {});
		if (!gh) return;
		const basic = Buffer.from(`x-access-token:${gh.token}`).toString("base64");
		await run("git", ["config", "--global", "--add", key, `Authorization: Basic ${basic}`], { cwd: this.home });
		await run("git", ["config", "--global", "user.name", gh.name ?? gh.login], { cwd: this.home });
		await run("git", ["config", "--global", "user.email", gh.email], { cwd: this.home });
		await run("git", ["config", "--global", "init.defaultBranch", "main"], { cwd: this.home });
	}

	async repos() {
		const clones = await this.workspaceClones();
		const list: any[] = [];
		for (let page = 1; page <= 5; page++) {
			const batch = await this.github(
				`/user/repos?per_page=100&page=${page}&sort=pushed&affiliation=owner,collaborator,organization_member`,
			);
			list.push(...batch);
			if (batch.length < 100) break;
		}
		return list.map((r) => ({
			fullName: r.full_name,
			name: r.name,
			owner: r.owner?.login,
			private: r.private,
			description: r.description ?? null,
			language: r.language ?? null,
			stars: r.stargazers_count ?? 0,
			pushedAt: r.pushed_at,
			defaultBranch: r.default_branch,
			...this.clonedAt(r.full_name, clones),
		}));
	}

	/**
	 * Workspace folders that are clones of a GitHub repository, keyed by
	 * lower-cased "owner/repo" (GitHub names are case-insensitive). Matched on
	 * the origin remote, never on the folder name: akun1/repo1 and akun2/repo1
	 * are different repositories that would both want the folder "repo1".
	 */
	private async workspaceClones(): Promise<Map<string, string>> {
		const out = new Map<string, string>();
		let names: string[] = [];
		try {
			names = readdirSync(this.workspace);
		} catch {
			return out;
		}
		await Promise.all(
			names.map(async (name) => {
				const dir = join(this.workspace, name);
				if (name.startsWith(".") || !existsSync(join(dir, ".git"))) return;
				// The URL as configured; `remote get-url` would apply url.insteadOf rewrites.
				const origin = (await run("git", ["config", "--get", "remote.origin.url"], { cwd: dir }).catch(() => "")).trim();
				const slug = parseGithubSlug(origin)?.toLowerCase();
				// Two folders with the same origin: the one named after the repo wins, as before.
				if (slug && (!out.has(slug) || name.toLowerCase() === slug.split("/")[1])) out.set(slug, dir);
			}),
		);
		return out;
	}

	private clonedAt(fullName: string, clones: Map<string, string>) {
		const path = clones.get(fullName.toLowerCase());
		return { cloned: path !== undefined, path: path ?? null };
	}

	/**
	 * The folder a new clone of [fullName] goes to: the repository's name, or
	 * "<name>-<owner>" (then "-2", "-3", ...) when that name is taken by any
	 * other file or folder.
	 */
	private cloneDest(fullName: string): string {
		const [owner, name] = fullName.split("/");
		const free = (n: string) => !existsSync(join(this.workspace, n));
		if (free(name)) return join(this.workspace, name);
		const base = `${name}-${owner}`;
		if (free(base)) return join(this.workspace, base);
		for (let i = 2; ; i++) if (free(`${base}-${i}`)) return join(this.workspace, `${base}-${i}`);
	}

	async clone(fullName: string, log: Log) {
		if (!/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/.test(fullName) || fullName.split("/").some((p) => p === "." || p === "..")) {
			throw new Error(`Not a GitHub repository name: ${fullName}`);
		}
		const existing = (await this.workspaceClones()).get(fullName.toLowerCase());
		if (existing) {
			log(`${fullName} is already cloned in ${basename(existing)}`);
			return { path: existing };
		}
		mkdirSync(this.workspace, { recursive: true });
		const dest = this.cloneDest(fullName);
		await run("git", ["clone", "--progress", `https://github.com/${fullName}.git`, dest], {
			cwd: this.workspace,
			log,
		});
		return { path: dest };
	}

	// -------------------------------------------------------------------------
	// Projects in the workspace

	async projects() {
		const out = [];
		for (const name of readdirSync(this.workspace)) {
			const dir = join(this.workspace, name);
			if (name.startsWith(".") || !statSync(dir).isDirectory()) continue;
			const git = existsSync(join(dir, ".git"));
			let branch: string | null = null;
			let remote: string | null = null;
			let dirty = false;
			if (git) {
				branch = (await run("git", ["branch", "--show-current"], { cwd: dir }).catch(() => "")).trim() || null;
				remote = (await run("git", ["remote", "get-url", "origin"], { cwd: dir }).catch(() => "")).trim() || null;
				dirty = (await run("git", ["status", "--porcelain"], { cwd: dir }).catch(() => "")).trim().length > 0;
			}
			out.push({ name, path: dir, git, branch, remote, dirty, modified: statSync(dir).mtimeMs });
		}
		return out.sort((a, b) => b.modified - a.modified);
	}

	// -------------------------------------------------------------------------
	// SSH

	async sshKey() {
		const key = join(this.home, ".ssh", "id_ed25519");
		mkdirSync(join(this.home, ".ssh"), { recursive: true, mode: 0o700 });
		if (!existsSync(key)) {
			await run("ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-C", "griphub", "-f", key], { cwd: this.home });
		}
		return readFileSync(`${key}.pub`, "utf8").trim();
	}

	saveSshHost(host: Partial<SshHost>) {
		if (!host.host || !host.user) throw new Error("Host and user are required");
		const entry: SshHost = {
			id: host.id ?? randomUUID(),
			name: sanitizeAlias(host.name || host.host),
			host: host.host.trim(),
			port: Number(host.port) || 22,
			user: host.user.trim(),
			path: host.path?.trim() || undefined,
		};
		const i = this.store.sshHosts.findIndex((h) => h.id === entry.id);
		if (i >= 0) this.store.sshHosts[i] = entry;
		else this.store.sshHosts.push(entry);
		this.save();
		this.writeSshConfig();
		return this.summary();
	}

	deleteSshHost(id: string) {
		this.store.sshHosts = this.store.sshHosts.filter((h) => h.id !== id);
		this.save();
		this.writeSshConfig();
		return this.summary();
	}

	/** Saved hosts become aliases in ~/.ssh/config so `ssh <name>` just works. */
	private writeSshConfig() {
		const file = join(this.home, ".ssh", "config");
		const begin = "# >>> griphub hosts (managed) >>>";
		const end = "# <<< griphub hosts <<<";
		let current = existsSync(file) ? readFileSync(file, "utf8") : "";
		const a = current.indexOf(begin);
		const b = current.indexOf(end);
		if (a >= 0 && b > a) current = current.slice(0, a) + current.slice(b + end.length);
		const key = join(this.home, ".ssh", "id_ed25519");
		const blocks = this.store.sshHosts.map(
			(h) =>
				`Host ${h.name}\n  HostName ${h.host}\n  User ${h.user}\n  Port ${h.port}\n  IdentityFile ${key}\n  UserKnownHostsFile ${join(this.home, ".ssh", "known_hosts")}\n  StrictHostKeyChecking accept-new\n`,
		);
		const managed = blocks.length ? `${begin}\n${blocks.join("\n")}${end}\n` : "";
		mkdirSync(join(this.home, ".ssh"), { recursive: true, mode: 0o700 });
		writeFileSync(file, `${managed}${current.trim() ? `\n${current.trim()}\n` : ""}`, { mode: 0o600 });
	}

	async sshTest(id: string, log: Log) {
		const h = this.host(id);
		await run("ssh", ["-F", join(this.home, ".ssh", "config"), "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", h.name, "echo connected: $(uname -sn)"], {
			cwd: this.home,
			log,
		});
		return { ok: true };
	}

	private host(id: string) {
		const h = this.store.sshHosts.find((x) => x.id === id);
		if (!h) throw new Error("Unknown SSH host");
		return h;
	}

	// -------------------------------------------------------------------------
	// Vercel

	private async vercel(path: string, init: RequestInit = {}, token = this.store.vercel?.token) {
		if (!token) throw new Error("Not connected to Vercel");
		const res = await fetch(`https://api.vercel.com${path}`, {
			...init,
			signal: init.signal ?? AbortSignal.timeout(30_000),
			headers: { Authorization: `Bearer ${token}`, ...init.headers },
		});
		const body = await res.json().catch(() => null);
		if (!res.ok) throw new Error(`Vercel: ${(body as any)?.error?.message ?? res.statusText} (${res.status})`);
		return body as any;
	}

	async vercelLogin(token: string) {
		token = token.trim();
		const { user } = await this.vercel("/v2/user", {}, token);
		this.store.vercel = { token, username: user.username ?? user.email };
		this.save();
		return this.summary();
	}

	vercelLogout() {
		delete this.store.vercel;
		this.save();
		return this.summary();
	}

	// -------------------------------------------------------------------------
	// Cloudflare (cloudflare.ts)

	async cloudflareLogin(token: string) {
		token = token.trim();
		const accounts = await Cloudflare.accounts(token);
		this.store.cloudflare = { token, accounts, accountId: accounts[0].id };
		this.save();
		return this.summary();
	}

	cloudflareSelectAccount(accountId: string) {
		const cf = this.store.cloudflare;
		if (!cf) throw new Error("Not connected to Cloudflare");
		if (!cf.accounts.some((a) => a.id === accountId)) throw new Error("Unknown Cloudflare account");
		cf.accountId = accountId;
		this.save();
		return this.summary();
	}

	cloudflareLogout() {
		delete this.store.cloudflare;
		this.save();
		return this.summary();
	}

	private cloudflare() {
		const cf = this.store.cloudflare;
		if (!cf) throw new Error("Not connected to Cloudflare");
		return new Cloudflare(cf.token, cf.accountId);
	}

	/** Commands in the Linux container (wrangler and npm live there), when it is installed. */
	private containerRunner() {
		if (this.options.server) return this.serverRunner();
		const rootfs = process.env.GRIPHUB_ROOTFS;
		const available = !!rootfs && existsSync(join(rootfs, "etc"));
		return {
			available,
			run: async (cmd: string, args: string[], opts: { cwd: string; log?: Log }) => {
				try {
					return await run(cmd, args, opts);
				} catch (e) {
					// bash says "npm: command not found", busybox sh "npm: not found".
					if (/\b(npx|npm): (command )?not found/.test((e as Error).message)) {
						const alpine = !!rootfs && existsSync(join(rootfs, "etc", "alpine-release"));
						const install = alpine ? "apk add nodejs npm" : "apt-get install -y nodejs npm";
						throw new Error(`Node.js isn't installed in the Linux container. Ask the agent to install it (${install}), then deploy again.`);
					}
					throw e;
				}
			},
		};
	}

	/**
	 * On a server, `box -c` is the rootless container when it is set up (the same launcher the agent's shell uses), and
	 * a plain shell on the server otherwise: Node.js is installed there for the host, so wrangler and npm can run.
	 */
	private serverRunner() {
		const box = this.options.boxScript?.() ?? null;
		return {
			available: true,
			run: async (cmd: string, args: string[], opts: { cwd: string; log?: Log }) => {
				try {
					return await run(cmd === "box" ? (box ?? "/bin/sh") : cmd, args, opts);
				} catch (e) {
					if (box && /\b(npx|npm): (command )?not found/.test((e as Error).message)) {
						throw new Error("Node.js isn't installed in the box. Ask the agent to install it (apt-get install -y nodejs npm), then deploy again.");
					}
					throw e;
				}
			},
		};
	}

	/** `npm run build` (installing dependencies first if needed) in the container, before a deploy. */
	private async build(root: string, log: Log) {
		const container = this.containerRunner();
		if (!container.available) {
			throw new Error("Building needs the Linux container with Node.js (Settings > Linux container). Or build the project first and deploy its output folder.");
		}
		if (!existsSync(join(root, "package.json"))) throw new Error("No package.json to build");
		log("Building (npm run build)…");
		const install = existsSync(join(root, "node_modules")) ? "" : "npm install && ";
		try {
			await container.run("box", ["-c", `${install}npm run build`], { cwd: root, log });
		} catch (e) {
			const message = (e as Error).message;
			if (message.startsWith("Node.js isn't installed")) throw e;
			// The log above has npm's own output; say what failed in words.
			if (/Missing script: "?build/.test(message)) {
				throw new Error("package.json has no build script. Choose a folder that is already built, or add a build script.");
			}
			throw new Error(`The build failed (npm ${install ? "install or " : ""}run build); see the log above.\n${message}`);
		}
	}

	// -------------------------------------------------------------------------
	// Deploy

	async deploy(target: string, dir: string, options: Record<string, any>, log: Log) {
		// A Cloudflare deploy may build its output folder first.
		if (!existsSync(dir) && !(target.startsWith("cloudflare") && options.build)) {
			// Name it the way the user typed it: relative to the project, not the app's private path.
			const root = typeof options.root === "string" ? options.root : null;
			const shown = root ? relative(root, dir) || "." : basename(dir);
			throw new Error(`No such folder: ${shown}${target.startsWith("cloudflare") ? ". Build the project first, or turn on Build first." : ""}`);
		}
		// Pages and Vercel deploys publish to the public internet: the UI must
		// have shown the resolved target and the user must have confirmed it.
		if ((target === "github_pages" || target === "vercel") && options.confirmed !== true) {
			throw new Error("Confirm the deploy target before deploying.");
		}
		switch (target) {
			case "vercel":
				return this.deployVercel(dir, options, log);
			case "github_pages":
				return this.deployPages(dir, options, log);
			case "cloudflare_workers":
			case "cloudflare_pages": {
				const root = typeof options.root === "string" && existsSync(options.root) ? options.root : dir;
				const rel = relative(root, dir);
				if (rel.startsWith("..")) throw new Error("The folder to deploy must be inside the project");
				if (options.build) {
					await this.build(root, log);
					if (!existsSync(dir)) throw new Error(`The build didn't produce ${relative(root, dir) || dir}`);
				}
				const cf = this.cloudflare();
				return target === "cloudflare_workers"
					? cf.deployWorker(dir, root, { name: options.name, spa: !!options.spa }, log, this.containerRunner())
					: cf.deployPages(dir, root, { project: options.name, preview: !!options.preview }, log, this.containerRunner());
			}
			case "ssh":
				return this.deploySsh(dir, options, log);
			default:
				throw new Error(`Unknown deploy target: ${target}`);
		}
	}

	private async deployVercel(dir: string, options: Record<string, any>, log: Log) {
		const files = walk(dir);
		if (files.length === 0) throw new Error("Nothing to deploy: the folder is empty");
		log(`Uploading ${files.length} files…`);
		const manifest = [];
		let done = 0;
		for (const rel of files) {
			const data = readFileSync(join(dir, rel));
			const sha = createHash("sha1").update(data).digest("hex");
			await this.vercel("/v2/files", {
				method: "POST",
				headers: { "Content-Type": "application/octet-stream", "x-vercel-digest": sha },
				body: data,
			});
			manifest.push({ file: rel.split("\\").join("/"), sha, size: data.length });
			done++;
			if (done % 10 === 0 || done === files.length) log(`  ${done}/${files.length}`);
		}
		const name = sanitizeProject(options.project || basename(dir));
		log(`Creating deployment for ${name}…`);
		let dep = await this.vercel("/v13/deployments?skipAutoDetectionConfirmation=1", {
			method: "POST",
			headers: { "Content-Type": "application/json" },
			body: JSON.stringify({ name, files: manifest, target: options.preview ? undefined : "production" }),
		});
		const inspector: string | null = dep.inspectorUrl ?? null;
		const report = (state: string) => {
			const done = ["READY", "ERROR", "CANCELED"].includes(state);
			log.ci?.({
				provider: "vercel",
				runs: [
					{
						id: dep.id,
						name: `Vercel · ${name}`,
						status: done ? "completed" : state === "QUEUED" || state === "INITIALIZING" ? "queued" : "in_progress",
						conclusion: done ? (state === "READY" ? "success" : "failure") : null,
						url: inspector,
						jobs: [],
					},
				],
			});
		};
		report(dep.readyState);
		const events = new AbortController();
		void this.streamVercelBuild(dep.id, log, events.signal);
		const started = Date.now();
		try {
			while (!["READY", "ERROR", "CANCELED"].includes(dep.readyState) && Date.now() - started < 15 * 60_000) {
				await sleep(3000);
				dep = await this.vercel(`/v13/deployments/${dep.id}`);
				report(dep.readyState);
			}
		} finally {
			// Let the last build lines land before closing the stream.
			await sleep(1000);
			events.abort();
		}
		if (dep.readyState !== "READY") throw new Error(`Deployment ${dep.readyState?.toLowerCase() ?? "timed out"}`);
		const url = `https://${dep.alias?.[0] ?? dep.url}`;
		log(`Live at ${url}`);
		return { url };
	}

	/** Follows a deployment's build output (the same log the Vercel dashboard shows). */
	private async streamVercelBuild(id: string, log: Log, signal: AbortSignal) {
		try {
			const res = await fetch(`https://api.vercel.com/v3/deployments/${id}/events?follow=1&builds=1`, {
				headers: { Authorization: `Bearer ${this.store.vercel?.token}` },
				signal,
			});
			if (!res.ok || !res.body) return;
			const decoder = new TextDecoder();
			let buffer = "";
			for await (const chunk of res.body as any as AsyncIterable<Uint8Array>) {
				buffer += decoder.decode(chunk, { stream: true });
				let nl: number;
				while ((nl = buffer.indexOf("\n")) >= 0) {
					const line = buffer.slice(0, nl).trim();
					buffer = buffer.slice(nl + 1);
					if (!line) continue;
					try {
						const ev = JSON.parse(line);
						const text = ev.payload?.text ?? ev.text;
						if (typeof text === "string" && text.trim()) log(`│ ${text.trimEnd()}`);
					} catch {
						// Keep-alive or partial line.
					}
				}
			}
		} catch {
			// Aborted when the deployment settles, or the stream is unavailable; state polling still reports.
		}
	}

	/**
	 * Waits for every GitHub Actions run on `sha` (Pages' own build plus any
	 * workflows the repo has), reporting jobs and steps as they progress.
	 * Throws with the failing job's log tail if one fails.
	 */
	async watchActions(slug: string, sha: string, log: Log) {
		const deadline = Date.now() + 20 * 60_000;
		const appearBy = Date.now() + 90_000;
		const announced = new Map<string, string>();
		while (Date.now() < deadline) {
			const { workflow_runs: list = [] } = await this.github(
				`/repos/${slug}/actions/runs?head_sha=${sha}&per_page=20`,
			).catch(() => ({ workflow_runs: [] }));
			if (list.length === 0) {
				if (Date.now() > appearBy) {
					log("No CI runs were started for this commit");
					return;
				}
				await sleep(4000);
				continue;
			}
			const runs: CiRun[] = [];
			for (const r of list) {
				const { jobs = [] } = await this.github(`/repos/${slug}/actions/runs/${r.id}/jobs`).catch(() => ({ jobs: [] }));
				runs.push({
					id: String(r.id),
					name: r.name ?? r.display_title ?? "workflow",
					status: r.status,
					conclusion: r.conclusion ?? null,
					url: r.html_url ?? null,
					jobs: jobs.map((j: any) => ({
						id: j.id,
						name: j.name,
						status: j.status,
						conclusion: j.conclusion ?? null,
						steps: (j.steps ?? []).map((s: any) => ({ name: s.name, status: s.status, conclusion: s.conclusion ?? null })),
					})),
				});
				for (const j of jobs) {
					const state = j.conclusion ?? j.status;
					const key = `${r.id}/${j.id}`;
					if (announced.get(key) !== state) {
						announced.set(key, state);
						log(`${r.name} › ${j.name}: ${state.replace(/_/g, " ")}`);
					}
				}
			}
			log.ci?.({ provider: "github", runs });
			if (runs.every((r) => r.status === "completed")) {
				const failed = list.filter((r: any) => FAILED.has(r.conclusion));
				for (const r of failed) {
					const run = runs.find((x) => x.id === String(r.id))!;
					for (const j of run.jobs as any[]) {
						if (!FAILED.has(j.conclusion)) continue;
						const tail = await this.jobLogTail(slug, j.id);
						log(`── ${r.name} › ${j.name} failed ──`);
						for (const line of tail) log(line);
					}
				}
				if (failed.length) throw new Error(`CI failed: ${failed.map((r: any) => r.name).join(", ")}`);
				return;
			}
			await sleep(4000);
		}
		log("Stopped waiting for CI after 20 minutes");
	}

	/** CI for the latest commit of a project folder with a GitHub remote. */
	async watchProject(dir: string, log: Log) {
		const remote = (await run("git", ["remote", "get-url", "origin"], { cwd: dir }).catch(() => "")).trim();
		const slug = parseGithubSlug(remote);
		if (!slug) throw new Error("This folder has no GitHub remote");
		const sha = (await run("git", ["rev-parse", "HEAD"], { cwd: dir })).trim();
		log(`CI for ${slug}@${sha.slice(0, 7)}`);
		await this.watchActions(slug, sha, log);
		return { url: null };
	}

	private async jobLogTail(slug: string, jobId: number, lines = 30) {
		try {
			const res = await fetch(`https://api.github.com/repos/${slug}/actions/jobs/${jobId}/logs`, {
				signal: AbortSignal.timeout(60_000),
				headers: { Authorization: `Bearer ${await this.githubToken()}`, Accept: "application/vnd.github+json" },
			});
			if (!res.ok) return [`(logs unavailable: ${res.status})`];
			const text = await res.text();
			// Drop the timestamp prefix GitHub puts on every line.
			return text
				.split("\n")
				.map((l) => l.replace(/^\d{4}-\d\d-\d\dT[\d:.]+Z\s?/, "").trimEnd())
				.filter(Boolean)
				.slice(-lines);
		} catch {
			return ["(logs unavailable)"];
		}
	}

	/**
	 * Resolves a deploy target without side effects, so the UI can confirm
	 * the exact destination (repository + visibility) before anything is
	 * pushed. Only read-only calls happen here.
	 */
	async deployPlan(target: string, dir: string, options: Record<string, any>) {
		if (target === "github_pages") {
			const gh = this.store.github;
			if (!gh) throw new Error("Sign in to GitHub first");
			const origin = (await run("git", ["remote", "get-url", "origin"], { cwd: dir }).catch(() => "")).trim();
			const slug = parseGithubSlug(origin);
			if (slug) {
				const repo = await this.github(`/repos/${slug}`).catch(() => null);
				return {
					target,
					dir,
					repo: slug,
					willCreate: false,
					visibility: repo == null ? "unknown" : repo.private === true ? "private" : "public",
					branch: "gh-pages",
				};
			}
			const name = sanitizeRepo(options.repo || basename(dir));
			return {
				target,
				dir,
				repo: `${gh.login}/${name}`,
				willCreate: true,
				visibility: "public",
				branch: "gh-pages",
				note: "New repositories are created public so Pages serves on free accounts.",
			};
		}
		if (target === "vercel") {
			return {
				target,
				dir,
				project: sanitizeProject(options.project || basename(dir)),
				preview: options.preview === true,
			};
		}
		if (target === "ssh") {
			const h = this.host(options.hostId);
			const remoteDir = (options.remotePath || h.path || "").trim();
			const files = walk(dir);
			return {
				target,
				dir,
				server: `${h.user}@${h.host}`,
				remoteDir,
				files: files.length,
				// What stays home, so the dialog can name it (.env above all).
				skipped: skippedEntries(dir),
			};
		}
		return { target, dir };
	}

	/**
	 * GitHub Pages deploy that never touches the user's own repository: only
	 * the selected folder's filtered content is copied to a temp dir and
	 * pushed to a dedicated gh-pages branch. The old code ran `git add -A`
	 * in the project (staging the whole tree, .env included), committed to
	 * the current branch, deleted a non-GitHub origin, and created public
	 * repos silently; Pages then served the branch root (or /docs), not the
	 * selected folder.
	 */
	private async deployPages(dir: string, options: Record<string, any>, log: Log) {
		const gh = this.store.github;
		if (!gh) throw new Error("Sign in to GitHub first");
		if (options.confirmed !== true) throw new Error("Confirm the deploy target (repository + visibility) before deploying.");
		// Resolve the target repo read-only: the user's local repo is never modified.
		const origin = (await run("git", ["remote", "get-url", "origin"], { cwd: dir }).catch(() => "")).trim();
		let slug = parseGithubSlug(origin);
		if (!slug) {
			const name = sanitizeRepo(options.repo || basename(dir));
			log(`Creating GitHub repository ${gh.login}/${name}…`);
			const repo = await this.github("/user/repos", {
				method: "POST",
				body: JSON.stringify({ name, private: false, description: "Deployed from GripHub AI Agent" }),
			}).catch(async (e) => {
				if ((e as any).status === 422) return this.github(`/repos/${gh.login}/${name}`);
				throw e;
			});
			slug = repo.full_name as string;
		}
		if (options.planRepo && options.planRepo !== slug) {
			throw new Error("Deploy target changed since confirmation; confirm again.");
		}
		const branch = "gh-pages";
		const files = walk(dir);
		if (files.length === 0) throw new Error("Nothing to deploy: the folder is empty");
		log(`Deploying ${files.length} files from ${basename(dir)} to ${slug} (${branch})…`);
		const tmp = mkdtempSync(join(tmpdir(), "griphub-deploy-"));
		try {
			for (const rel of files) {
				const target = join(tmp, rel);
				mkdirSync(dirname(target), { recursive: true });
				copyFileSync(join(dir, rel), target);
			}
			const git = (args: string[]) => run("git", args, { cwd: tmp, log });
			const quiet = (args: string[]) => run("git", args, { cwd: tmp });
			await git(["init", "-b", branch]);
			await git(["add", "-A"]);
			await git(["commit", "-m", options.message || "Deploy from GripHub AI Agent"]);
			await quiet(["remote", "add", "origin", `https://github.com/${slug}.git`]);
			// Push with a lease when the branch already exists, so a
			// concurrent change to the deploy branch is refused, not clobbered.
			const lease = (await quiet(["fetch", "origin", branch]).then(() => quiet(["rev-parse", "FETCH_HEAD"])).catch(() => "")).trim();
			await git(lease ? ["push", `--force-with-lease=${branch}:${lease}`, "origin", `HEAD:${branch}`] : ["push", "origin", `HEAD:${branch}`]);
			log("Enabling GitHub Pages…");
			try {
				await this.github(`/repos/${slug}/pages`, {
					method: "POST",
					body: JSON.stringify({ source: { branch, path: "/" } }),
				});
			} catch (e) {
				if ((e as any).status !== 409) throw e;
				await this.github(`/repos/${slug}/pages`, {
					method: "PUT",
					body: JSON.stringify({ source: { branch, path: "/" } }),
				}).catch(() => {});
			}
			const pages = await this.github(`/repos/${slug}/pages`);
			const url = pages.html_url as string;
			const sha = (await quiet(["rev-parse", "HEAD"])).trim();
			log(`Waiting for CI on ${sha.slice(0, 7)}…`);
			await this.watchActions(slug, sha, log);
			log(`Live at ${url}`);
			return { url, repo: `https://github.com/${slug}` };
		} finally {
			rmSync(tmp, { recursive: true, force: true });
		}
	}

	/**
	 * SSH deploy of exactly the files every other target uploads (see walk):
	 * no dotfiles (.env), no .git or node_modules, no symlinks. It used to
	 * rsync/scp the whole folder minus .git and node_modules, so a project's
	 * .env landed on the server, often inside the web root.
	 */
	private async deploySsh(dir: string, options: Record<string, any>, log: Log) {
		if (options.confirmed !== true) throw new Error("Confirm the deploy target (server + folder) before deploying.");
		const h = this.host(options.hostId);
		const remoteDir = (options.remotePath || h.path || "").trim();
		if (!remoteDir) throw new Error("Choose a remote folder to deploy into");
		const files = walk(dir);
		if (!files.length) throw new Error("Nothing to deploy: the folder has no files (dotfiles are never uploaded)");
		const config = join(this.home, ".ssh", "config");
		const target = `${h.name}:${remoteDir.replace(/\/?$/, "/")}`;
		log(`Syncing ${files.length} files to ${h.user}@${h.host}:${remoteDir}…`);
		await run("ssh", ["-F", config, "-o", "BatchMode=yes", h.name, `mkdir -p '${remoteDir.replace(/'/g, "'\\''")}'`], {
			cwd: dir,
			log,
		});
		const tmp = mkdtempSync(join(tmpdir(), "griphub-ssh-"));
		try {
			const list = join(tmp, "files.txt");
			writeFileSync(list, `${files.join("\n")}\n`);
			try {
				await run("rsync", ["-az", "--stats", `--files-from=${list}`, "-e", `ssh -F ${config} -o BatchMode=yes`, `${dir}/`, target], {
					cwd: dir,
					log,
				});
			} catch (e) {
				if (!/rsync.*(not found|No such file)|protocol/i.test(String((e as Error).message))) throw e;
				log("rsync unavailable on the server, falling back to scp");
				// scp copies trees, not lists: stage the filtered files first.
				const stage = join(tmp, "stage");
				for (const f of files) {
					mkdirSync(dirname(join(stage, f)), { recursive: true });
					copyFileSync(join(dir, f), join(stage, f));
				}
				await run("scp", ["-F", config, "-S", "ssh", "-o", "BatchMode=yes", "-r", `${stage}/.`, target], { cwd: dir, log });
			}
		} finally {
			rmSync(tmp, { recursive: true, force: true });
		}
		log("Done");
		return { url: null };
	}
}

// ---------------------------------------------------------------------------
// Helpers

/** Runs a command, streaming lines to `log`. Resolves with stdout. */
/**
 * Runs a child process and returns its stdout. A hung git/ssh/rsync used to
 * block forever (no timeout anywhere); every call now dies after
 * `timeoutMs` (default 10 minutes) with a clear error instead.
 */
export function run(cmd: string, args: string[], opts: { cwd: string; log?: Log; timeoutMs?: number }): Promise<string> {
	return new Promise((resolve, reject) => {
		const child = spawn(cmd, args, { cwd: opts.cwd, env: process.env });
		let stdout = "";
		const tail: string[] = [];
		let done = false;
		const timer = setTimeout(() => {
			if (done) return;
			done = true;
			child.kill("SIGKILL");
			reject(new Error(`${cmd} timed out after ${opts.timeoutMs ?? 600_000}ms`));
		}, opts.timeoutMs ?? 600_000);
		timer.unref?.();
		const finish = (fn: () => void) => {
			if (done) return;
			done = true;
			clearTimeout(timer);
			fn();
		};
		const feed = (chunk: Buffer, keep: boolean) => {
			const text = chunk.toString("utf8");
			if (keep) stdout += text;
			// git progress redraws with \r; treat each redraw as a line.
			for (const line of text.split(/\r?\n|\r/)) {
				if (!line.trim()) continue;
				tail.push(line);
				if (tail.length > 20) tail.shift();
				opts.log?.(line);
			}
		};
		child.stdout.on("data", (c) => feed(c, true));
		child.stderr.on("data", (c) => feed(c, false));
		child.on("error", (e) => finish(() => reject(e)));
		child.on("close", (code) => {
			finish(() => {
				if (code === 0) resolve(stdout);
				else reject(new Error(`${cmd} exited with ${code}\n${tail.slice(-6).join("\n")}`));
			});
		});
	});
}

const SKIP_DIRS = new Set([".git", "node_modules", ".vercel", ".next", ".DS_Store"]);

/**
 * Files under a folder, for deploys. Dotfiles (.env included) and symlinks
 * are never uploaded: a symlink could point outside the folder (or at
 * /etc), and dotfiles are where secrets live. statSync follows symlinks,
 * so lstatSync is what makes the symlink check real.
 */
/** Top-level names a deploy leaves out (dotfiles and SKIP_DIRS), for the confirm dialog. */
export function skippedEntries(root: string): string[] {
	return readdirSync(root)
		.filter((name) => SKIP_DIRS.has(name) || name.startsWith("."))
		.sort();
}

export function walk(root: string, dir = root, out: string[] = []): string[] {
	for (const name of readdirSync(dir)) {
		if (SKIP_DIRS.has(name) || name.startsWith(".")) continue;
		const path = join(dir, name);
		const st = lstatSync(path);
		if (st.isSymbolicLink()) continue;
		if (st.isDirectory()) walk(root, path, out);
		else if (st.isFile()) out.push(relative(root, path));
		if (out.length > 5000) throw new Error("Too many files to deploy (over 5000)");
	}
	return out;
}

function parseGithubSlug(url: string): string | null {
	const m = url.match(/github\.com[:/]([^/]+\/[^/]+?)(?:\.git)?\/?$/);
	return m ? m[1] : null;
}

function sanitizeAlias(s: string) {
	return s.trim().replace(/[^A-Za-z0-9._-]+/g, "-") || "server";
}

function sanitizeRepo(s: string) {
	return s.trim().replace(/[^A-Za-z0-9._-]+/g, "-").replace(/^-+|-+$/g, "") || "site";
}

function sanitizeProject(s: string) {
	return (
		s
			.toLowerCase()
			.replace(/[^a-z0-9-]+/g, "-")
			.replace(/^-+|-+$/g, "")
			.slice(0, 90) || "site"
	);
}
