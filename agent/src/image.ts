/**
 * generate_image: the agent makes pictures through GripHub Router's image models, inside the chat.
 *
 * - The model is the user's default (Settings → Pictures), or the cheapest image model by the live rates ("auto").
 * - Limits of their own, inside the account's daily budget:
 *   - pictures per call (a hard cap: more are not made, and the agent is told);
 *   - credits a request of the agent may spend on pictures without asking (summed over the whole request, so a
 *     model cannot get around it with many small calls); over it the user is asked, the cheapest model is used,
 *     or the call is refused, as the user chose;
 *   - credits a day for pictures, and the daily budget: hard, never asked about.
 * - Pictures of one call are made in parallel; each one is reported as it lands (tool_execution_update details), so
 *   the app can show it at once. They are saved under the project's .images/ (ignored by git), and the agent gets
 *   their paths as text, not the pictures: they would cost tokens on every later turn, and fail on text-only models.
 * - Nothing is retried: a request that timed out may still have made (and billed) a picture on the router.
 * - The day's picture spend is kept in a small log (images.json), which also counts the pictures toward the daily
 *   budget until the router's own figure includes them.
 */

import { existsSync, mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { Type } from "typebox";
import { readSecureJson, writeSecureJson } from "./secure.js";
import type { ImageSettings } from "./integrations.js";
import { ImageError } from "./providers.js";
import { wibDay } from "./workbench.js";

export const IMAGE_TOOL = "generate_image";

/** Sizes the router's image models take, and the words a model may use for them. */
export const IMAGE_SIZES = ["1024x1024", "1536x1024", "1024x1536"] as const;
export type ImageSize = (typeof IMAGE_SIZES)[number];
const SIZE_WORDS: Record<string, ImageSize> = {
	"1:1": "1024x1024",
	square: "1024x1024",
	"3:2": "1536x1024",
	"16:9": "1536x1024",
	landscape: "1536x1024",
	wide: "1536x1024",
	"2:3": "1024x1536",
	"9:16": "1024x1536",
	portrait: "1024x1536",
	tall: "1024x1536",
};

/** Longest prompt sent on; image models ignore (or refuse) more. */
export const MAX_PROMPT_CHARS = 4000;

/** How long the list of image models is reused before it is read again. */
const MODELS_TTL_MS = 10 * 60_000;

/** Picture log entries older than this are dropped. */
const LOG_KEEP_MS = 3 * 86400_000;

export interface ImageModel {
	id: string;
	name: string;
	/** Credits per picture, or null when the price is not known. */
	credits: number | null;
}

/** One picture of a call, as the app shows it. */
export interface ImageSlot {
	status: "running" | "done" | "failed" | "stopped";
	/** Absolute path of the saved picture, once done. */
	file?: string;
	error?: string;
	/** For a failure: whether it may have been billed anyway (timed out, connection lost). */
	maybeBilled?: boolean;
}

/** The tool's `details`, for the app's card (updates and the final result alike). */
export interface ImageDetails {
	model: string;
	size: ImageSize;
	prompt: string;
	/** Pictures asked for by the model, before the per-call cap. */
	asked: number;
	slots: ImageSlot[];
	/** Credits per picture (the router's rate), or null when unknown. */
	rate: number | null;
	/** Credits for the pictures made (rate × done), or null when unknown. Estimates: the router's figure is final. */
	credits: number | null;
	/** True when the model was picked as the cheapest one ("auto", or over a limit with "cheapest"). */
	cheapest: boolean;
	startedAt: number;
	finishedAt?: number;
}

export interface ImageLogEntry {
	ts: number;
	model: string;
	credits: number | null;
	file?: string;
}

export interface ImageHooks {
	settings(): ImageSettings;
	/** The saved GripHub key ("" when there is none). */
	key(): string;
	baseUrl: string;
	/** The router's image models (id, name). Throws when they cannot be read. */
	listModels(baseUrl: string, key: string): Promise<{ id: string; name: string }[]>;
	/** Credits per picture by the live rates, or null. */
	rate(model: string): number | null;
	/** All models the rate table has as per-picture, for when the model list cannot be read. */
	knownImageModels(): string[];
	generate(baseUrl: string, key: string, model: string, prompt: string, size: string, signal?: AbortSignal): Promise<string>;
	/** The account's daily-budget refusal for spending [extra] more credits now, or null. */
	budgetError(extra: number): string | null;
	now?(): number;
}

/** Normalizes a size a model sent ("16:9", "portrait", "1024X1536") to one the router takes; default square. */
export function imageSize(raw: unknown): ImageSize {
	const s = String(raw ?? "")
		.trim()
		.toLowerCase()
		.replace(/\s+/g, "")
		.replace("×", "x");
	if ((IMAGE_SIZES as readonly string[]).includes(s)) return s as ImageSize;
	return SIZE_WORDS[s] ?? "1024x1024";
}

/** The cheapest model with a known price; ties keep the list order. Null when none has a price. */
export function cheapestModel(models: ImageModel[]): ImageModel | null {
	let best: ImageModel | null = null;
	for (const m of models) if (m.credits !== null && (best === null || m.credits < (best.credits ?? Infinity))) best = m;
	return best;
}

/** File extension for picture bytes, by their first bytes (models return PNG, JPEG or WebP). */
export function imageExt(bytes: Buffer): string {
	if (bytes.length >= 4 && bytes[0] === 0x89 && bytes[1] === 0x50 && bytes[2] === 0x4e && bytes[3] === 0x47) return "png";
	if (bytes.length >= 3 && bytes[0] === 0xff && bytes[1] === 0xd8 && bytes[2] === 0xff) return "jpg";
	if (bytes.length >= 12 && bytes.toString("ascii", 0, 4) === "RIFF" && bytes.toString("ascii", 8, 12) === "WEBP") return "webp";
	return "";
}

/** A short file-name part from a prompt: "Logo kedai kopi, minimalis!" -> "logo-kedai-kopi-minimalis". */
export function slug(prompt: string): string {
	const s = prompt
		.toLowerCase()
		.normalize("NFKD")
		.replace(/[^\w\s-]/g, " ")
		.trim()
		.split(/[\s_-]+/)
		.filter(Boolean)
		.slice(0, 6)
		.join("-")
		.slice(0, 48)
		.replace(/-+$/, "");
	return s || "image";
}

/** Rounds credits for text the agent and the user read. */
function fmt(credits: number): string {
	return String(Math.round(credits * 100) / 100);
}

/**
 * The picture maker: the tool, the per-request spend, and the day's log. One per host; the tool is handed to each
 * interactive session (and to background ones when the user allows it), with that session's folder.
 */
export class Images {
	private models: { at: number; list: ImageModel[] } | null = null;
	/** Credits of pictures being made right now (all chats), so parallel calls cannot both fit under one limit. */
	private inFlight = 0;
	/** Credits spent on pictures in the current request of each session (keyed by the session, see tool()). */
	private runSpend = new WeakMap<object, number>();
	private log: ImageLogEntry[];

	constructor(
		private readonly logFile: string,
		private readonly hooks: ImageHooks,
	) {
		this.log = readSecureJson<ImageLogEntry[]>(logFile, [], Array.isArray).filter((e) => e && typeof e.ts === "number");
	}

	private now() {
		return this.hooks.now?.() ?? Date.now();
	}

	/** Pictures and credits today (WIB day), from the log. */
	today(): { day: string; count: number; credits: number } {
		const day = wibDay(this.now());
		const mine = this.log.filter((e) => wibDay(e.ts) === day);
		return { day, count: mine.length, credits: mine.reduce((s, e) => s + (e.credits ?? 0), 0) };
	}

	/** Credits of pictures made at or after [from] (ms): what the router's last snapshot does not include yet. */
	creditsSince(from: number): number {
		return this.log.filter((e) => e.ts >= from).reduce((s, e) => s + (e.credits ?? 0), 0);
	}

	/** Records a picture made outside the tool (the manual image screen). */
	record(model: string, file?: string) {
		this.push({ ts: this.now(), model, credits: this.hooks.rate(model), file });
	}

	private push(e: ImageLogEntry) {
		const cutoff = this.now() - LOG_KEEP_MS;
		this.log = [...this.log.filter((x) => x.ts >= cutoff), e];
		try {
			writeSecureJson(this.logFile, this.log);
		} catch {
			// The log only feeds limits and the usage line; a full disk must not fail a picture already made.
		}
	}

	/** The router's image models with their prices, cached for a while. Falls back to the rate table offline. */
	async imageModels(force = false): Promise<ImageModel[]> {
		if (!force && this.models && this.now() - this.models.at < MODELS_TTL_MS) return this.models.list;
		const key = this.hooks.key();
		let ids: { id: string; name: string }[];
		try {
			if (!key) throw new Error("no key");
			ids = await this.hooks.listModels(this.hooks.baseUrl, key);
		} catch (e) {
			// Offline or no key: the models the rate table knows, not cached (the next call tries the router again).
			const known = this.hooks.knownImageModels().map((id) => ({ id, name: id, credits: this.hooks.rate(id) }));
			if (known.length) return known;
			throw e;
		}
		const list = ids.map((m) => ({ ...m, credits: this.hooks.rate(m.id) }));
		this.models = { at: this.now(), list };
		return list;
	}

	/**
	 * Daily limit refusal for spending [cost] more on pictures now, or null: the picture cap, then the account's
	 * budget. Unknown prices count as 0 here (they are asked about before, see plan()).
	 */
	dailyError(cost: number): string | null {
		const s = this.hooks.settings();
		if (s.imageDailyCredits > 0) {
			const spent = this.today().credits + this.inFlight;
			if (spent + cost > s.imageDailyCredits + 1e-9) {
				return `Daily picture limit of ${fmt(s.imageDailyCredits)} credits reached (${fmt(spent)} spent on pictures today, this needs ${fmt(cost)} more). Raise it in Settings → Pictures.`;
			}
		}
		return this.hooks.budgetError(cost + this.inFlight);
	}

	/** Resets the per-request spend of a session (its agent run starts). */
	startRun(key: object) {
		this.runSpend.set(key, 0);
	}

	/**
	 * Works out which model makes how many pictures, or why it will not. [canAsk] is false where nobody can answer
	 * (a run nobody watches): what would be asked is refused then.
	 */
	async plan(
		params: { prompt?: unknown; count?: unknown; size?: unknown; model?: unknown },
		runKey: object,
		canAsk: boolean,
	): Promise<
		| { ok: true; model: ImageModel; count: number; asked: number; size: ImageSize; prompt: string; cheapest: boolean; askReason?: string }
		| { ok: false; error: string }
	> {
		const s = this.hooks.settings();
		const prompt = String(params.prompt ?? "").trim().slice(0, MAX_PROMPT_CHARS);
		if (!prompt) return { ok: false, error: "The prompt is empty: describe the picture to make." };
		if (!this.hooks.key()) return { ok: false, error: "No GripHub key is saved, so pictures cannot be made. The user can add one in Settings → GripHub Router." };
		const n = Math.floor(Number(params.count ?? 1));
		const asked = Number.isFinite(n) && n >= 1 ? n : 1;
		const count = Math.min(asked, s.imageMaxPerCall);
		const size = imageSize(params.size);

		let models: ImageModel[];
		try {
			models = await this.imageModels();
		} catch (e) {
			return { ok: false, error: `Could not read the router's image models: ${(e as Error).message}` };
		}
		if (!models.length) return { ok: false, error: "The router offers no image models right now." };
		const cheapest = cheapestModel(models);

		// The model: the one named in the call, else the user's default, else the cheapest.
		const want = String(params.model ?? "").trim() || (s.imageModel !== "auto" ? s.imageModel : "");
		let model: ImageModel | null;
		let isCheapest: boolean;
		if (want) {
			model = models.find((m) => m.id.toLowerCase() === want.toLowerCase()) ?? null;
			if (!model) {
				// A default that is gone (retired by the router) falls back to the cheapest; a model the agent made up is an error.
				if (String(params.model ?? "").trim()) {
					return { ok: false, error: `Unknown image model "${want}". Available: ${models.map((m) => m.id).join(", ")}.` };
				}
				model = cheapest ?? models[0];
			}
			isCheapest = !!cheapest && model.id === cheapest.id;
		} else {
			model = cheapest ?? models[0];
			isCheapest = !!cheapest;
		}

		const costOf = (m: ImageModel) => (m.credits === null ? null : m.credits * count);
		const runSpent = this.runSpend.get(runKey) ?? 0;

		// Hard limits first: the day's picture cap and the account's budget. "Cheapest" may still fit.
		let daily = this.dailyError(costOf(model) ?? 0);
		if (daily && s.imageOverLimit === "cheapest" && cheapest && cheapest.id !== model.id && !this.dailyError(costOf(cheapest) ?? 0)) {
			model = cheapest;
			isCheapest = true;
			daily = null;
		}
		if (daily) return { ok: false, error: daily };

		// Then the "without asking" limit, over the whole request.
		const overAuto = (m: ImageModel) => {
			const c = costOf(m);
			return c === null || s.imageAutoCredits === 0 || runSpent + c > s.imageAutoCredits + 1e-9;
		};
		if (!overAuto(model)) return { ok: true, model, count, asked, size, prompt, cheapest: isCheapest };
		if (s.imageOverLimit === "cheapest" && cheapest && !overAuto(cheapest)) {
			return { ok: true, model: cheapest, count, asked, size, prompt, cheapest: true };
		}
		const cost = costOf(model);
		const why =
			cost === null
				? `the price of ${model.id} is not known`
				: s.imageAutoCredits === 0
					? "every picture is asked about (Settings → Pictures)"
					: `about ${fmt(cost)} credits, over the ${fmt(s.imageAutoCredits)} credits a request may spend on pictures without asking${runSpent > 0 ? ` (${fmt(runSpent)} already spent in this request)` : ""}`;
		if (s.imageOverLimit === "refuse" || !canAsk) {
			return {
				ok: false,
				error: `Not made: ${why}. ${canAsk ? "The user set pictures over the limit to be refused" : "Nobody is watching this run to approve it"}; tell the user, and do not try to get around it.`,
			};
		}
		return { ok: true, model, count, asked, size, prompt, cheapest: isCheapest, askReason: why };
	}

	/**
	 * The pi tool. [runKey] identifies the session (its per-request spend, reset by startRun on agent_start); [ask]
	 * shows the user an approval card, absent where nobody watches.
	 */
	tool(runKey: object, cwd: () => string, ask?: (summary: string, reason: string) => Promise<boolean>) {
		const images = this;
		return {
			name: IMAGE_TOOL,
			label: "Generate image",
			description:
				"Make pictures (illustrations, logos, icons, photos, mockups) with GripHub Router's image models, and save them in the project's .images/ folder. " +
				"Use it when the user asks for a picture, not for diagrams or UI you can write as code (SVG, HTML). " +
				"Write a detailed prompt in English: subject, style, composition, colours, background, and any text that must appear (in quotes). " +
				"Each picture costs credits; the user's limits apply and may ask the user first or refuse. " +
				"You get the saved files' paths back, not the pictures: to look at one, read its file.",
			promptSnippet: `${IMAGE_TOOL}: make pictures with an image model; returns the saved files' paths`,
			promptGuidelines: [
				`Use ${IMAGE_TOOL} when the user asks for a picture, logo or illustration. Make as many as they ask for (one when they do not say), never more.`,
				`Leave the model out of ${IMAGE_TOOL} unless the user names one: their default (often the cheapest) is used.`,
				`If ${IMAGE_TOOL} is refused for a limit, tell the user which limit and where to change it; do not retry it in pieces.`,
			],
			parameters: Type.Object({
				prompt: Type.String({ description: "What to draw, in detail, in English." }),
				count: Type.Optional(Type.Number({ description: "How many pictures (default 1)." })),
				size: Type.Optional(Type.String({ description: "1024x1024 (square, default), 1536x1024 (landscape) or 1024x1536 (portrait)." })),
				model: Type.Optional(Type.String({ description: "Image model id; only when the user names one." })),
			}),
			// Runs one at a time: two calls in one step must not both fit under a limit meant for them together.
			executionMode: "sequential" as const,
			async execute(
				_toolCallId: string,
				params: { prompt: string; count?: number; size?: string; model?: string },
				signal?: AbortSignal,
				onUpdate?: (r: { content: { type: "text"; text: string }[]; details: ImageDetails }) => void,
			) {
				// Turned off while this chat was open (its tools are rebuilt once it is idle).
				if (!images.hooks.settings().imageAgentTool) throw new Error("Making pictures is turned off in Settings → Pictures.");
				const plan = await images.plan(params, runKey, !!ask);
				if (!plan.ok) throw new Error(plan.error);
				if (plan.askReason) {
					const summary = `${plan.count} × ${plan.model.id} (${plan.size})${plan.model.credits !== null ? ` ≈ ${fmt(plan.model.credits * plan.count)} credits` : ""}\n${plan.prompt}`;
					const ok = await ask!(summary, "Over your picture limit without asking");
					if (!ok) throw new Error(`The user declined: ${plan.askReason}. Ask what they would like instead.`);
					// The answer may have taken a while: the day may have filled up meanwhile.
					const daily = images.dailyError((plan.model.credits ?? 0) * plan.count);
					if (daily) throw new Error(daily);
				}
				return images.make(plan, runKey, cwd(), signal, onUpdate);
			},
		};
	}

	/** Makes the planned pictures in parallel, reporting each as it lands. */
	private async make(
		plan: { model: ImageModel; count: number; asked: number; size: ImageSize; prompt: string; cheapest: boolean },
		runKey: object,
		cwd: string,
		signal: AbortSignal | undefined,
		onUpdate: ((r: { content: { type: "text"; text: string }[]; details: ImageDetails }) => void) | undefined,
	) {
		const rate = plan.model.credits;
		const reserved = (rate ?? 0) * plan.count;
		this.inFlight += reserved;
		this.runSpend.set(runKey, (this.runSpend.get(runKey) ?? 0) + reserved);
		const details: ImageDetails = {
			model: plan.model.id,
			size: plan.size,
			prompt: plan.prompt,
			asked: plan.asked,
			slots: Array.from({ length: plan.count }, () => ({ status: "running" as const })),
			rate,
			credits: rate === null ? null : 0,
			cheapest: plan.cheapest,
			startedAt: this.now(),
		};
		const done = () => details.slots.filter((x) => x.status === "done").length;
		const report = () =>
			onUpdate?.({
				content: [{ type: "text", text: `Making ${plan.count} picture${plan.count > 1 ? "s" : ""} with ${plan.model.id}: ${done()} done` }],
				details: structuredClone(details),
			});
		report();

		const dir = join(cwd, ".images");
		const stamp = new Date(details.startedAt).toISOString().replace(/[-:]/g, "").replace("T", "-").slice(0, 15);
		const base = `${stamp}-${slug(plan.prompt)}`;
		let released = 0;
		const release = (credits: number) => {
			released += credits;
			this.inFlight = Math.max(0, this.inFlight - credits);
		};

		try {
			await Promise.all(
				details.slots.map(async (slot, i) => {
					try {
						const b64 = await this.hooks.generate(this.hooks.baseUrl, this.hooks.key(), plan.model.id, plan.prompt, plan.size, signal);
						const bytes = Buffer.from(b64, "base64");
						const ext = imageExt(bytes);
						if (!ext) throw new ImageError("The router sent something that is not a picture", 200, true);
						mkdirSync(dir, { recursive: true });
						// Keep pictures out of git (the folder ignores itself), like .screenshots.
						if (!existsSync(join(dir, ".gitignore"))) writeFileSync(join(dir, ".gitignore"), "*\n");
						const file = join(dir, `${base}${plan.count > 1 ? `-${i + 1}` : ""}.${ext}`);
						writeFileSync(file, bytes);
						slot.status = "done";
						slot.file = file;
						if (details.credits !== null) details.credits += rate ?? 0;
						release(rate ?? 0);
						this.push({ ts: this.now(), model: plan.model.id, credits: rate, file });
					} catch (e) {
						// Duck-typed: a failure that knows whether it may have been billed says so; anything else was not sent.
						const err = { message: (e as Error)?.message ?? String(e), maybeBilled: (e as { maybeBilled?: unknown })?.maybeBilled === true };
						slot.status = signal?.aborted ? "stopped" : "failed";
						slot.error = err.message;
						slot.maybeBilled = err.maybeBilled;
						release(rate ?? 0);
						// A request that may have been billed is counted toward the day, so the limits stay on the safe side.
						if (err.maybeBilled) this.push({ ts: this.now(), model: plan.model.id, credits: rate });
						// What was not spent goes back to the request's allowance.
						if (!err.maybeBilled) this.runSpend.set(runKey, Math.max(0, (this.runSpend.get(runKey) ?? 0) - (rate ?? 0)));
					}
					report();
				}),
			);
		} finally {
			// Whatever happened, nothing stays reserved.
			if (released < reserved) this.inFlight = Math.max(0, this.inFlight - (reserved - released));
		}
		details.finishedAt = this.now();

		const made = details.slots.filter((s) => s.status === "done");
		const lines: string[] = [];
		if (made.length) {
			lines.push(`Made ${made.length} of ${plan.count} picture${plan.count > 1 ? "s" : ""} with ${plan.model.id} (${plan.size}), saved to:`);
			for (const s of made) lines.push(`- ${s.file}`);
		}
		if (plan.asked > plan.count) {
			lines.push(`Only ${plan.count} of the ${plan.asked} asked for were made: the user's limit is ${plan.count} per request (Settings → Pictures).`);
		}
		const failed = details.slots.filter((s) => s.status !== "done");
		for (const s of failed) {
			lines.push(
				s.status === "stopped"
					? "One picture was stopped by the user."
					: `One picture failed: ${s.error}${s.maybeBilled ? " (it may still have been billed; do not retry it on your own)" : " (not billed)"}`,
			);
		}
		if (details.credits !== null && made.length) lines.push(`About ${fmt(details.credits)} credits.`);
		if (made.length) lines.push("The user sees the pictures in the chat. Do not paste the paths unless they help.");
		const text = lines.join("\n");
		return { content: [{ type: "text" as const, text }], details, isError: made.length === 0 };
	}
}
