// Which file writes ask first (guard.ts riskOf). The check used to read a path its own way and pi's `write` and `edit`
// read it another: a leading `@` (pi drops it), a `file://` address (pi turns it into a path) and a link inside the
// project that leads out all looked "inside the project" to the check and were the real file to the tool. These tests
// compare the check with pi's own path resolver, and the table below is what must ask and what must not.
import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, realpathSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { bundle } from "./helpers.mjs";

const here = dirname(fileURLToPath(import.meta.url));
const { riskOf, resolveLikePi } = await bundle("guard");
// pi does not export its resolver (only its package entry), so it is loaded from its file.
const { resolveToCwd } = await import(
	pathToFileURL(join(here, "..", "node_modules", "@earendil-works", "pi-coding-agent", "dist", "core", "tools", "path-utils.js")).href
);

const ASKS = "Writes outside the project folder";
const realHome = process.env.HOME;
let root, project, outside, home, projectLink;

before(() => {
	root = realpathSync(mkdtempSync(join(tmpdir(), "gh-guard-")));
	project = join(root, "proj");
	outside = join(root, "elsewhere");
	home = join(root, "home");
	for (const d of [project, join(project, "src"), join(project, "sub"), outside, home]) mkdirSync(d, { recursive: true });
	writeFileSync(join(outside, "secret"), "x");
	symlinkSync(outside, join(project, "out")); // a link that leads out
	symlinkSync(join(outside, "not-yet"), join(project, "dangling")); // leads out, to something that does not exist yet
	symlinkSync(join(project, "sub"), join(project, "inside-link")); // leads somewhere inside
	symlinkSync(join(project, "inside-link"), join(project, "chain")); // a link to a link, still inside
	symlinkSync(join(project, "loop-b"), join(project, "loop-a"));
	symlinkSync(join(project, "loop-a"), join(project, "loop-b")); // a loop: cannot be told, so it asks
	mkdirSync(join(project, "deep"));
	symlinkSync(join(project, "sub"), join(project, "deep", "via")); // deep/via is the folder sub, by a longer name
	symlinkSync("../../not-yet-outside", join(project, "sub", "rel-dangling")); // from sub: two levels up is outside
	projectLink = join(root, "proj-link");
	symlinkSync(project, projectLink); // the project itself reached through a link
	process.env.HOME = home;
});

after(() => {
	process.env.HOME = realHome;
	rmSync(root, { recursive: true, force: true });
});

const ask = (tool, path, cwd = project) => riskOf(tool, { path }, cwd);

test("inside the project nothing asks, however the path is written", () => {
	for (const p of [
		"src/a.ts",
		"./src/../src/a.ts",
		"new/deeper/file.txt", // folders that do not exist yet
		"@src/a.ts", // pi drops the @
		join(project, "src", "a.ts"),
		"inside-link/f", // a link that stays inside
		"chain/f",
		"@@/x", // pi drops one @ only: this is a folder called "@" in the project
		"",
		".",
	]) {
		assert.equal(ask("write", p), null, `write ${JSON.stringify(p)}`);
		assert.equal(ask("edit", p), null, `edit ${JSON.stringify(p)}`);
	}
	assert.equal(riskOf("write", {}, project), null, "no path at all: the tool reports that itself");
});

test("a leading @ no longer hides where a file is written", () => {
	for (const p of [
		`@${join(outside, "f")}`,
		`@${outside}`,
		"@~/.bashrc",
		"@~",
		"@../x",
		"@../../.bashrc",
		"@/etc/passwd",
		"@/home/griphub/.ssh/authorized_keys",
	]) {
		assert.equal(ask("write", p), ASKS, `write ${p}`);
		assert.equal(ask("edit", p), ASKS, `edit ${p}`);
	}
});

test("outside the project asks: absolute, home, parent folders, and a folder that only starts with the project's name", () => {
	for (const p of [join(outside, "f"), outside, "~/x", "~", "../x", "../../x", "/etc/passwd", `${project}-evil/f`, root]) {
		assert.equal(ask("write", p), ASKS, JSON.stringify(p));
	}
});

test("a file:// address is the path it names, as in pi, not a folder called file:", () => {
	assert.equal(ask("write", pathToFileURL(join(outside, "f")).href), ASKS);
	assert.equal(ask("write", pathToFileURL(join(project, "src", "a.ts")).href), null);
	assert.equal(ask("write", "file://remote-host/x"), ASKS, "an address pi refuses is not waved through");
});

