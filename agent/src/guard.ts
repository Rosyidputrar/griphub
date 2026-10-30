/**
 * The app's inline pi extension: approvals before risky tool calls, plan
 * mode (read-only until the plan is approved), dev-server detection from
 * command output, and a checkpoint before the agent starts changing files.
 */

import { homedir } from "node:os";
import { isAbsolute, relative, resolve, sep } from "node:path";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

/**
 * When the agent must ask before acting. `deny_risky` is for runs nobody is watching (a server's background tasks):
 * what `ask_risky` would ask about is refused outright instead, since there is nobody to answer.
 */
export type ApprovalMode = "ask_all" | "ask_risky" | "auto" | "deny_risky";

/** An approval card as the host sends it. */
export interface ApprovalRecord {
	type: "approval";
	approvalId: string;
	toolName: string;
	summary: string;
	reason: string;
	key: string;
}

export interface GuardHooks {
	send(record: object): void;
	/** Snapshot the working tree before the agent's first file change in a run. */
	checkpoint(cwd: string, label: string): Promise<void>;
	cwd(): string;
}

/** Whether [path] is [dir] or somewhere inside it (lexically; resolve links first where they matter). */
export function isInside(path: string, dir: string): boolean {
	const rel = relative(resolve(dir), resolve(dir, path));
	return rel === "" || (rel !== ".." && !rel.startsWith("../") && !isAbsolute(rel));
}

/** Tools that change nothing; never need approval and stay on in plan mode. */
const READ_ONLY = new Set(["read", "grep", "find", "ls", "web_search", "web_fetch", "web_screenshot", "todo_write"]);

/**
 * Commands worth a second look before they run. The flag patterns allow any
 * flags before the dangerous one: `rm -v -rf` and `git -C x push --force`
 * used to slip through because only the first flag was examined.
 */
const RISKY_BASH = [
	/\brm\b[^;&|]*(-[a-z]*r|-[a-z]*f|--recursive|--force)/i,
	/\bgit\b[^;&|]*\b(push|reset\s+--hard|clean\s+-[a-z]*f|checkout\s+--\s|branch\s+-D|rebase)\b/i,
	/\bfind\b[^;&|]*\b(-delete|-exec\b|-execdir\b|-ok\b)/i,
	/\b(vercel|netlify|wrangler|firebase)\b.*\b(deploy|--prod)\b/i,
	/\bnpm\s+publish\b|\bpip\s+upload\b|\btwine\s+upload\b/i,
	/\b(curl|wget)\b[^|]*\|\s*(sudo\s+)?(ba)?sh\b/i,
	/\b(dd|mkfs|shred|chmod\s+-R|chown\s+-R)\b/i,
	/\bssh\b|\bscp\b|\brsync\b/i,
	/>\s*\/(etc|usr|bin|system)\b/i,
	/\bkill(all)?\b|\bpkill\b/i,
	/\bDROP\s+(TABLE|DATABASE)\b|\bTRUNCATE\b/i,
];

/**
 * Why a call deserves a second look, or null. `mcp` says whether tools from MCP servers count: a person is asked about
 * them, but an unattended run may use the servers the user set up (as background runs always could).
 */
function riskOf(toolName: string, input: Record<string, unknown>, cwd: string, mcp = true): string | null {
	if (READ_ONLY.has(toolName)) return null;
	// A background job is a bash command that runs a while: the same second look.
	if (toolName === "bash" || toolName === "background_job") {
		const cmd = String(input.command ?? "");
		const hit = RISKY_BASH.find((re) => re.test(cmd));
		return hit ? "This command can delete data, publish or reach other machines" : null;
	}
	if (toolName === "write" || toolName === "edit") {
		const raw = String(input.path ?? "");
		// Resolve ~, relative paths and .. segments before comparing, and
		// compare against cwd + separator: /a/bc is not inside /a/b.
		const expanded = raw === "~" ? homedir() : raw.startsWith("~/") ? resolve(homedir(), raw.slice(2)) : raw;
		const resolved = resolve(cwd, expanded);
		if (resolved !== cwd && !resolved.startsWith(cwd + sep)) return "Writes outside the project folder";
		return null;
	}
	// Unknown/custom tools (MCP and friends) are treated as risky.
	return mcp && toolName.startsWith("mcp_") ? "External tool from an MCP server" : null;
}

/** Summary line for the approval card. */
function describe(toolName: string, input: Record<string, unknown>) {
	if (toolName === "bash" || toolName === "background_job") return String(input.command ?? "");
	if (typeof input.path === "string") return input.path;
	return JSON.stringify(input).slice(0, 400);
}

export class Guard {
	mode: ApprovalMode = "ask_risky";
	/** Plan mode: only read-only tools until the user approves the plan. */
	planMode = false;
	/** "Always allow" choices for this app run, keyed by the full command/pattern. */
	private allowed = new Set<string>();
	/** Waiting approvals with the record that asked, so an app that reconnects can show them again. */
	private pending = new Map<string, { resolve: (allow: boolean) => void; record: ApprovalRecord }>();
	/** Random per-process token: approval ids must never repeat across host restarts. */
	private readonly epoch = Math.random().toString(36).slice(2, 8);
	private next = 1;
	private changedThisRun = false;

