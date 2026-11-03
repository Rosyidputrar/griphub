/**
 * Chat mode: a plain conversation, like a chatbot on the web, beside the coding agent every other chat is.
 *
 * A coding chat has the whole tool set (files, shell, todo, subagents, jobs, MCP) and a coding agent's notes in its
 * prompt, so even "what's the news today?" was answered by an agent that read files and planned steps. A chat in chat
 * mode only gets what a conversation needs: web search and fetch for things that change, `read` for what the user
 * attached, and pictures when those are on. Its prompt is its own (no AGENTS.md, no skills), and it may make only a
 * few tool calls per answer.
 *
 * What makes a chat one of these is its folder: every chat-mode chat works in `<workspace>/.chats`. That needs nothing
 * stored apart (the session's header already keeps its folder, and the chat list already has it), every rebuild of
 * the session (a setting, MCP coming up, a fork) keeps the mode, and chats from before keep being coding chats. The
 * folder is inside the workspace so the app can put attachments there on a server too (fs_* only reaches the
 * workspace), and it starts with a dot so it is never listed, synced or backed up as a project.
 */

import { realpathSync } from "node:fs";
import { join, resolve } from "node:path";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { isInside, resolveLikePi } from "./guard.js";

export type ChatMode = "chat" | "coding";

/** The folder chat-mode chats work in, inside the workspace. */
export const CHAT_DIR_NAME = ".chats";

export function chatDir(workspace: string): string {
	return join(workspace, CHAT_DIR_NAME);
}

/** Whether a chat working in [cwd] is a chat-mode chat. */
export function isChatCwd(cwd: string | undefined | null, workspace: string): boolean {
	return !!cwd && resolve(cwd) === resolve(chatDir(workspace));
}

export function modeOf(cwd: string | undefined | null, workspace: string): ChatMode {
	return isChatCwd(cwd, workspace) ? "chat" : "coding";
}

/** The built-in tools a chat-mode chat has; generate_image is added when pictures are on. */
export const CHAT_TOOLS = ["read", "web_search", "web_fetch"];

/**
 * Tool calls one answer may make. A conversation needs a search or two and maybe a page; past this the model is told
 * to answer with what it has, and a model that keeps going anyway has its run ended.
 */
export const CHAT_MAX_TOOL_CALLS = 6;
const CHAT_GRACE_CALLS = 3;

/** Today's date as the user reads it ("Tuesday, 3 November 2026"), in [timeZone] when one is set and valid. */
export function chatDate(now: Date, timeZone?: string | null): string {
	const format = (zone?: string) =>
		new Intl.DateTimeFormat("en-GB", { weekday: "long", day: "numeric", month: "long", year: "numeric", ...(zone ? { timeZone: zone } : {}) }).format(now);
	if (timeZone) {
		try {
			return format(timeZone);
		} catch {
			// Not a zone this runtime knows: the machine's own.
		}
	}
	return format();
}

export interface ChatPromptOptions {
	/** Today's date, already formatted (chatDate). */
	date: string;
	/** generate_image is there. */
	pictures: boolean;
}

/** The whole system prompt of a chat-mode chat (pi adds the working folder after it). */
export function chatSystemPrompt({ date, pictures }: ChatPromptOptions): string {
	const lines = [
		"You are GripHub, a helpful general assistant in the GripHub app on the user's phone. This is a regular chat, not a coding session: you answer questions, explain things, help write and translate, brainstorm, and look things up.",
		"",
		"- Answer directly and conversationally, in the user's language. Use Markdown only where it helps (a short list, a table, code when asked for).",
		`- Today is ${date}. Your own knowledge stops at a cutoff date.`,
		"- Most messages need no tools: general knowledge, explanations, advice, writing, translation and math are answered from what you know.",
		"- Use web_search only when the answer depends on current or fast-changing information (news, prices, weather, schedules, releases, recent events, live facts about people or companies) or when the user asks you to look something up. One or two searches are usually enough. Use web_fetch only when the search snippets are not enough to answer.",
		"- When you used the web, name your sources with their links at the end of the answer.",
		"- If a search fails or finds nothing useful, say so and answer from what you know, noting that it may be out of date. Do not keep rephrasing the same search.",
		'- Files listed after "Attached files:" are part of the user\'s message: read them with the read tool before you answer. A pasted-text.txt there is text the user pasted into the message.',
	];
	if (pictures) lines.push("- Use generate_image only when the user asks for a picture.");
	lines.push(
		"- You cannot run commands, change files or work on projects in this chat. When the user wants that, tell them to start a Coding chat with the + button.",
	);
	return lines.join("\n");
}

/** Where [path] really is, links followed as far as it exists. */
function real(path: string): string {
	try {
		return realpathSync(path);
	} catch {
		return path;
	}
}

/** Why a chat-mode chat may not make this call, or null: `read` only reaches what was attached (the chat folder). */
export function chatCallProblem(toolName: string, input: Record<string, unknown>, dir: string): string | null {
	if (toolName !== "read") return null;
	let target: string;
	try {
		target = resolveLikePi(String(input.path ?? ""), dir);
	} catch {
		return "In this chat you can only read the files the user attached.";
	}
	return isInside(real(target), real(dir)) ? null : "In this chat you can only read the files the user attached.";
}

/** The pi extension of a chat-mode chat: the folder fence for `read` and the per-answer tool-call limit. */
export function chatModeExtension(opts: { dir: string; maxCalls?: number; stopped?: (reason: string) => void }) {
	const max = opts.maxCalls ?? CHAT_MAX_TOOL_CALLS;
	return (pi: ExtensionAPI) => {
		let calls = 0;
		pi.on("agent_start", () => {
			calls = 0;
		});
		pi.on("tool_call", (event) => {
			calls++;
			if (calls > max + CHAT_GRACE_CALLS) {
				if (calls === max + CHAT_GRACE_CALLS + 1) opts.stopped?.(`Stopped after ${max} tool calls in one answer.`);
				return { block: true, reason: "Tool-call limit reached; the answer is ending.", terminate: true };
			}
			if (calls > max) {
				return {
					block: true,
					reason: `Tool-call limit for one answer in a chat reached (${max}). Do not call any more tools: answer the user now with what you have.`,
				};
			}
			const problem = chatCallProblem(event.toolName, event.input as Record<string, unknown>, opts.dir);
			return problem ? { block: true, reason: problem } : undefined;
		});
	};
}
