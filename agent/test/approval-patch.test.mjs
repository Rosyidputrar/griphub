// The approval card for an edit or a write carries the change as a unified patch, so it is seen before it is allowed;
// when the change can't be told for certain the card has the path alone, as before.
import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { build } from "esbuild";

const here = dirname(fileURLToPath(import.meta.url));
mkdirSync(join(here, "..", "build"), { recursive: true });
const out = mkdtempSync(join(here, "..", "build", "approval-patch-test-"));
const outfile = join(out, "guard.mjs");
await build({ entryPoints: [join(here, "..", "src", "guard.ts")], outfile, bundle: true, platform: "node", format: "esm", packages: "external", logLevel: "error" });
const { Guard, proposedPatch, editsOf } = await import(pathToFileURL(outfile).href);

function project(files) {
	const dir = mkdtempSync(join(tmpdir(), "approval-patch-"));
	for (const [name, text] of Object.entries(files)) writeFileSync(join(dir, name), text);
	return dir;
}

test("an edit's patch shows the lines it replaces and the ones it puts in", async () => {
	const cwd = project({ "app.js": "const a = 1;\nconst b = 2;\nconsole.log(a + b);\n" });
	const patch = await proposedPatch("edit", { path: "app.js", edits: [{ oldText: "const b = 2;", newText: "const b = 3;" }] }, cwd);
	assert.match(patch, /^--- app\.js\n\+\+\+ app\.js\n@@ /m);
	assert.match(patch, /^-const b = 2;$/m);
	assert.match(patch, /^\+const b = 3;$/m);
	assert.match(patch, /^ const a = 1;$/m, "with context around it");
});

test("each shape models send an edit in: an array, a JSON string, one object, the old oldText/newText", async () => {
	const cwd = project({ "a.txt": "one\ntwo\nthree\n" });
	const one = { oldText: "two", newText: "2" };
	for (const input of [{ edits: [one] }, { edits: JSON.stringify([one]) }, { edits: one }, { ...one }]) {
		assert.deepEqual(editsOf(input), [one]);
		assert.match(await proposedPatch("edit", { path: "a.txt", ...input }, cwd), /^\+2$/m);
	}
	assert.equal(editsOf({ edits: "not json" }), null);
	assert.equal(editsOf({ edits: [] }), null);
});

test("several edits in one call are matched against the original, like pi's edit tool", async () => {
	const cwd = project({ "a.txt": "alpha\nbeta\ngamma\ndelta\n" });
	const patch = await proposedPatch("edit", { path: "a.txt", edits: [{ oldText: "delta", newText: "D" }, { oldText: "alpha", newText: "A" }] }, cwd);
	assert.match(patch, /^\+A$/m);
	assert.match(patch, /^\+D$/m);
});

test("no patch when the change can't be told for certain: the card shows the path alone", async () => {
	const cwd = project({ "a.txt": "same\nsame\n", "b.txt": "x\n" });
	assert.equal(await proposedPatch("edit", { path: "a.txt", edits: [{ oldText: "same", newText: "s" }] }, cwd), undefined, "the text is there twice");
	assert.equal(await proposedPatch("edit", { path: "b.txt", edits: [{ oldText: "missing", newText: "y" }] }, cwd), undefined, "the text isn't there");
	assert.equal(await proposedPatch("edit", { path: "nope.txt", edits: [{ oldText: "a", newText: "b" }] }, cwd), undefined, "no such file");
	assert.equal(await proposedPatch("edit", { path: "b.txt", edits: [{ oldText: "x", newText: "x" }] }, cwd), undefined, "no change");
	assert.equal(
		await proposedPatch("edit", { path: "a.txt", edits: [{ oldText: "same\nsa", newText: "1" }, { oldText: "same\nsame", newText: "2" }] }, cwd),
		undefined,
		"overlapping edits",
	);
	writeFileSync(join(cwd, "big.txt"), "x".repeat(600 * 1024));
	assert.equal(await proposedPatch("write", { path: "big.txt", content: "small" }, cwd), undefined, "too big to preview");
	writeFileSync(join(cwd, "bin.dat"), Buffer.from([1, 0, 2]));
	assert.equal(await proposedPatch("write", { path: "bin.dat", content: "text" }, cwd), undefined, "binary");
	assert.equal(await proposedPatch("bash", { command: "rm -rf x" }, cwd), undefined, "not a file tool");
});

test("a write shows a new file as all added, and an overwrite as what changes", async () => {
	const cwd = project({ "old.txt": "keep\nchange me\n" });
	const fresh = await proposedPatch("write", { path: "new.txt", content: "hello\nworld\n" }, cwd);
	assert.match(fresh, /^\+hello$/m);
	assert.doesNotMatch(fresh, /^-(?!-- )/m, "nothing removed");
	const over = await proposedPatch("write", { path: "old.txt", content: "keep\nchanged\n" }, cwd);
	assert.match(over, /^-change me$/m);
	assert.match(over, /^\+changed$/m);
});

test("Windows line endings in the file or the edit don't stop the match, and don't show as changed lines", async () => {
	const cwd = project({ "w.txt": "first\r\nsecond\r\nthird\r\n" });
	const patch = await proposedPatch("edit", { path: "w.txt", edits: [{ oldText: "second\r\n", newText: "2nd\n" }] }, cwd);
	assert.match(patch, /^-second$/m);
	assert.match(patch, /^\+2nd$/m);
	assert.doesNotMatch(patch, /\r/);
});

test("the guard puts the patch on the approval it sends, and only for edits and writes", async () => {
	const cwd = project({ "a.txt": "hello\n" });
	const sent = [];
	const guard = new Guard({ send: (r) => sent.push(r), checkpoint: async () => {}, cwd: () => cwd });
	guard.mode = "ask_all";
	const handlers = {};
	guard.extension({ on: (name, fn) => (handlers[name] = fn), registerTool() {}, registerCommand() {} });
	const call = handlers.tool_call({ toolName: "edit", input: { path: "a.txt", edits: [{ oldText: "hello", newText: "hi" }] } });
	for (let i = 0; i < 50 && !sent.some((r) => r.type === "approval"); i++) await new Promise((r) => setTimeout(r, 5));
	const card = sent.find((r) => r.type === "approval");
	assert.equal(card.summary, "a.txt");
	assert.match(card.patch, /^\+hi$/m);
	guard.reply(card.approvalId, true);
	assert.equal(await call, undefined, "allowed: the call goes ahead");

	const bash = handlers.tool_call({ toolName: "bash", input: { command: "echo hi > a.txt" } });
	for (let i = 0; i < 50 && sent.filter((r) => r.type === "approval").length < 2; i++) await new Promise((r) => setTimeout(r, 5));
	const second = sent.filter((r) => r.type === "approval")[1];
	assert.equal(second.patch, undefined);
	guard.reply(second.approvalId, false);
	assert.equal((await bash).block, true);
});
