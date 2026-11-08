/**
 * Screen companion (Fitur 5): the user, stuck in another app, lets the agent see the screen and is guided one step at
 * a time. The agent sees and guides; the user's finger acts. Nothing here can tap, swipe or type anywhere.
 *
 * A frame (one screenshot, taken by the phone only when a step needs it) goes to the router as context of the active
 * chat for that one request, and nowhere else: it is not in the user's message, so it is not in the chat's file; it is
 * added to the request by pi's `context` hook (a copy of the messages, per request), held in memory only until the
 * turn ends, and dropped when the companion stops. Not logged, not remembered (memory.ts), not written anywhere.
 */

/** The marker the user's turn carries, so the request-time hook knows where the frame goes. */
export const COMPANION_MARK = "[Pendamping layar]";

/** What the model is told with each step (in the user's turn; the frame itself is attached only to the request). */
export function companionInstruction(o: { goal: string; tree: boolean; width: number; height: number; secure: boolean }): string {
	if (o.secure) {
		return [
			COMPANION_MARK,
			"The screen the user is on cannot be seen: Android hides it (a secure screen such as a banking app or a password field).",
			"Say so plainly in one or two sentences, and suggest what the user can do. Do not guess what is on it.",
			"",
			`The user: ${o.goal}`,
		].join("\n");
	}
	return [
		COMPANION_MARK,
		`The picture with this message is the user's phone screen right now (${o.width}×${o.height} pixels). It is not kept.`,
		"Guide the user ONE step at a time towards their goal, in one or two short sentences, in their language.",
		"You cannot tap, swipe or type for them, and must not offer to: the user does it.",
		"When the step is about one element on screen, end with a line exactly like:",
		o.tree ? "SOROT: #<id from the list below>" : "SOROT: <x>,<y>,<width>,<height>   (pixels on the picture: the element's box)",
		"Leave that line out when no element needs pointing at. When the goal is reached, say so and give no SOROT line.",
		"If the screen looks black or empty, say you cannot see it; never invent what is on it.",
		// The elements themselves come with the picture, for this request only: screen text is not kept either.
		...(o.tree ? ["The list of elements on screen comes with the picture."] : []),
		"",
		`The user: ${o.goal}`,
	].join("\n");
}

/** Where to point, from a reply: an element of the tree, or a box on the frame; null when the reply points at nothing. */
export type Pointer = { id: string } | { x: number; y: number; w: number; h: number };

export function pointerOf(reply: string): Pointer | null {
	const line = reply.split("\n").reverse().find((l) => /^\s*SOROT\s*:/i.test(l));
	if (!line) return null;
	const v = line.replace(/^\s*SOROT\s*:\s*/i, "").trim();
	// What follows the id or the box (a full stop, a word) does not matter; a line with neither points at nothing.
	const id = /^#([\w-]+)/.exec(v);
	if (id) return { id: id[1] };
	const box = /^(\d+)\s*,\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)/.exec(v);
	if (box) return { x: +box[1], y: +box[2], w: +box[3], h: +box[4] };
	return null;
}

/** The reply without its SOROT line, as the user reads it. */
export function withoutPointer(reply: string): string {
	return reply
		.split("\n")
		.filter((l) => !/^\s*SOROT\s*:/i.test(l))
		.join("\n")
		.trim();
}

/** A UI tree node from the phone's accessibility service (only when the user turned it on). */
export interface TreeNode {
	id: string;
	text?: string;
	desc?: string;
	x: number;
	y: number;
	w: number;
	h: number;
}

/** The tree as the model reads it: short lines, password fields never carry text (the phone leaves it out). */
export function treeText(nodes: TreeNode[], max = 120): string {
	return nodes
		.slice(0, max)
		.map((n) => `#${n.id} "${(n.text || n.desc || "").replace(/\s+/g, " ").slice(0, 80)}" ${n.x},${n.y},${n.w},${n.h}`)
		.join("\n");
}

/** One frame (and, when the user turned it on, the screen's elements) held for one request; dropped after it. */
export interface Frame {
	data: string;
	mimeType: string;
	tree?: string;
}

/**
 * The request-time hook: the held frame goes onto the last companion turn of the copy of the messages pi sends (the
 * chat's file never sees it). Returns the messages to send, or undefined when there is nothing to add.
 */
export function withFrame(messages: any[], frame: Frame | null): any[] | undefined {
	if (!frame) return undefined;
	for (let i = messages.length - 1; i >= 0; i--) {
		const m = messages[i];
		if (m?.role !== "user") continue;
		const text = typeof m.content === "string" ? m.content : (m.content ?? []).filter((c: any) => c?.type === "text").map((c: any) => c.text).join("\n");
		if (!text.includes(COMPANION_MARK)) return undefined;
		const content = typeof m.content === "string" ? [{ type: "text", text: m.content }] : [...m.content];
		if (frame.tree) content.push({ type: "text", text: `Elements on screen (id, text, box x,y,w,h in screen pixels):\n${frame.tree}` });
		content.push({ type: "image", data: frame.data, mimeType: frame.mimeType });
		const out = messages.slice();
		out[i] = { ...m, content };
		return out;
	}
	return undefined;
}
