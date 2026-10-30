// The composer's @ list: the project's files by name, best match first, without dependencies or what .gitignore keeps
// out, from ripgrep or (without it) a plain walk.
import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { build } from "esbuild";

const here = dirname(fileURLToPath(import.meta.url));
mkdirSync(join(here, "..", "build"), { recursive: true });
const out = mkdtempSync(join(here, "..", "build", "files-find-test-"));
const outfile = join(out, "workbench.mjs");
await build({ entryPoints: [join(here, "..", "src", "workbench.ts")], outfile, bundle: true, platform: "node", format: "esm", packages: "external", logLevel: "error" });
const { findFiles, fileScore } = await import(pathToFileURL(outfile).href);

function project() {
	const dir = mkdtempSync(join(tmpdir(), "files-find-"));
	const files = {
		"lib/ui/chat_screen.dart": "",
		"lib/ui/chat_extras.dart": "",
		"lib/agent/chat.dart": "",
		"README.md": "",
		"node_modules/chat/index.js": "",
		"build/chat_screen.dart": "",
		".gitignore": "secret/\n",
		"secret/chat.txt": "",
	};
	for (const [name, text] of Object.entries(files)) {
		mkdirSync(join(dir, dirname(name)), { recursive: true });
		writeFileSync(join(dir, name), text);
	}
	return dir;
}

test("the file's name beats a folder, which beats letters in order; shorter paths win ties", () => {
	assert.ok(fileScore("lib/ui/chat_screen.dart", "chat_s") > fileScore("lib/chat_s/x.dart", "chat_s"));
	assert.ok(fileScore("lib/ui/chat_screen.dart", "chscr") >= 0, "letters in order");
	assert.equal(fileScore("lib/ui/chat_screen.dart", "zzz"), -1);
	assert.ok(fileScore("a/chat.dart", "chat") > fileScore("a/b/c/chat.dart", "chat"));
});

test("best match first, with dependencies, build output and what .gitignore keeps out left off", async () => {
	const cwd = project();
	const { files } = await findFiles(cwd, "chat");
	assert.equal(files[0], "lib/agent/chat.dart", "the name starts with it, and it's the shortest such path");
	assert.ok(files.includes("lib/ui/chat_screen.dart"));
	assert.ok(!files.some((f) => f.startsWith("node_modules/") || f.startsWith("build/")));
	assert.ok(!files.includes("secret/chat.txt"), ".gitignore");
	const all = await findFiles(cwd, "");
	assert.ok(all.files.includes("README.md"), "nothing typed yet: everything, shortest first");
	assert.equal((await findFiles(cwd, "chat", 2)).files.length, 2);
});

test("without ripgrep, a plain walk still finds the files", async () => {
	const cwd = project();
	const path = process.env.PATH;
	process.env.PATH = "";
	try {
		const { files } = await findFiles(cwd, "screen");
		assert.deepEqual(files, ["lib/ui/chat_screen.dart"]);
	} finally {
		process.env.PATH = path;
	}
});
