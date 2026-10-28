/**
 * Follow-ups sent while the agent works.
 *
 * They wait in pi's queue until the turn reaches a boundary (they are never
 * steered into the running turn). pi keeps only their text, so this mirrors
 * them with their images and an id, for the app to show as waiting bubbles
 * and to cancel one. pi can only clear the whole queue, so removing one
 * clears it and queues the rest again, in order.
 */

/** The parts of pi's AgentSession this needs (a fake in tests). */
export interface QueueSession {
	readonly isStreaming: boolean;
	prompt(text: string, options?: { images?: any[]; streamingBehavior?: "steer" | "followUp" }): Promise<void>;
	clearQueue(): { steering: string[]; followUp: string[] };
	getFollowUpMessages(): readonly string[];
}

export interface QueuedPrompt {
	id: string;
	/** What pi was given (plan mode adds an instruction). */
	text: string;
	/** What the user typed, for the bubble. */
	shown: string;
	images?: any[];
	at: number;
}

export class PromptQueue {
	private items: QueuedPrompt[] = [];
	private next = 1;
	/** While the queue is being rebuilt, pi's own queue updates are ours. */
	private rebuilding = false;

	constructor(
		private readonly emit: (items: { id: string; text: string; images: number; at: number }[]) => void,
		private readonly onError: (message: string) => void = () => {},
	) {}

	list() {
		return this.items.map((q) => ({ id: q.id, text: q.shown, images: q.images?.length ?? 0, at: q.at }));
	}

	private changed() {
		this.emit(this.list());
	}

	/**
	 * Queues a follow-up on a streaming session. Returns its id, or null when
	 * a boundary consumed it during the call (it is already in the chat).
	 */
	async add(s: QueueSession, text: string, shown: string, images?: any[]): Promise<string | null> {
		const q: QueuedPrompt = { id: `q${this.next++}`, text, shown, images, at: Date.now() };
		await s.prompt(text, { images, streamingBehavior: "followUp" });
		if (s.getFollowUpMessages().length <= this.items.length) return null;
		this.items.push(q);
		this.changed();
		return q.id;
	}

	/** pi's queue now holds [left] follow-ups: the oldest of ours were delivered (or dropped). */
	sync(left: number) {
		if (this.rebuilding || left >= this.items.length) return;
		this.items = left <= 0 ? [] : this.items.slice(this.items.length - left);
		this.changed();
	}

	/** The chat is closing: what waited goes with it. */
	clear() {
		if (!this.items.length) return;
		this.items = [];
		this.changed();
	}

	/** Cancels one queued follow-up; the others keep their order. */
	async remove(s: QueueSession, id: string, waitMs = 2000) {
		if (!this.items.some((q) => q.id === id)) throw new Error("That message was already sent");
		const rest = this.items.filter((q) => q.id !== id);
		this.rebuilding = true;
		try {
			s.clearQueue();
			this.items = [];
			for (const q of rest) {
				if (s.isStreaming) {
					await s.prompt(q.text, { images: q.images, streamingBehavior: "followUp" });
					this.items.push(q);
					continue;
				}
				// The turn ended meanwhile: this one starts the next turn, the rest wait behind it.
				s.prompt(q.text, { images: q.images }).catch((e) => this.onError(String(e?.message ?? e)));
				for (let waited = 0; waited < waitMs && !s.isStreaming; waited += 25) {
					await new Promise((r) => setTimeout(r, 25));
				}
			}
		} finally {
			this.rebuilding = false;
		}
		this.changed();
		return { items: this.items.map((q) => q.id) };
	}
}
