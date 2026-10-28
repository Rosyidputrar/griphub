// The server's rootless container as the host sees it (podmanbox.ts), driving the real launcher server/box/box with a
// stand-in podman. Ported from CoderRa's agent/test/podmanbox.test.ts (types stripped); the cases through the real
// host are in host-process.test.mjs.
import assert from "node:assert/strict";
import { chmodSync, existsSync, mkdirSync, readdirSync, readFileSync, statSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import { bundle, tempDir } from "./helpers.mjs";

const { defaultExec, PodmanBox } = await bundle("podmanbox");

// The host's view of the Podman box. Podman is a stand-in script that keeps its state in files and answers the way podman
// does for the few commands used; the launcher is the real server/box/box. What podman really prints is NOT verified here
// (there is none on the test machine): these tests check that the host asks the right questions and does the right thing
// with the answers it is given.

const ORIGINAL_ENV = Object.fromEntries(
	["PATH", "HOME", "GRIPHUB_WORKSPACE", "STUB_DIR", "GRIPHUB_DIR", "GRIPHUB_BOX_HOME", "GRIPHUB_BOX_CONF", "STUB_EXEC_EXIT", "STUB_BUILD_EXIT", "STUB_BUILD_DELAY", "STUB_USAGE_FAIL"].map((k) => [k, process.env[k]]),
);

const BOX = fileURLToPath(new URL("../../server/box/box", import.meta.url));

const PODMAN = `#!/bin/bash
dir="$STUB_DIR"
cmd="$1"; shift
line="$cmd"; for a in "$@"; do line="$line"$'\\t'"$a"; done
printf '%s\\n' "$line" >> "$dir/calls.log"
case "$cmd" in
  --version) echo "podman version 4.9.3" ;;
  image) [ -f "$dir/image" ] ;;
  container)
    [ -f "$dir/state" ] || { echo "Error: no such container griphub-box" >&2; exit 125; }
    s=$(cat "$dir/state")
    case "$*" in *"|"*) echo "$s|2026-10-18T09:00:00.123456Z" ;; *) echo "$s" ;; esac ;;
  exec)
    case "$*" in
      *box-works*) [ "\${STUB_EXEC_EXIT:-0}" = 0 ] || { echo "Error: crun: cannot start" >&2; exit "$STUB_EXEC_EXIT"; }; echo box-works ;;
      *memory.current*) [ -n "\${STUB_USAGE_FAIL:-}" ] && exit 1; cat "$dir/usage" 2>/dev/null ;;
    esac ;;
  stop)
    if [ -f "$dir/state" ]; then echo exited > "$dir/state"; else echo "Error: no container with name or ID \\"griphub-box\\" found: no such container" >&2; exit 125; fi ;;
  rm) rm -f "$dir/state" ;;
  run) echo running > "$dir/state"; echo id ;;
  start) echo running > "$dir/state" ;;
  build)
    echo "STEP 1/3: FROM ubuntu"; echo "STEP 2/3: RUN apt-get install"; sleep "\${STUB_BUILD_DELAY:-0}"
    [ "\${STUB_BUILD_EXIT:-0}" = 0 ] || { echo "Error: building at STEP 2/3" >&2; exit "$STUB_BUILD_EXIT"; }
    touch "$dir/image"; echo "Successfully tagged localhost/griphub-box" ;;
  unshare) chmod -R u+rwx "\${@: -1}"; rm -rf "\${@: -1}" ;;
esac
`;

function rig(t, o = {}) {
	const home = tempDir(t);
	const bin = join(home, "bin");
	const stub = join(home, "stub");
	mkdirSync(bin);
	mkdirSync(stub);
	writeFileSync(join(bin, "podman"), PODMAN);
	chmodSync(join(bin, "podman"), 0o755);
	if (o.image !== false) writeFileSync(join(stub, "image"), "");
	if (o.state) writeFileSync(join(stub, "state"), `${o.state}\n`);
	if (o.usage !== undefined) writeFileSync(join(stub, "usage"), o.usage);
	const griphubDir = join(home, ".griphub");
	mkdirSync(join(griphubDir, "box"), { recursive: true });
	if (o.containerfile !== false) writeFileSync(join(griphubDir, "box", "Containerfile"), "FROM ubuntu\n");
	mkdirSync(join(home, "workspace"), { recursive: true });
	const env = { PATH: `${bin}:${process.env.PATH}`, HOME: home, GRIPHUB_WORKSPACE: join(home, "workspace"), STUB_DIR: stub, GRIPHUB_DIR: griphubDir };
	for (const k of Object.keys(env)) process.env[k] = (env)[k];
	delete process.env.GRIPHUB_BOX_HOME;
	delete process.env.GRIPHUB_BOX_CONF;
	// Child processes inherit the environment, so it is put back as it was when the file was loaded (a test may make
	// several rigs, and each would otherwise "restore" what the one before it set).
	t.after(() => {
		for (const [k, v] of Object.entries(ORIGINAL_ENV)) {
			if (v === undefined) delete process.env[k];
			else process.env[k] = v;
		}
	});
	const script = o.script === false ? join(home, "no-such-box") : BOX;
	const box = new PodmanBox({ script, griphubDir, exec: (f, a, x) => defaultExec(f, a, { timeoutMs: Math.min(x?.timeoutMs ?? 5000, 5000) }), checkTimeoutMs: 5000 });
	const calls = () => (existsSync(join(stub, "calls.log")) ? readFileSync(join(stub, "calls.log"), "utf8").trim().split("\n").map((l) => l.split("\t")) : []);
	return { home, stub, griphubDir, box, calls, script, env };
}

test("with no launcher there is no box, and podman is not even asked", async (t) => {
	const r = rig(t, { script: false });
	const s = await r.box.status(undefined);
	assert.deepEqual([s.kind, s.available, s.installed, s.state, s.enabled], ["podman", false, false, "none", false]);
	assert.match(s.problem , /no box on this server/i);
	assert.deepEqual(r.calls(), []);
	await assert.rejects(() => r.box.reset(), (e) => e.code === "no_box");
	await assert.rejects(() => r.box.stop(), (e) => e.code === "no_box");
	await assert.rejects(() => r.box.wipeHome(), (e) => e.code === "no_box");
	assert.deepEqual(await r.box.check(), { ok: false, message: "There is no box on this server." });
});

test("podman that is not there is a problem to read, not a crash", async (t) => {
	const r = rig(t);
	const box = new PodmanBox({ script: BOX, griphubDir: r.griphubDir, podman: join(r.home, "nowhere", "podman") });
	const s = await box.status(undefined);
	assert.deepEqual([s.available, s.state], [true, "unknown"]);
	assert.match(s.problem , /Podman is not installed/);
});

test("before anything has been built: no image, no container, and it says what to do", async (t) => {
	const r = rig(t, { image: false });
	const s = await r.box.status(undefined);
	assert.deepEqual([s.available, s.installed, s.state, s.usage], [true, false, "none", null]);
	assert.match(s.problem , /image has not been built/);
});

test("an image but no container yet is the normal state before the first command", async (t) => {
	const r = rig(t);
	const s = await r.box.status(undefined);
	assert.deepEqual([s.installed, s.state, s.problem, s.distro], [true, "none", null, "ubuntu"]);
});

test("a running box: when it started, what it uses, whether the agent's commands go through it", async (t) => {
	const r = rig(t, { state: "running", usage: "123456789\n2147483648\n7\n" });
	const s = await r.box.status(r.script);
	assert.deepEqual([s.state, s.enabled, s.startedAt], ["running", true, "2026-10-18T09:00:00.123456Z"]);
	assert.deepEqual(s.usage, { memoryBytes: 123456789, memoryLimitBytes: 2147483648, processes: 7 });
	assert.deepEqual(s.limits, { memory: "2g", swap: "3g", cpus: "1.5" });
	assert.equal((await r.box.status(undefined)).enabled, false, "the agent's commands run directly on the server");
	assert.equal((await r.box.status("/bin/bash")).enabled, false);
});

test("a stopped box is not asked about its usage", async (t) => {
	const r = rig(t, { state: "exited", usage: "1\n2\n3\n" });
	const s = await r.box.status(undefined);
	assert.deepEqual([s.state, s.usage, s.startedAt], ["stopped", null, null]);
	assert.ok(!r.calls().some((c) => c[0] === "exec"));
});

test("usage that cannot be read is absent, not wrong", async (t) => {
	const cases = [
		["500\nmax\n4\n", null], // no memory limit
		["", "absent"], // cgroup v1: nothing to read
		["abc\n100\n3\n", "absent"],
		["5\n100\n", "absent"],
	];
	for (const [usage, limit] of cases) {
		const r = rig(t, { state: "running", usage });
		const u = (await r.box.status(undefined)).usage;
		if (limit === "absent") assert.equal(u, null, JSON.stringify(usage));
		else assert.deepEqual(u, { memoryBytes: 500, memoryLimitBytes: limit, processes: 4 });
	}
	process.env.STUB_USAGE_FAIL = "1";
	t.after(() => void delete process.env.STUB_USAGE_FAIL);
	assert.equal((await rig(t, { state: "running", usage: "1\n2\n3\n" }).box.status(undefined)).usage, null);
});

test("limits come from box.conf, as the launcher reads them, and junk is ignored", async (t) => {
	const r = rig(t);
	writeFileSync(
		join(r.griphubDir, "box.conf"),
		['# limits', 'BOX_MEMORY=3g', "BOX_SWAP='4G'  # more", 'BOX_CPUS="0.5"', "BOX_EXTRA=ignored"].join("\n"),
	);
	assert.deepEqual(r.box.limits(), { memory: "3g", swap: "4G", cpus: "0.5" });
	writeFileSync(join(r.griphubDir, "box.conf"), "BOX_MEMORY=$(rm -rf /)\nBOX_CPUS=lots\nBOX_SWAP=\n");
	assert.deepEqual(r.box.limits(), { memory: "2g", swap: "3g", cpus: "1.5" }, "only plain numbers are believed");
});

test("a podman that does not answer is reported as such", async (t) => {
	const r = rig(t, { state: "running" });
	writeFileSync(join(r.home, "bin", "podman"), "#!/bin/bash\nsleep 5\n");
	const box = new PodmanBox({ script: BOX, griphubDir: r.griphubDir, exec: (f, a) => defaultExec(f, a, { timeoutMs: 300 }) });
	const s = await box.status(undefined);
	assert.equal(s.state, "unknown");
	assert.ok(s.problem);
});

test("check runs a command through the launcher: yes, with the reason when not", async (t) => {
	const ok = rig(t);
	assert.deepEqual(await ok.box.check(), { ok: true, message: "The box works: a command ran inside it." });
	assert.ok(ok.calls().some((c) => c[0] === "run"), "the first use made the container");

	process.env.STUB_EXEC_EXIT = "126";
	t.after(() => void delete process.env.STUB_EXEC_EXIT);
	const bad = rig(t, { state: "running" });
	const r = await bad.box.check();
	assert.equal(r.ok, false);
	assert.match(r.message, /crun: cannot start/);
});

test("resetting throws the container away and keeps the image and the home folder", async (t) => {
	const r = rig(t, { state: "running" });
	mkdirSync(join(r.griphubDir, "box-home"));
	writeFileSync(join(r.griphubDir, "box-home", "keep.txt"), "mine");
	await r.box.reset();
	assert.equal(existsSync(join(r.stub, "state")), false);
	assert.equal(existsSync(join(r.stub, "image")), true);
	assert.equal(readFileSync(join(r.griphubDir, "box-home", "keep.txt"), "utf8"), "mine");
	assert.equal((await r.box.status(undefined)).state, "none");
});

test("stopping: a running box stops, one that is not there is already stopped", async (t) => {
	const r = rig(t, { state: "running" });
	await r.box.stop();
	assert.equal((await r.box.status(undefined)).state, "stopped");
	const none = rig(t);
	await none.box.stop();
});

test("rebuilding the image shows what podman says, then drops the old container so the new image is used", async (t) => {
	const r = rig(t, { state: "running", image: false });
	const lines = [];
	const log = Object.assign((l) => void lines.push(l), {});
	await r.box.rebuildImage(log);
	assert.ok(lines.some((l) => /STEP 1\/3/.test(l)));
	assert.equal(existsSync(join(r.stub, "image")), true);
	assert.equal(existsSync(join(r.stub, "state")), false, "the container made from the old image is gone");
	const build = r.calls().find((c) => c[0] === "build") ;
	assert.deepEqual(build.slice(1, 3), ["-t", "localhost/griphub-box"]);
	assert.ok(build.includes(join(r.griphubDir, "box", "Containerfile")));
});

test("a build that fails keeps the old container, and says why", async (t) => {
	process.env.STUB_BUILD_EXIT = "1";
	t.after(() => void delete process.env.STUB_BUILD_EXIT);
	const r = rig(t, { state: "running" });
	await assert.rejects(() => r.box.rebuildImage(() => {}), /podman exited with 1[\s\S]*building at STEP 2\/3/);
	assert.equal(existsSync(join(r.stub, "state")), true, "what worked before still does");
});

test("no Containerfile: it says to run the setup script again", async (t) => {
	const r = rig(t, { containerfile: false });
	await assert.rejects(() => r.box.rebuildImage(() => {}), /Containerfile is missing/);
});

test("two changes at once are not allowed to fight over the container", async (t) => {
	process.env.STUB_BUILD_DELAY = "0.5";
	t.after(() => void delete process.env.STUB_BUILD_DELAY);
	const r = rig(t, { state: "running" });
	const building = r.box.rebuildImage(() => {});
	await new Promise((x) => setTimeout(x, 100));
	await assert.rejects(() => r.box.reset(), (e) => e.code === "busy" && /rebuilding the image/.test(e.message));
	await assert.rejects(() => r.box.wipeHome(), (e) => e.code === "busy");
	await building;
	await r.box.reset(); // free again
});

test("wiping the home empties it, keeps the folder private, and leaves the workspace alone", async (t) => {
	const r = rig(t, { state: "running" });
	const bh = join(r.griphubDir, "box-home");
	mkdirSync(join(bh, ".ssh"), { recursive: true });
	writeFileSync(join(bh, ".ssh", "known_hosts"), "x");
	writeFileSync(join(bh, ".bash_history"), "ls");
	writeFileSync(join(r.home, "workspace", "project.txt"), "safe");
	const res = await r.box.wipeHome();
	assert.equal(res.removed, 2);
	assert.deepEqual(readdirSync(bh), []);
	assert.equal(statSync(bh).mode & 0o777, 0o700);
	assert.equal(readFileSync(join(r.home, "workspace", "project.txt"), "utf8"), "safe");
	assert.equal(existsSync(join(r.stub, "state")), false, "the container was removed first");
});

test("files the outside user cannot delete are removed through podman's own user namespace", async (t) => {
	const r = rig(t, { state: "running" });
	const bh = join(r.griphubDir, "box-home");
	mkdirSync(join(bh, "locked"), { recursive: true });
	writeFileSync(join(bh, "locked", "owned-by-another-uid"), "x");
	chmodSync(join(bh, "locked"), 0o000);
	t.after(() => {
		try {
			chmodSync(join(bh, "locked"), 0o755);
		} catch {
			// already removed
		}
	});
	if (process.getuid?.() === 0) return t.skip("root can delete anything");
	const res = await r.box.wipeHome();
	assert.equal(res.removed, 1);
	assert.deepEqual(readdirSync(bh), []);
	assert.ok(r.calls().some((c) => c[0] === "unshare"));
});

test("a setting that points the home folder somewhere surprising is not obeyed", async (t) => {
	const r = rig(t, { state: "running" });
	for (const bad of ["/", r.home, join(r.home, "workspace"), "/etc"]) {
		process.env.GRIPHUB_BOX_HOME = bad;
		await assert.rejects(() => r.box.wipeHome(), (e) => e.code === "unsafe", bad);
	}
	assert.equal(existsSync(join(r.home, "workspace")), true);
	assert.equal(existsSync(join(r.stub, "state")), true, "and the container was not touched either");
});
