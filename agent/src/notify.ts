/**
 * Adapted from CoderRa's server mode (seseegy/coderra agent/src/notify.ts); see server_agent.md.
 *
 * Push notifications through ntfy (https://ntfy.sh, or a server of your own), for when the app is not open: the agent
 * finished, wants an approval, or something needs attention. They carry only a generic title: topic names on a public
 * server are not secret from whoever guesses them, so nothing about the project or the conversation goes in them.
 */

export interface NotifyConfig {
	url: string;
	topic: string;
}

export interface NotifyOptions {
	/** The current settings, or null when notifications are off or not set up. Read on every send. */
	config: () => NotifyConfig | null;
	/** False while someone is looking at the app: they do not need a push for what they can see. */
	shouldSend: () => boolean;
	/** At most one message of a kind per this long. */
	minIntervalMs?: number;
	fetch?: typeof fetch;
	now?: () => number;
	log?: (message: string) => void;
}

export interface SendOptions {
	/** ntfy priority, 1 (min) to 5 (max). Default 3. */
	priority?: 1 | 2 | 3 | 4 | 5;
	tags?: string[];
	message?: string;
}

/** Whether a url and topic can be used. Returns the reason if not. */
export function checkConfig(c: Partial<NotifyConfig> | null | undefined): string | null {
	if (!c?.url || !c.topic) return "A server address and a topic are both needed.";
	try {
		const u = new URL(c.url);
		if (u.protocol !== "https:" && u.protocol !== "http:") return "The server address must start with https:// or http://.";
	} catch {
		return "The server address is not a valid URL.";
	}
	if (!/^[A-Za-z0-9_-]{8,64}$/.test(c.topic)) return "The topic must be 8 to 64 letters, digits, - or _.";
	return null;
}

export class Notifier {
	private readonly lastSent = new Map<string, number>();

	constructor(private readonly o: NotifyOptions) {}

	/** Sends one push. Never throws; resolves whether it went out. */
	async send(kind: string, title: string, options: SendOptions = {}): Promise<boolean> {
		try {
			const config = this.o.config();
			if (!config || checkConfig(config)) return false;
			if (!this.o.shouldSend()) return false;
			const now = (this.o.now ?? Date.now)();
			const last = this.lastSent.get(kind);
			if (last !== undefined && now - last < (this.o.minIntervalMs ?? 60_000)) return false;
			this.lastSent.set(kind, now);

			const res = await this.post(config, title, options);
			if (!res.ok) {
				this.o.log?.(`ntfy answered ${res.status}`);
				return false;
			}
			return true;
		} catch (e) {
			this.o.log?.(`could not send a notification: ${(e as Error).message}`);
			return false;
		}
	}

	/**
	 * Sends a test push now, with the app open (that is when someone presses the button) and outside the rate limit.
	 * Says why when it does not go out: `off` (not set up or switched off), `config` (with the reason), `http` (the ntfy
	 * server's status), or `network`.
	 */
	async test(): Promise<{ ok: true } | { ok: false; reason: "off" | "config" | "http" | "network"; detail?: string }> {
		const config = this.o.config();
		if (!config) return { ok: false, reason: "off" };
		const bad = checkConfig(config);
		if (bad) return { ok: false, reason: "config", detail: bad };
		try {
			const res = await this.post(config, "Test notification", { tags: ["bell"], message: "Notifications from GripHub arrive on this phone." });
			return res.ok ? { ok: true } : { ok: false, reason: "http", detail: String(res.status) };
		} catch (e) {
			return { ok: false, reason: "network", detail: (e as Error).message };
		}
	}

	private post(config: NotifyConfig, title: string, options: SendOptions) {
		const headers: Record<string, string> = {
			// Header values are plain ASCII.
			Title: title.replace(/[^\x20-\x7e]/g, "?"),
			Priority: String(options.priority ?? 3),
		};
		if (options.tags?.length) headers.Tags = options.tags.join(",");
		return (this.o.fetch ?? fetch)(`${config.url.replace(/\/+$/, "")}/${encodeURIComponent(config.topic)}`, {
			method: "POST",
			headers,
			body: options.message ?? "Open GripHub to see.",
			signal: AbortSignal.timeout(5000),
		});
	}
}
