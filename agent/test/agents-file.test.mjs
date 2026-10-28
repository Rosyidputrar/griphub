// The environment notes pi reads at the start of every session (agents-file.ts). The phone's text must stay exactly what
// the host wrote before server mode existed (fixtures/agents-phone.md was made from that code); a server gets its own.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { bundle } from "./helpers.mjs";

const { AGENTS_MARKER, agentsFileText, isManaged } = await bundle("agents-file");
const here = dirname(fileURLToPath(import.meta.url));
const PHONE_WS = "/data/user/0/id.griphub.agent/files/workspace";

test("the phone's notes are byte for byte what the host wrote before server mode", () => {
	const before = readFileSync(join(here, "fixtures", "agents-phone.md"), "utf8");
	assert.equal(agentsFileText({ mode: "phone", workspace: PHONE_WS }), before);
	// Any mode that is not "server" is the phone (an unset GRIPHUB_MODE on the phone, say).
	assert.equal(agentsFileText({ mode: "", workspace: PHONE_WS, box: true }), before);
});

test("a server's notes describe the server, with or without the box", () => {
	const ws = "/home/griphub/workspace";
	const inBox = agentsFileText({ mode: "server", workspace: ws, box: true });
	const bare = agentsFileText({ mode: "server", workspace: ws, box: false });
	for (const text of [inBox, bare]) {
		assert.ok(text.startsWith(`${AGENTS_MARKER}\n# Environment\n`));
		assert.match(text, /on a Linux server/);
		assert.match(text, new RegExp(`The workspace directory is ${ws}\\.`));
		// Nothing of the phone: no Android shell, no proot container, no device key.
		assert.doesNotMatch(text, /Android|mksh|toybox|proot|\/system\/bin\/sh|id_ed25519/);
		// What GripHub's agent relies on everywhere.
		assert.match(text, /todo_write/);
		assert.match(text, /pasted-text\.txt/);
		assert.match(text, /\$CLOUDFLARE_API_TOKEN/);
		assert.match(text, /stop after 10 minutes/);
		// Dev servers stay on the loopback: the app reaches them through ssh, and 0.0.0.0 would publish them.
		assert.match(text, /--host 127\.0\.0\.1/);
		assert.match(text, /0\.0\.0\.0 would put/);
		// Unattended runs are refused risky actions (guard.ts deny_risky).
		assert.match(text, /risky commands are refused outright/);
	}
	assert.match(inBox, /inside an Ubuntu container as root/);
	assert.match(inBox, /apt-get install -y/);
	assert.match(bare, /directly on the server as an unprivileged user/);
	assert.doesNotMatch(bare, /Ubuntu container/);
});

test("the file is ours to rewrite while it carries the marker; without it, it is the user's", () => {
	for (const mode of ["phone", "server"]) {
		const ours = agentsFileText({ mode, workspace: "/w" });
		assert.equal(isManaged(ours), true);
		// Deleting the marker line, as the line itself says, keeps the user's edits (the old start-of-file check did not).
		assert.equal(isManaged(ours.replace(`${AGENTS_MARKER}\n`, "")), false, mode);
	}
	assert.equal(isManaged("# My own notes\n\nUse tabs."), false);
});
