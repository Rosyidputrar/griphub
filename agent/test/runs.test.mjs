// Removing one finished run from the Tasks list (swipe), with Undo.
import { test, after } from "node:test";
import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, readFileSync, rmSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { build } from "esbuild";

const here = dirname(fileURLToPath(import.meta.url));
mkdirSync(join(here, "..", "build"), { recursive: true });
const out = mkdtempSync(join(here, "..", "build", "runs-test-"));
async function bundle(name) {
	const outfile = join(out, `${name}.mjs`);
	await build({ entryPoints: [join(here, "..", "src", `${name}.ts`)], outfile, bundle: true, platform: "node", format: "esm", packages: "external", logLevel: "error" });
	return import(pathToFileURL(outfile).href);
}
const { Runner } = await bundle("runs");

const runners = [];
/** A runner over a saved list; its timers are cleared after the tests. */
function runner(runs) {
	const file = join(mkdtempSync(join(out, "r-")), "runs.json");
	const sent = [];
	const r = new Runner(file, async () => ({}), (rec) => sent.push(rec), async () => []);
	r.store.runs = runs.map((x) => ({ title: x.id, prompt: "p", cwd: "/w", source: "queue", createdAt: 1, ...x }));
	runners.push(r);
	return { r, file, sent };
}
after(() => {
	for (const r of runners) r.dispose();
	rmSync(out, { recursive: true, force: true });
});

const ids = (r) => r.summary().runs.map((x) => x.id);

test("a finished run is removed, saved, announced, and comes back at its place on Undo", () => {
	const { r, file, sent } = runner([
		{ id: "a", status: "done" },
		{ id: "b", status: "error" },
		{ id: "c", status: "cancelled" },
	]);
	const removed = r.delete("b");
	assert.deepEqual(removed.index, 1);
	assert.equal(removed.run.id, "b");
	assert.deepEqual(ids(r), ["a", "c"]);
	assert.deepEqual(JSON.parse(readFileSync(file, "utf8")).runs.map((x) => x.id), ["a", "c"]);
	assert.deepEqual(sent.at(-1).runs.map((x) => x.id), ["a", "c"]);

	r.restore(removed.run, removed.index);
	assert.deepEqual(ids(r), ["a", "b", "c"]);
	// Undo twice (double tap) doesn't duplicate it.
	r.restore(removed.run, removed.index);
	assert.deepEqual(ids(r), ["a", "b", "c"]);
});

test("queued and running runs can't be removed, only cancelled", () => {
	const { r } = runner([
		{ id: "q", status: "queued" },
		{ id: "x", status: "running" },
	]);
	assert.throws(() => r.delete("q"), /Cancel the run/);
	assert.throws(() => r.delete("x"), /Cancel the run/);
	assert.deepEqual(ids(r), ["q", "x"]);
});

test("an unknown id is a no-op; Undo of a list that shrank meanwhile lands at the end", () => {
	const { r } = runner([
		{ id: "a", status: "done" },
		{ id: "b", status: "done" },
		{ id: "c", status: "done" },
	]);
	assert.equal(r.delete("nope"), null);
	const removed = r.delete("c");
	r.clearFinished();
	r.restore(removed.run, removed.index);
	assert.deepEqual(ids(r), ["c"]);
});

test("Undo can't sneak a queued run back in", () => {
	const { r } = runner([]);
	r.restore({ id: "z", status: "queued", title: "z" }, 0);
	assert.deepEqual(ids(r), []);
});