test("unusual spaces count as spaces, as in pi: a name that starts with one is a name inside the project", () => {
	assert.equal(ask("write", " x"), null);
	assert.equal(ask("write", " /etc/passwd"), null, "relative: a folder called ' ' in the project");
});

test("a link inside the project that leads out asks, whether or not what it points at exists", () => {
	assert.equal(ask("write", "out/f"), ASKS);
	assert.equal(ask("write", "out"), ASKS);
	assert.equal(ask("edit", "out/secret"), ASKS);
	assert.equal(ask("write", "dangling"), ASKS, "writing through it would create the file where it points");
	assert.equal(ask("write", "dangling/sub/x"), ASKS);
	assert.equal(ask("write", "loop-a/x"), ASKS, "a loop of links cannot be followed: it asks");
	// A relative link that leads nowhere is read from the folder it is in, not from the name it was reached by: `..` from
	// deep/via/ is sub's parent (the project), but from sub itself, where the link lives, two levels up is outside.
	assert.equal(ask("write", "sub/rel-dangling"), ASKS);
	assert.equal(ask("write", "deep/via/rel-dangling"), ASKS, "the same link, reached through a longer way round");
});

test("the project reached through a link is the same project", () => {
	assert.equal(riskOf("write", { path: "a.txt" }, projectLink), null);
	assert.equal(riskOf("write", { path: join(project, "a.txt") }, projectLink), null);
	assert.equal(riskOf("write", { path: join(projectLink, "a.txt") }, project), null);
	assert.equal(riskOf("write", { path: join(outside, "a.txt") }, projectLink), ASKS);
	assert.equal(riskOf("write", { path: "out/a.txt" }, projectLink), ASKS);
});

test("it agrees with pi about where a file lands, for a table of awkward paths", () => {
	const paths = [
		"a.txt", "./a.txt", "../a.txt", "@a.txt", "@@a.txt", "@/etc/x", "@~/x", "~/x", "~", "@~", "~x", "@ ~/x",
		" a", " /etc/x", "@ ~/x", "/abs/x", `@${outside}/x`, "file:///tmp/x", "@file:///tmp/x", " @x", "a/../../b",
	];
	for (const p of paths) {
		assert.equal(resolveLikePi(p, project), resolveToCwd(p, project), `resolve ${JSON.stringify(p)}`);
	}
	// What pi would write is what the check judges: it asks exactly when that file is outside the project.
	for (const p of paths) {
		const lands = resolveToCwd(p, project);
		const outsideProject = lands !== project && !lands.startsWith(project + "/");
		assert.equal(ask("write", p) === ASKS, outsideProject, `write ${JSON.stringify(p)} lands at ${lands}`);
	}
});

test("a write into a .git folder asks, however it is reached: git runs what is written there", () => {
	const GIT = "Writes inside a .git folder: git runs what is written there";
	symlinkSync(join(project, ".git"), join(project, "git-link")); // a link inside the project to its own .git
	mkdirSync(join(project, ".git", "hooks"), { recursive: true });
	mkdirSync(join(project, "sub", ".git"), { recursive: true }); // a repository nested in the project
	for (const p of [".git/config", ".git/hooks/pre-commit", "@.git/config", "sub/.git/config", "src/../.git/config", join(project, ".git", "config"), "git-link/config", ".git"]) {
		assert.equal(ask("write", p), GIT, `write ${p}`);
		assert.equal(ask("edit", p), GIT, `edit ${p}`);
	}
	// Names that only look like it do not ask.
	for (const p of [".gitignore", ".gitattributes", ".github/workflows/ci.yml", "a.git/x", "src/git/x", "src/.gitkeep"]) assert.equal(ask("write", p), null, `write ${p}`);
	// Outside the project is still the first thing said.
	assert.equal(ask("write", join(outside, ".git", "config")), ASKS);
});

test("other tools and the other modes are as they were", () => {
	assert.equal(riskOf("read", { path: "/etc/passwd" }, project), null, "reading is not this check's business");
	assert.equal(riskOf("bash", { command: "ls" }, project), null);
	assert.match(riskOf("bash", { command: "rm -rf x" }, project), /delete data/);
	assert.equal(riskOf("mcp_x", {}, project), "External tool from an MCP server");
	assert.equal(riskOf("mcp_x", {}, project, false), null, "an unattended run may use the servers the user set up");
});