	constructor(private readonly hooks: GuardHooks) {}

	reply(id: string, allow: boolean, always = false, key?: string) {
		const waiting = this.pending.get(id);
		this.pending.delete(id);
		if (allow && always && key) this.allowed.add(key);
		waiting?.resolve(allow);
	}

	/** Approval for something outside a tool call (e.g. an issue-triggered run). Reuses the same card and reply path; the empty key can never be "always"-allowed. */
	askApproval(toolName: string, summary: string, reason: string): Promise<boolean> {
		return this.request({ toolName, summary, reason, key: "" });
	}

	/**
	 * The approvals still waiting for an answer, as the records that asked for them. A server agent's app may have been
	 * away when they were sent (and the replay buffer may no longer hold them); it asks for these after reconnecting.
	 */
	pendingApprovals(): ApprovalRecord[] {
		return [...this.pending.values()].map((w) => w.record);
	}

	/** Deny everything still waiting (e.g. when the run is aborted). */
	cancelAll() {
		for (const [id, waiting] of this.pending) {
			this.hooks.send({ type: "approval_dismiss", approvalId: id });
			waiting.resolve(false);
		}
		this.pending.clear();
	}

	private ask(toolName: string, input: Record<string, unknown>, reason: string, key: string) {
		return this.request({ toolName, summary: describe(toolName, input), reason, key });
	}

	private request(fields: Omit<ApprovalRecord, "type" | "approvalId">): Promise<boolean> {
		const record: ApprovalRecord = { type: "approval", approvalId: `a${this.epoch}-${this.next++}`, ...fields };
		this.hooks.send(record);
		return new Promise<boolean>((resolve) => this.pending.set(record.approvalId, { resolve, record }));
	}

	/** The pi extension factory. */
	extension = (pi: ExtensionAPI) => {
		pi.on("agent_start", () => {
			this.changedThisRun = false;
		});

		pi.on("tool_call", async (event) => {
			const input = event.input as Record<string, unknown>;
			const cwd = this.hooks.cwd();

			// The plan in plan mode is the numbered text the user approves; the checklist comes after.
			if (this.planMode && event.toolName === "todo_write") {
				return {
					block: true,
					reason:
						"Plan mode is on: write the plan as a numbered list for the user to approve. Call todo_write once it is approved.",
				};
			}

			if (this.planMode && !READ_ONLY.has(event.toolName)) {
				return {
					block: true,
					reason:
						"Plan mode is on: do not change anything yet. Finish the plan as a numbered list and ask the user to approve it.",
				};
			}

			const risk = this.mode === "ask_all" ? (READ_ONLY.has(event.toolName) ? null : "Approval required for every change") : this.mode === "ask_risky" ? riskOf(event.toolName, input, cwd) : this.mode === "deny_risky" ? riskOf(event.toolName, input, cwd, false) : null;
			if (risk && this.mode === "deny_risky") {
				return {
					block: true,
					reason: `Refused: nobody is watching this run, so actions that need approval are not allowed (${risk}). Do not look for a way around this; finish what you safely can and say what is left for the user.`,
				};
			}
			if (risk) {
				// "Always allow" stores the FULL pattern. Storing only the
				// first two words let `cd app && git push` also allow
				// `cd app && rm -rf ~`; storing only the tool name let one
				// write allow every write.
				const key =
					event.toolName === "bash" || event.toolName === "background_job"
						? `${event.toolName}:${String(input.command ?? "").trim().replace(/\s+/g, " ")}`
						: event.toolName === "write" || event.toolName === "edit"
							? `${event.toolName}:${String(input.path ?? "")}`
							: `${event.toolName}:${JSON.stringify(input).slice(0, 400)}`;
				if (!this.allowed.has(key)) {
					const ok = await this.ask(event.toolName, input, risk, key);
					if (!ok) return { block: true, reason: "The user declined this action. Ask what they would like instead." };
				}
			}

			// First change in this run: snapshot so the user can undo the whole run.
			if (!READ_ONLY.has(event.toolName) && !this.changedThisRun) {
				this.changedThisRun = true;
				await this.hooks.checkpoint(cwd, "Before the agent's changes").catch(() => {});
			}
			return undefined;
		});

		pi.on("tool_result", (event) => {
			if (event.toolName !== "bash") return;
			const text = event.content.map((c: any) => (c.type === "text" ? c.text : "")).join("\n");
			const found = new Set<number>();
			for (const m of text.matchAll(/(?:localhost|127\.0\.0\.1|0\.0\.0\.0|\[::\]):(\d{2,5})\b/g)) {
				const port = Number(m[1]);
				if (port >= 1024 && port <= 65535) found.add(port);
			}
			for (const port of found) this.hooks.send({ type: "dev_server", port, url: `http://localhost:${port}` });
		});
	};
}
