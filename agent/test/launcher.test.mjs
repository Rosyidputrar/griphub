// The launcher files that the app's update cannot copy (they live outside the host's folder) and the host puts in place
// at start (launcher.ts). Also that the bundle carries exactly the files bootstrap.sh installs there.
import assert from "node:assert/strict";
import { chmodSync, existsSync, mkdirSync, readFileSync, readdirSync, statSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import { bundle, tempDir } from "./helpers.mjs";

const { LAUNCHER_FILES, syncLauncher } = await bundle("launcher");
const SERVER = join(dirname(fileURLToPath(import.meta.url)), "..", "..", "server");

function put(path, text, mode = 0o644) {
	mkdirSync(dirname(path), { recursive: true });
	writeFileSync(path, text);
	chmodSync(path, mode);
}

/** A bundle folder with a launcher/ in it and a server whose files were put there by an older setup. */
function rig(t, { installed = ["box", "griphub-attach", "Containerfile"] } = {}) {
	const root = tempDir(t);
	const hostDir = join(root, "host");
	const griphubDir = join(root, ".griphub");
	for (const f of LAUNCHER_FILES) put(join(hostDir, "launcher", f.name), `new ${f.name}\n`);
	for (const f of LAUNCHER_FILES) if (installed.includes(f.name)) put(join(griphubDir, f.target), `old ${f.name}\n`, 0o600);
	return { hostDir, griphubDir };
}

test("files that differ are replaced, with the mode bootstrap.sh gives them", (t) => {
	const { hostDir, griphubDir } = rig(t);
	const replaced = syncLauncher({ hostDir, griphubDir });
	assert.deepEqual(replaced.sort(), LAUNCHER_FILES.map((f) => f.target).sort());
	for (const f of LAUNCHER_FILES) {
		const path = join(griphubDir, f.target);
		assert.equal(readFileSync(path, "utf8"), `new ${f.name}\n`);
		assert.equal(statSync(path).mode & 0o777, f.mode, f.target);
	}
});

test("files that are already current are left alone, and no temporary file stays behind", (t) => {
	const { hostDir, griphubDir } = rig(t);
	syncLauncher({ hostDir, griphubDir });
	assert.deepEqual(syncLauncher({ hostDir, griphubDir }), []);
	for (const dir of ["bin", "box"]) assert.ok(!readdirSync(join(griphubDir, dir)).some((n) => n.includes(".new-")), dir);
});

test("a file the server does not have is not created: no box.sh means a server set up with --no-box", (t) => {
	const { hostDir, griphubDir } = rig(t, { installed: ["griphub-attach"] });
	assert.deepEqual(syncLauncher({ hostDir, griphubDir }), [join("bin", "griphub-attach")]);
	assert.ok(!existsSync(join(griphubDir, "bin", "box")), "the agent's commands must not be switched to a box nobody set up");
	assert.ok(!existsSync(join(griphubDir, "box", "Containerfile")));
});

test("a bundle without launcher/ (an older app) changes nothing", (t) => {
	const { griphubDir } = rig(t);
	const empty = tempDir(t);
	assert.deepEqual(syncLauncher({ hostDir: empty, griphubDir }), []);
	assert.equal(readFileSync(join(griphubDir, "bin", "box"), "utf8"), "old box\n");
});

test("a file that cannot be written is reported and the others still go in", (t) => {
	if (process.getuid?.() === 0) return t.skip("root writes anywhere, so the case cannot be made");
	const { hostDir, griphubDir } = rig(t);
	const warnings = [];
	let replaced;
	chmodSync(join(griphubDir, "box"), 0o555); // Containerfile's folder: the new file cannot be made beside it
	try {
		replaced = syncLauncher({ hostDir, griphubDir, warn: (m) => warnings.push(m) });
	} finally {
		chmodSync(join(griphubDir, "box"), 0o755); // before the temporary folder is removed
	}
	assert.deepEqual(replaced.sort(), [join("bin", "box"), join("bin", "griphub-attach")].sort());
	assert.equal(warnings.length, 1);
	assert.match(warnings[0], /Containerfile/);
	assert.equal(readFileSync(join(griphubDir, "box", "Containerfile"), "utf8"), "old Containerfile\n");
});

test("what the host syncs is what bootstrap.sh installs, from the same server/ files", () => {
	const bootstrap = readFileSync(join(SERVER, "bootstrap.sh"), "utf8");
	const installs = [...bootstrap.matchAll(/install -o "\$USER_NAME" -g "\$USER_NAME" -m (\d+) "\$HERE\/([\w/.-]+)" "\$(?:GRIPHUB_DIR)\/([\w/.-]+)"/g)];
	assert.ok(installs.length >= 3, "found the install lines in bootstrap.sh");
	for (const f of LAUNCHER_FILES) {
		const line = installs.find((m) => m[3] === f.target.split("\\").join("/"));
		assert.ok(line, `${f.target} is installed by bootstrap.sh`);
		assert.equal(parseInt(line[1], 8), f.mode, `${f.target}: same mode as bootstrap.sh`);
		assert.ok(existsSync(join(SERVER, line[2])), `${line[2]} exists in server/`);
	}
});
