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
const { findFiles, fileScore, gitignoreTest } = await import(pathToFileURL(outfile).href);

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

/** Runs [fn] as on a machine without ripgrep (some phones, the CI runner). */
async function withoutRipgrep(fn) {
	const path = process.env.PATH;
	process.env.PATH = "";
	try {
		return await fn();
	} finally {
		process.env.PATH = path;
	}
}

test("without ripgrep, a plain walk finds the same files and leaves out the same ones", async () => {
	const cwd = project();
	await withoutRipgrep(async () => {
		assert.deepEqual((await findFiles(cwd, "screen")).files, ["lib/ui/chat_screen.dart"]);
		const { files } = await findFiles(cwd, "chat");
		assert.equal(files[0], "lib/agent/chat.dart");
		assert.ok(!files.includes("secret/chat.txt"), ".gitignore, which ripgrep reads by itself");
		assert.ok(!files.some((f) => f.startsWith("node_modules/") || f.startsWith("build/")));
	});
});

test(".gitignore for the walk: names anywhere, paths from the top, folders only, wildcards", () => {
	const dir = mkdtempSync(join(tmpdir(), "gitignore-"));
	writeFileSync(join(dir, ".gitignore"), ["# a comment", "", "*.log", "/dist", "tmp/", "docs/private", "**/cache/**", "!keep.log", "secret.txt"].join("\n"));
	const ignored = gitignoreTest(dir);
	assert.equal(ignored("app.log", false), true);
	assert.equal(ignored("src/deep/app.log", false), true, "a name matches in any folder");
	assert.equal(ignored("dist", true), true);
	assert.equal(ignored("src/dist", true), false, "/dist is the top's only");
	assert.equal(ignored("tmp", true), true);
	assert.equal(ignored("tmp", false), false, "tmp/ is a folder, not a file called tmp");
	assert.equal(ignored("docs/private", true), true);
	assert.equal(ignored("a/b/cache/x.bin", false), true);
	assert.equal(ignored("secret.txt", false), true);
	assert.equal(ignored("src/main.ts", false), false);
	assert.equal(ignored("keep.log", false), true, "a negation is not followed: the walk shows less than git, never something ignored");
	assert.equal(gitignoreTest(mkdtempSync(join(tmpdir(), "none-")))("anything", false), false, "no .gitignore");
});
