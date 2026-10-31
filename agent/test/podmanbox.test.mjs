// The server's rootless container as the host sees it (podmanbox.ts), driving the real launcher server/box/box with a
// stand-in podman. Ported from CoderRa's agent/test/podmanbox.test.ts (types stripped); the cases through the real
// host are in host-process.test.mjs.
import assert from "node:assert/strict";
import { chmodSync, existsSync, mkdirSync, readdirSync, readFileSync, statSync, writeFileSync } from "node:fs";
import { spawn, spawnSync } from "node:child_process";
import net from "node:net";
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
	["PATH", "HOME", "GRIPHUB_WORKSPACE", "STUB_DIR", "GRIPHUB_DIR", "GRIPHUB_BOX_HOME", "GRIPHUB_BOX_CONF", "STUB_EXEC_EXIT", "STUB_BUILD_EXIT", "STUB_BUILD_DELAY", "STUB_USAGE_FAIL", "STUB_HOLD", "STUB_EXEC_HANG", "STUB_PROBE_EXIT", "STUB_INSPECT_HANG", "STUB_START_HANG", "BOX_PROBE_SECS", "BOX_START_SECS", "BOX_ALIVE_SECS", "XDG_RUNTIME_DIR"].map((k) => [k, process.env[k]]),
);

const BOX = fileURLToPath(new URL("../../server/box/box", import.meta.url));

// systemd-run stand-in: records the call and runs the command after "--", as a scope would.
const SYSTEMD_RUN = `#!/bin/bash
echo "$*" >> "$STUB_DIR/systemd-run.log"
while [ "$1" != "--" ]; do shift; done
shift
exec "$@"
`;

