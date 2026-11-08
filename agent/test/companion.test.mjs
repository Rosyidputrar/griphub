// Screen companion's pure parts (companion.ts): where to point from a reply, the request-time frame, the instruction.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readdirSync, readFileSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { bundle } from "./helpers.mjs";

const c = await bundle("companion");
const here = dirname(fileURLToPath(import.meta.url));

test("the pointer comes from the reply's SOROT line: an element, or a box", () => {
	assert.deepEqual(c.pointerOf("Ketuk Transfer.\nSOROT: #n1"), { id: "n1" });
	assert.deepEqual(c.pointerOf("Ketuk di sini\nSOROT: 40, 1800, 300,120"), { x: 40, y: 1800, w: 300, h: 120 });
	assert.equal(c.pointerOf("Sudah selesai, tujuanmu tercapai."), null);
	assert.equal(c.pointerOf("SOROT: di sana"), null, "nothing made up from a vague line");
	assert.deepEqual(c.pointerOf("Ketuk.\nSOROT: #n7."), { id: "n7" }, "a full stop after the id");
	assert.deepEqual(c.pointerOf("SOROT: 1, 2, 3, 4 (tombol)"), { x: 1, y: 2, w: 3, h: 4 });
	assert.equal(c.withoutPointer("Ketuk Transfer.\nSOROT: #n1"), "Ketuk Transfer.");
});

test("the frame goes onto the last companion turn of the request's copy, and only there", () => {
	const msgs = [
		{ role: "user", content: "halo" },
		{ role: "assistant", content: [{ type: "text", text: "hai" }] },
		{ role: "user", content: `${c.COMPANION_MARK}\nThe user: bantu` },
	];
	const out = c.withFrame(msgs, { data: "AAA", mimeType: "image/png", tree: '#n1 "Transfer" 1,2,3,4' });
	assert.equal(out.at(-1).content.at(-1).type, "image");
	assert.match(out.at(-1).content[1].text, /Transfer/);
	assert.equal(typeof msgs.at(-1).content, "string", "the original messages are not touched");
	assert.equal(c.withFrame(msgs, null), undefined);
	assert.equal(c.withFrame([{ role: "user", content: "biasa" }], { data: "A", mimeType: "image/png" }), undefined, "not on an ordinary message");
});

test("the instruction never offers to act, and never keeps the screen's text", () => {
	const t = c.companionInstruction({ goal: "transfer", tree: true, width: 1080, height: 2400, secure: false });
	assert.match(t, /You cannot tap, swipe or type for them/);
	assert.match(t, /ONE step at a time/);
	assert.doesNotMatch(t, /Transfer"/, "no element text in what is kept");
	assert.match(c.companionInstruction({ goal: "x", tree: false, width: 1, height: 1, secure: true }), /cannot be seen/);
});

test("nothing in the app can tap for the user: no gesture or click is dispatched anywhere", () => {
	const root = join(here, "..", "..", "android", "app", "src", "main");
	const kotlin = [];
	const walk = (d) => {
		for (const e of readdirSync(d, { withFileTypes: true })) {
			const p = join(d, e.name);
			if (e.isDirectory()) walk(p);
			else if (/\.(kt|java)$/.test(e.name)) kotlin.push([p, readFileSync(p, "utf8")]);
		}
	};
	walk(join(root, "kotlin"));
	for (const [p, src] of kotlin) {
		assert.doesNotMatch(src, /dispatchGesture|performGlobalAction|ACTION_CLICK|ACTION_SET_TEXT|performAction\(/, p);
	}
	const a11y = readFileSync(join(root, "res", "xml", "companion_accessibility.xml"), "utf8");
	assert.match(a11y, /android:canPerformGestures="false"/);
});
