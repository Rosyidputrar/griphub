// Self-verification runs the project's own test command, which is code that came with the project (a freshly cloned
// repository's `npm test` runs whatever it says). The first one in a folder is asked about in the default mode, refused
// where nobody watches, and a yes covers that folder; the user's own command from Settings is theirs and not asked.
import { test } from "node:test";
import assert from "node:assert/strict";
import { bundle } from "./helpers.mjs";

const { Guard, PROJECT_CHECK_RISK } = await bundle("guard");

function rig(mode) {
	const sent = [];
	const guard = new Guard({ send: (r) => sent.push(r), checkpoint: async () => {}, cwd: () => "/work", chat: () => "c.jsonl" });
	guard.mode = mode;
	/** Asks to run [command] for [project]; [allow] answers a card if one is shown. */
	const check = async (command, project, { allow = true, always = false } = {}) => {
		const before = sent.length;
		const call = guard.allowCommand(command, project);
		await new Promise((r) => setImmediate(r));
		const asked = sent.length > before ? sent.at(-1) : null;
		if (asked) guard.reply(asked.approvalId, allow, always, asked.key);
		return { refused: await call, asked };
	};
	return { guard, check };
}

test("the first check of a folder is asked about, with what it runs; a yes covers that folder only", async () => {
	const { check } = rig("ask_risky");
	const first = await check("npm test", "/work/repo");
	assert.equal(first.asked?.reason, PROJECT_CHECK_RISK);
	assert.match(first.asked.summary, /npm test/);
	assert.equal(first.refused, null);
	assert.equal((await check("npm test", "/work/repo")).asked, null, "not asked again in that folder");
	assert.ok((await check("npm test", "/work/other")).asked, "another folder is asked about");
});

test("a no runs nothing and is asked again next time", async () => {
	const { check } = rig("ask_risky");
	const no = await check("npm test", "/work/repo", { allow: false });
	assert.match(no.refused, /declined/);
	assert.ok((await check("npm test", "/work/repo")).asked);
});

test("nobody watching: refused unless it was allowed in that folder before", async () => {
	const { guard, check } = rig("ask_risky");
	await check("npm test", "/work/repo");
	guard.mode = "deny_risky";
	assert.equal((await check("npm test", "/work/repo")).refused, null, "allowed there already");
	const other = await check("npm test", "/work/new");
	assert.equal(other.asked, null, "no question where nobody can answer");
	assert.match(other.refused, /not been allowed to run in this folder/);
});

test("the user's own command (no project given) and Bypass all are not asked about here", async () => {
	assert.equal((await rig("ask_risky").check("make check", undefined)).asked, null);
	assert.equal((await rig("auto").check("npm test", "/work/repo")).asked, null);
});
