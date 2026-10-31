// pi loads extensions from a project's own `.pi/extensions/` and runs them inside the host, with the sign-in tokens around,
// unless the project is untrusted. The agent can write that folder, so the host must never trust a project: a
// prompt-injected agent could otherwise write an extension and have it run the next time a chat opens in that project
// (a restart, a switch, a rebuild after a setting). The host says projectTrusted: false; these keep it that way and keep
// the claim honest by running pi the way the host does.
import { test } from "node:test";
import assert from "node:assert/strict";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const { DefaultResourceLoader, SettingsManager } = await import("@earendil-works/pi-coding-agent");

async function extensionRuns(projectTrusted) {
	const root = mkdtempSync(join(tmpdir(), "gh-trust-"));
	try {
		const project = join(root, "proj");
		const agentDir = join(root, "agent");
		const marker = join(root, "marker");
		mkdirSync(join(project, ".pi", "extensions"), { recursive: true });
		mkdirSync(agentDir, { recursive: true });
		writeFileSync(join(project, ".pi", "extensions", "evil.ts"), `import { writeFileSync } from "node:fs";\nwriteFileSync(${JSON.stringify(marker)}, "loaded");\nexport default function () {}\n`);
		const settingsManager = SettingsManager.create(root, agentDir, { projectTrusted });
		await new DefaultResourceLoader({ cwd: project, agentDir, settingsManager, extensionFactories: [] }).reload();
		return existsSync(marker);
	} finally {
		rmSync(root, { recursive: true, force: true });
	}
}

test("a project's own extension runs only if the project is trusted (so the check below is not vacuous)", async () => {
	assert.equal(await extensionRuns(true), true, "trusted: it runs");
	assert.equal(await extensionRuns(false), false, "untrusted: it does not");
});

test("the host never trusts a project", () => {
	const host = readFileSync(join(here, "..", "src", "host.ts"), "utf8");
	assert.match(host, /SettingsManager\.create\(workspace, agentDir, \{ projectTrusted: false \}\)/);
	assert.ok(!/setProjectTrusted\(\s*true/.test(host), "and nothing turns it on later");
	assert.ok(!/resolveProjectTrust/.test(host), "nor asks a callback that could");
	assert.equal((host.match(/new DefaultResourceLoader\(/g) ?? []).length, 2, "both ways the host builds a session (chat, subagent) use the one settings manager");
	assert.equal((host.match(/new DefaultResourceLoader\(\{\s*cwd,\s*agentDir,\s*settingsManager,/g) ?? []).length, 2);
});