const PODMAN = `#!/bin/bash
dir="$STUB_DIR"
cmd="$1"; shift
line="$cmd"; for a in "$@"; do line="$line"$'\\t'"$a"; done
printf '%s\\n' "$line" >> "$dir/calls.log"
case "$cmd" in
  --version) echo "podman version 4.9.3" ;;
  image) [ -f "$dir/image" ] ;;
  container)
    [ -n "\${STUB_INSPECT_HANG:-}" ] && exec sleep 30
    [ -f "$dir/state" ] || { echo "Error: no such container griphub-box" >&2; exit 125; }
    s=$(cat "$dir/state")
    case "$*" in *"|"*) echo "$s|2026-10-18T09:00:00.123456Z" ;; *) echo "$s" ;; esac ;;
  exec)
    [ -n "\${STUB_EXEC_HANG:-}" ] && exec sleep 30
    if [ -n "\${STUB_PROBE_EXIT:-}" ] && [ "$*" = "griphub-box true" ]; then echo "Error: crun: cannot start" >&2; exit "$STUB_PROBE_EXIT"; fi
    case "$*" in
      *box-works*) [ "\${STUB_EXEC_EXIT:-0}" = 0 ] || { echo "Error: crun: cannot start" >&2; exit "$STUB_EXEC_EXIT"; }; echo box-works ;;
      *memory.current*) [ -n "\${STUB_USAGE_FAIL:-}" ] && exit 1; cat "$dir/usage" 2>/dev/null ;;
    esac ;;
  stop)
    if [ -f "$dir/state" ]; then echo exited > "$dir/state"; else echo "Error: no container with name or ID \\"griphub-box\\" found: no such container" >&2; exit 125; fi ;;
  rm) rm -f "$dir/state" ;;
  run) echo running > "$dir/state"; echo id
    if [ -n "\${STUB_HOLD:-}" ]; then sleep 60 >/dev/null 2>&1 & echo $! >> "$dir/holders"; fi ;;
  start) [ -n "\${STUB_START_HANG:-}" ] && exec sleep 30
    echo running > "$dir/state"
    if [ -n "\${STUB_HOLD:-}" ]; then sleep 60 >/dev/null 2>&1 & echo $! >> "$dir/holders"; fi ;;
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
	// No user session bus here, so the launcher runs podman directly; a test that wants the bus makes one (see "scope").
	mkdirSync(join(home, "run"));
	const env = { PATH: `${bin}:${process.env.PATH}`, HOME: home, GRIPHUB_WORKSPACE: join(home, "workspace"), STUB_DIR: stub, GRIPHUB_DIR: griphubDir, XDG_RUNTIME_DIR: join(home, "run") };
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
	t.after(() => {
		const holders = join(stub, "holders");
		if (existsSync(holders)) for (const pid of readFileSync(holders, "utf8").split("\n").filter(Boolean)) spawnSync("kill", [pid]);
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

test("what podman leaves running does not keep the launcher's lock, so the next call is not stuck behind it", (t) => {
	const r = rig(t);
	process.env.STUB_HOLD = "1"; // podman run starts a process that lives on, as conmon does, and it inherits what is open
	const first = spawnSync(BOX, ["-c", "echo first"], { cwd: r.home, encoding: "utf8", env: process.env, timeout: 15_000 });
	assert.equal(first.status, 0, first.stderr);
	assert.ok(existsSync(join(r.stub, "holders")), "the stand-in for conmon is running");
	const lock = spawnSync("flock", ["-n", join(r.griphubDir, "box.lock"), "-c", "true"], { encoding: "utf8", timeout: 5000 });
	assert.equal(lock.status, 0, "the lock is free while the container lives on");
	// A stopped container is started again by podman start, which leaves a process behind in the same way.
	writeFileSync(join(r.stub, "state"), "exited\n");
	const second = spawnSync(BOX, ["-c", "echo second"], { cwd: r.home, encoding: "utf8", env: process.env, timeout: 15_000 });
	assert.equal(second.status, 0, second.stderr);
	const third = spawnSync(BOX, ["-c", "echo third"], { cwd: r.home, encoding: "utf8", env: process.env, timeout: 15_000 });
	assert.equal(third.status, 0, third.stderr);
});

test("a call that cannot get the lock in time says so and fails, instead of waiting for ever", (t) => {
	const r = rig(t, { state: "running" });
	const held = spawn("flock", [join(r.griphubDir, "box.lock"), "sleep", "30"], { stdio: "ignore" });
	t.after(() => held.kill());
	// flock needs a moment to take the lock before the launcher asks for it
	spawnSync("sleep", ["0.5"]);
	const fast = spawnSync("bash", ["-c", `sed 's/flock -w 60 9/flock -w 1 9/' "${BOX}" > "${r.home}/box-short" && chmod +x "${r.home}/box-short" && "${r.home}/box-short" -c true`], {
		cwd: r.home,
		encoding: "utf8",
		env: process.env,
		timeout: 20_000,
	});
	assert.equal(fast.status, 75, fast.stderr);
	assert.match(fast.stderr, /another box operation is still running/);
	assert.match(readFileSync(BOX, "utf8"), /flock -w 60 9/, "the real wait is 60 seconds (the test shortens a copy)");
});

test("the container is started in a scope of its own when there is a user session, so restarting the host does not stop it", async (t) => {
	const r = rig(t);
	writeFileSync(join(r.home, "bin", "systemd-run"), SYSTEMD_RUN);
	chmodSync(join(r.home, "bin", "systemd-run"), 0o755);
	const bus = net.createServer().listen(join(r.home, "run", "bus"));
	t.after(() => bus.close());
	await new Promise((resolve) => bus.once("listening", resolve));
	const run = (cmd) => spawnSync(BOX, ["-c", cmd], { cwd: r.home, encoding: "utf8", env: process.env, timeout: 15_000 });
	assert.equal(run("echo made").status, 0);
	writeFileSync(join(r.stub, "state"), "exited\n");
	assert.equal(run("echo started").status, 0);
	const scoped = readFileSync(join(r.stub, "systemd-run.log"), "utf8").trim().split("\n");
	assert.equal(scoped.length, 2, "podman run and podman start, and nothing else, go through a scope");
	for (const line of scoped) assert.match(line, /--user --scope .* -- timeout -k 5 120 podman (run|start) /);
	assert.deepEqual(r.calls().filter((c) => c[0] === "run" || c[0] === "start").map((c) => c[0]), ["run", "start"]);
});

test("without a user session bus podman runs as before, and the commands still work", (t) => {
	const r = rig(t);
	writeFileSync(join(r.home, "bin", "systemd-run"), SYSTEMD_RUN); // there, but with no bus to talk to it is not used
	chmodSync(join(r.home, "bin", "systemd-run"), 0o755);
	const ran = spawnSync(BOX, ["-c", "echo ok"], { cwd: r.home, encoding: "utf8", env: process.env, timeout: 15_000 });
	assert.equal(ran.status, 0, ran.stderr);
	assert.ok(!existsSync(join(r.stub, "systemd-run.log")), "systemd-run was not called");
	assert.ok(r.calls().some((c) => c[0] === "run"));
});

test("without an image every command is refused, saying what to do, and nothing runs on the server", async (t) => {
	const r = rig(t, { image: false });
	const ran = spawnSync(BOX, ["-c", "touch ran-outside"], { cwd: r.home, encoding: "utf8", env: process.env });
	assert.equal(ran.status, 127);
	assert.match(ran.stderr, /has not been built on this server yet/);
	assert.match(ran.stderr, /Settings > The agent's box > Build the box/);
	assert.ok(!existsSync(join(r.home, "ran-outside")), "the command did not run anywhere");
	const c = await r.box.check();
	assert.equal(c.ok, false);
	assert.match(c.message, /has not been built/);
});

// A box that says "Running" while nothing in it answers (the state it was in on the owner's server, 28 Oct): every command
// used to hang until the tool's own time limit, saying nothing. Now the exec path is probed before the command goes in.
const runBox = (r, cmd, env = {}) => {
	const t0 = Date.now();
	const out = spawnSync(BOX, ["-c", cmd], { cwd: r.home, encoding: "utf8", env: { ...process.env, ...env }, timeout: 20_000 });
	return { ...out, secs: (Date.now() - t0) / 1000 };
};
const probes = (r) => r.calls().filter((c) => c[0] === "exec" && c[2] === "true").length;

test("a box that is Running but does not answer refuses the command, quickly and saying what to do, and runs nothing", async (t) => {
	const r = rig(t, { state: "running" });
	process.env.STUB_EXEC_HANG = "1";
	const ran = runBox(r, "touch ran-outside", { BOX_PROBE_SECS: "1" });
	assert.equal(ran.status, 70, `${ran.stderr} (signal ${ran.signal})`);
	assert.ok(ran.secs < 10, `refused after ${ran.secs}s, not left hanging`);
	assert.match(ran.stderr, /the agent's box did not answer/);
	assert.match(ran.stderr, /The command was not run/);
	assert.match(ran.stderr, /Reset the box/);
	assert.match(ran.stderr, /Run the agent's commands in the box/);
	assert.ok(!existsSync(join(r.home, "ran-outside")), "not run anywhere, the server itself included");
	assert.ok(!existsSync(join(r.griphubDir, "box.alive")), "a box that did not answer is not remembered as alive");
	// The host's own test says the same, through the same launcher.
	process.env.BOX_PROBE_SECS = "1";
	const c = await r.box.check();
	assert.equal(c.ok, false);
	assert.match(c.message, /did not answer/);
});

test("podman that does not answer when asked about the container is called stuck, not 'no container'", (t) => {
	const r = rig(t, { state: "running" });
	process.env.STUB_INSPECT_HANG = "1";
	const ran = runBox(r, "true", { BOX_PROBE_SECS: "1" });
	assert.equal(ran.status, 70, ran.stderr);
	assert.match(ran.stderr, /podman did not answer in 1s/);
	assert.ok(!r.calls().some((c) => c[0] === "run"), "no second container is made over one that may exist");
});

test("a container that will not start is refused with the same words, after its own limit", (t) => {
	const r = rig(t, { state: "exited" });
	process.env.STUB_START_HANG = "1";
	const ran = runBox(r, "true", { BOX_START_SECS: "1" });
	assert.equal(ran.status, 70, ran.stderr);
	assert.match(ran.stderr, /starting the container took more than 1s/);
});

test("a healthy box is probed once, not before every command, and again after a reset", (t) => {
	const r = rig(t, { state: "running" });
	assert.equal(runBox(r, "echo one").status, 0);
	assert.equal(runBox(r, "echo two").status, 0);
	assert.equal(probes(r), 1, "the second command went in on the first one's answer");
	assert.ok(existsSync(join(r.griphubDir, "box.alive")));
	assert.equal(spawnSync(BOX, ["--reset"], { cwd: r.home, env: process.env }).status, 0);
	assert.ok(!existsSync(join(r.griphubDir, "box.alive")), "a reset forgets it");
	assert.equal(runBox(r, "echo three").status, 0);
	assert.equal(probes(r), 2);
	// And with no memory of it (BOX_ALIVE_SECS=0) every command probes.
	assert.equal(runBox(r, "echo four", { BOX_ALIVE_SECS: "0" }).status, 0);
	assert.equal(probes(r), 3);
});

test("a probe that fails some other way does not refuse: the command meets podman's own message", (t) => {
	const r = rig(t, { state: "running" });
	process.env.STUB_PROBE_EXIT = "126"; // podman answers the probe, with an error: not a hang
	const ran = runBox(r, "echo ok");
	assert.equal(ran.status, 0, ran.stderr);
	assert.doesNotMatch(ran.stderr, /did not answer/);
	assert.equal(probes(r), 1, "it did probe");
	assert.ok(!existsSync(join(r.griphubDir, "box.alive")), "an error is not an answer to remember");
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
