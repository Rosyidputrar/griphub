/**
 * Self-verification (Fitur 2): a coding task that changed files is not "done" on the agent's word. Before the run
 * settles, the host runs the project's own checks, puts the result in the chat as evidence, and lets the agent go on:
 * to fix a failure (a few rounds), or to write its closing message, which must report that evidence.
 *
 * This file holds the parts that need no session: which command verifies a project, running it, telling test files
 * apart (a failure is never fixed by editing the tests), and the evidence's wording. host.ts wires it into pi's
 * agent_before_settle boundary, and runs the command only after the guard allows it like any bash call (guard.ts
 * allowCommand).
 */

import { spawn } from "node:child_process";
import { createHash } from "node:crypto";
import { existsSync, mkdirSync, readdirSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { getShellConfig } from "@earendil-works/pi-coding-agent";

// ---------------------------------------------------------------------------
// Which command

export interface VerifyCommand {
	command: string;
	/** Where it came from: the user's project setting, or the file that names it. */
	source: string;
}

const NPM_DEFAULT_TEST = /no test specified/i;

/**
 * The command that verifies the project in [cwd], by these rules, first match wins:
 *   1. the command the user set for this project in Settings;
 *   2. package.json with a real "test" script (not npm's "no test specified"): npm test, or pnpm / yarn / bun test when
 *      their lockfile is there;
 *   3. pubspec.yaml: `flutter test` when it depends on Flutter, else `dart test`, only when a test/ folder exists;
 *   4. gradlew with a src/test folder anywhere one level down: `./gradlew test`;
 *   5. Cargo.toml: `cargo test`; go.mod: `go test ./...`;
 *   6. pytest.ini, a [tool.pytest...] section in pyproject.toml, or a tests/ folder with Python in it: `python -m pytest`;
 *   7. a Makefile with a `test:` target: `make test`.
 * Null when none applies: the evidence then says no test could be run, never that it passed.
 */
export function detectVerifyCommand(cwd: string, declared?: string | null): VerifyCommand | null {
	if (declared && declared.trim()) return { command: declared.trim(), source: "project setting" };
	const has = (p: string) => existsSync(join(cwd, p));
	const read = (p: string) => {
		try {
			return readFileSync(join(cwd, p), "utf8");
		} catch {
			return "";
		}
	};
	if (has("package.json")) {
		let test: unknown;
		try {
			test = JSON.parse(read("package.json"))?.scripts?.test;
		} catch {
			test = undefined;
		}
		if (typeof test === "string" && test.trim() && !NPM_DEFAULT_TEST.test(test)) {
			const pm = has("pnpm-lock.yaml") ? "pnpm" : has("yarn.lock") ? "yarn" : has("bun.lockb") || has("bun.lock") ? "bun" : "npm";
			return { command: `${pm} test`, source: "package.json" };
		}
	}
	if (has("pubspec.yaml") && isDir(join(cwd, "test"))) {
		const flutter = /^\s{2}flutter:\s*\n\s{4}sdk:\s*flutter/m.test(read("pubspec.yaml"));
		return { command: flutter ? "flutter test" : "dart test", source: "pubspec.yaml" };
	}
	if (has("gradlew") && (isDir(join(cwd, "src", "test")) || isDir(join(cwd, "app", "src", "test")))) {
		return { command: "./gradlew test", source: "gradlew" };
	}
	if (has("Cargo.toml")) return { command: "cargo test", source: "Cargo.toml" };
	if (has("go.mod")) return { command: "go test ./...", source: "go.mod" };
	if (has("pytest.ini") || /\[tool\.pytest/.test(read("pyproject.toml")) || pythonTests(join(cwd, "tests"))) {
		return { command: "python -m pytest", source: has("pytest.ini") ? "pytest.ini" : has("pyproject.toml") ? "pyproject.toml" : "tests/" };
	}
	if (has("Makefile") && /^test:/m.test(read("Makefile"))) return { command: "make test", source: "Makefile" };
	return null;
}

function isDir(p: string): boolean {
	try {
		return statSync(p).isDirectory();
	} catch {
		return false;
	}
}

function pythonTests(dir: string): boolean {
	try {
		return isDir(dir) && readdirSync(dir).some((n) => n.endsWith(".py"));
	} catch {
		return false;
	}
}

// ---------------------------------------------------------------------------
// Test files: a failure is fixed in the code, never by changing the tests

const TEST_PATH =
	/(^|\/)(test|tests|__tests__|spec|specs|androidTest|testFixtures)\/|(^|\/)[^/]*([._-](test|spec))\.[a-z0-9]+$|(^|\/)(test|tests|spec|specs)\.[a-z0-9]+$|(^|\/)test_[^/]*\.py$|_test\.(go|dart|py|rs)$/i;

export function isTestPath(path: string): boolean {
	return TEST_PATH.test(path);
}

/** Files that only configure how tests run: changing them while fixing a failure changes the tests too. */
const TEST_CONFIG =
	/(^|\/)(pytest\.ini|tox\.ini|conftest\.py|phpunit\.xml(\.dist)?|karma\.conf\.[cm]?[jt]s|(jest|vitest|vite|playwright|cypress)\.config\.[cm]?[jt]s|vitest\.workspace\.[cm]?[jt]s|(jest\.setup|setupTests)\.[cm]?[jt]sx?|\.mocharc\.[a-z]+|\.nycrc(\.[a-z]+)?|dart_test\.yaml)$/i;

export function isTestConfig(path: string): boolean {
	return TEST_CONFIG.test(path);
}

/**
 * How the project's tests are defined, beyond the test files: the test script in package.json, the Makefile's test
 * target, pytest's section of pyproject.toml. Weakening one of these (`"test": "exit 0"`) is changing the tests; the
 * rest of those files (a new dependency, another target) is not.
 */
export function testDefinition(cwd: string): Record<string, string> {
	const read = (p: string) => {
		try {
			return readFileSync(join(cwd, p), "utf8");
		} catch {
			return null;
		}
	};
	const out: Record<string, string> = {};
	const pkg = read("package.json");
	if (pkg !== null) {
		try {
			const json = JSON.parse(pkg) ?? {};
			for (const [k, v] of Object.entries(json.scripts ?? {})) if (/^(pre|post)?test(:|$)/.test(k)) out[`package.json (${k})`] = String(v);
			// Test runners configured inside package.json.
			for (const k of ["jest", "vitest", "mocha", "ava", "c8", "nyc"]) if (json[k] !== undefined) out[`package.json (${k})`] = JSON.stringify(json[k]);
		} catch {
			out["package.json (test)"] = "unreadable";
		}
	}
	// Gradle: the blocks that say how tests run (test { }, tasks.test, withType<Test>, testOptions).
	for (const f of ["build.gradle", "build.gradle.kts", "app/build.gradle", "app/build.gradle.kts"]) {
		const g = read(f);
		if (g === null) continue;
		const blocks = gradleTestBlocks(g);
		if (blocks.length) out[`${f} (test)`] = blocks.join("\n");
	}
	const make = read("Makefile");
	if (make !== null) {
		const m = /^test:.*(\n\t.*)*/m.exec(make);
		if (m) out["Makefile (test)"] = m[0];
	}
	const py = read("pyproject.toml");
	if (py !== null) {
		const m = /^\[tool\.pytest[^\]]*\][^[]*/m.exec(py);
		if (m) out["pyproject.toml (pytest)"] = m[0];
	}
	return out;
}

/** The `test { ... }`-like blocks of a Gradle build file, braces matched. */
function gradleTestBlocks(text: string): string[] {
	const out: string[] = [];
	const start = /^\s*(tasks\.)?(test|testOptions|withType<Test>|withType\(Test\)|named\(["']test["']\)|tasks\.named<Test>\(["']test["']\))\b[^\n{]*\{/gm;
	for (const m of text.matchAll(start)) {
		let depth = 0;
		let i = (m.index ?? 0) + m[0].length - 1;
		const from = m.index ?? 0;
		for (; i < text.length; i++) {
			if (text[i] === "{") depth++;
			else if (text[i] === "}" && --depth === 0) break;
		}
		out.push(text.slice(from, i + 1));
	}
	return out;
}

/** Folders never looked into for tests: dependencies, builds and caches (not the project's own tests). */
const SKIP_DIRS = new Set(["node_modules", ".git", ".dart_tool", ".gradle", "build", "dist", "out", "target", ".next", ".venv", "venv", "__pycache__", ".pytest_cache", "coverage", ".idea", "Pods", ".pub-cache"]);

/**
 * The project's test files and test configuration, each with a hash of its content, read from the folder itself (not
 * the checkpoint repository, which skips what .gitignore names: a test folder in .gitignore is still seen here).
 */
export function testFingerprint(cwd: string, limit = 20_000): Record<string, string> {
	const out: Record<string, string> = {};
	let seen = 0;
	const walk = (dir: string, rel: string) => {
		let names: import("node:fs").Dirent[];
		try {
			names = readdirSync(dir, { withFileTypes: true });
		} catch {
			return;
		}
		for (const d of names) {
			if (++seen > limit) return;
			const r = rel ? `${rel}/${d.name}` : d.name;
			const p = join(dir, d.name);
			if (d.isDirectory()) {
				if (!SKIP_DIRS.has(d.name)) walk(p, r);
			} else if (d.isFile() && (isTestPath(r) || isTestConfig(r))) {
				try {
					const st = statSync(p);
					out[r] = st.size > 4_000_000 ? `size:${st.size}:${st.mtimeMs}` : createHash("sha1").update(readFileSync(p)).digest("hex");
				} catch {}
			}
		}
	};
	walk(cwd, "");
	return out;
}

/** Test files changed between two fingerprints: changed or removed always; added only when [added] says so. */
export function testsChanged(before: Record<string, string>, after: Record<string, string>, { added = false } = {}): string[] {
	const out = Object.keys(before).filter((f) => after[f] !== before[f]);
	if (added) out.push(...Object.keys(after).filter((f) => !(f in before)));
	return out.sort();
}

/** A short fingerprint of how tests run here: the command and its definition (for the approval that covers it). */
export function definitionKey(command: string, def: Record<string, string>): string {
	return createHash("sha1").update(JSON.stringify([command, Object.entries(def).sort()])).digest("hex").slice(0, 16);
}

/**
 * The environment the check runs in: the host's, without what looks like a secret (keys, tokens, passwords). The
 * project's test code is not the agent's and has no business with GripHub's or GitHub's credentials.
 */
export function verifyEnv(env: NodeJS.ProcessEnv = process.env): NodeJS.ProcessEnv {
	const secret = /(TOKEN|SECRET|PASSW|API_?KEY|ACCESS_?KEY|PRIVATE|CREDENTIAL|AUTH|COOKIE|SESSION|_KEY$|^KEY$)/i;
	const out: NodeJS.ProcessEnv = {};
	for (const [k, v] of Object.entries(env)) if (!secret.test(k)) out[k] = v;
	return { ...out, CI: "1" };
}

/** The names in [testDefinition] that differ between two readings of it. */
export function testDefinitionChanged(before: Record<string, string>, after: Record<string, string>): string[] {
	const keys = new Set([...Object.keys(before), ...Object.keys(after)]);
	return [...keys].filter((k) => before[k] !== after[k]).sort();
}

// ---------------------------------------------------------------------------
// Running it

export interface VerifyRun {
	exitCode: number | null;
	/** Killed for taking longer than the limit, or stopped by the user. */
	timedOut: boolean;
	aborted: boolean;
	durationMs: number;
	/** The whole output (stdout and stderr in order), capped at FULL_CAP from the end. */
	output: string;
	truncated: boolean;
}

/** How much of a run's output is kept (the end of it). */
export const FULL_CAP = 2_000_000;
export const VERIFY_TIMEOUT_MS = 15 * 60_000;

/** Runs [command] in [cwd] with the agent's own shell (the same as its bash tool: the container on the phone). */
export function runVerify(command: string, cwd: string, shellPath: string | undefined, signal?: AbortSignal, timeoutMs = VERIFY_TIMEOUT_MS): Promise<VerifyRun> {
	return new Promise((resolve) => {
		const shell = getShellConfig(shellPath);
		const started = Date.now();
		let output = "";
		let truncated = false;
		let timedOut = false;
		const child = spawn(shell.shell, [...shell.args, command], {
			cwd,
			detached: true,
			env: verifyEnv(),
			stdio: ["ignore", "pipe", "pipe"],
		});
		const add = (chunk: Buffer) => {
			output += chunk.toString("utf8");
			if (output.length > FULL_CAP) {
				output = output.slice(output.length - FULL_CAP);
				truncated = true;
			}
		};
		child.stdout?.on("data", add);
		child.stderr?.on("data", add);
		const kill = () => {
			try {
				if (child.pid) process.kill(-child.pid, "SIGKILL");
			} catch {
				child.kill("SIGKILL");
			}
		};
		const timer = setTimeout(() => {
			timedOut = true;
			kill();
		}, timeoutMs);
		const onAbort = () => kill();
		signal?.addEventListener("abort", onAbort, { once: true });
		const finish = (code: number | null) => {
			clearTimeout(timer);
			signal?.removeEventListener("abort", onAbort);
			resolve({ exitCode: code, timedOut, aborted: !!signal?.aborted, durationMs: Date.now() - started, output, truncated });
		};
		child.on("error", (e) => {
			add(Buffer.from(`\n${e.message}\n`));
			finish(null);
		});
		child.on("close", (code) => finish(code));
	});
}

/** The end of the output, as the evidence shows it: the last [lines] lines, at most [chars] characters. */
export function outputSummary(output: string, lines = 40, chars = 3_000): string {
	const all = output.replace(/\x1b\[[0-9;?]*[A-Za-z]/g, "").replace(/\r(?!\n)/g, "\n").trimEnd();
	let tail = all.split("\n").slice(-lines).join("\n");
	if (tail.length > chars) tail = tail.slice(tail.length - chars);
	return tail;
}

// ---------------------------------------------------------------------------
// The evidence

/**
 * passed / failed: the check ran. tests-changed: tests or their setup were changed while fixing a failure (not taken as
 * a pass). passed-tests-changed: it passed, but the task changed tests that were there before (said, not hidden).
 * setup-changed: the task changed how tests run (the test script, the runner's config), so the app did not run that.
 * unmeasured: the folder could not be measured, so nothing could be checked. none / declined: nothing ran.
 */
export type VerifyStatus = "passed" | "failed" | "none" | "declined" | "tests-changed" | "passed-tests-changed" | "setup-changed" | "unmeasured";

export interface Evidence {
	status: VerifyStatus;
	command: string | null;
	source: string | null;
	exitCode: number | null;
	durationMs: number;
	summary: string;
	/** Id of the whole output, kept by the host (verify_output). */
	outputId: string | null;
	round: number;
	maxRounds: number;
	/** Test files (or their setup) changed by the task, or while fixing a failure (the result is then not taken as a pass). */
	testsTouched: string[];
	/** Why it did not run (declined). */
	reason?: string;
	timedOut?: boolean;
	at: number;
}

/** Message type of the evidence in the chat: shown by the app as an evidence block, read by the model as a message. */
export const VERIFY_MESSAGE = "griphub_verify";

/** What comes next after this evidence. */
export type NextStep = "close" | "fix";

const seconds = (ms: number) => `${(ms / 1000).toFixed(1)} s`;

/** What the model reads: the facts, then exactly what it must do next. */
export function evidenceText(e: Evidence, next: NextStep): string {
	const head = `[Verification evidence #${e.round + 1}, run by the app in this session, not a claim]`;
	const touched = e.testsTouched.length ? e.testsTouched.join(", ") : "";
	const facts =
		e.status === "none"
			? ["No test could be run for this project (no test command found, and none is set in the project's settings)."]
			: e.status === "declined"
				? [`Command: ${e.command}`, `Not run: ${e.reason ?? "the user did not allow it"}.`]
				: e.status === "unmeasured"
					? ["Not checked: the app could not measure what changed in the folder, so it ran nothing."]
					: e.status === "setup-changed"
						? [`Command: ${e.command}`, `Not run: this task changed how the tests run (${touched}). The app does not run a test setup the task changed.`]
						: e.status === "tests-changed" && e.exitCode === null
							? [`Command: ${e.command}`, `Status: NOT ACCEPTED (how the tests run was changed while fixing: ${touched}); not run.`]
							: [
									`Command: ${e.command}`,
									`Status: ${e.status === "passed" ? "PASSED" : e.status === "passed-tests-changed" ? "PASSED, BUT THIS TASK CHANGED EXISTING TESTS" : e.status === "tests-changed" ? "NOT ACCEPTED (tests were changed)" : "FAILED"}${e.exitCode !== null ? ` (exit code ${e.exitCode})` : ""}${e.timedOut ? " (stopped: took too long)" : ""}, ${seconds(e.durationMs)}`,
									...(touched ? [`Existing tests changed by this task: ${touched}`] : []),
									"Output (end):",
									"```",
									e.summary || "(no output)",
									"```",
								];
	const ask =
		next === "fix"
			? [
					e.status === "tests-changed"
						? "Put the test files back as they were and fix the code instead."
						: "Fix the cause of the failure in the code.",
					"Never change, delete or skip tests to make them pass. When done, stop: the app runs the check again" +
						` (${e.maxRounds - e.round - 1} more ${e.maxRounds - e.round - 1 === 1 ? "round" : "rounds"} after this one).`,
				]
			: e.status === "passed"
				? ["Write a short closing message for the user that states this verification result (passed, with the command). Do not change files any more."]
				: e.status === "passed-tests-changed"
					? [
							"Write a short closing message that states the tests passed AND, plainly, which existing tests this task changed and why.",
							"Do not present it as the original tests passing. Do not change files any more.",
						]
					: e.status === "none" || e.status === "declined" || e.status === "unmeasured" || e.status === "setup-changed"
						? ["Write a short closing message for the user that says plainly the change was not verified by tests, and why. Do not say it works. Do not change files any more."]
					: [
							"No fix rounds are left. Write a closing message that reports this failure as it is, with the last result.",
							"Do NOT say the task is done or works. Do not change files any more.",
						];
	return [head, ...facts, "", ...ask].join("\n");
}

/** Added to a coding chat's system prompt while self-verification is on. */
export const VERIFY_NOTE = [
	"",
	"# Verification in this app",
	"When you finish a task that changed files, do not claim it is done, fixed or working: summarise what you changed and stop.",
	"The app then runs the project's tests itself and gives you the result (a verification evidence message) for your closing message.",
	"Never change, delete or skip tests to make them pass.",
].join("\n");

// ---------------------------------------------------------------------------
// Whole outputs, for "show the full output"

export class VerifyOutputs {
	/** At most [keep] outputs and [maxBytes] in all stay (the oldest go first). */
	constructor(private readonly dir: string, private readonly keep = 60, private readonly maxBytes = 50_000_000) {}

	save(output: string): string {
		mkdirSync(this.dir, { recursive: true });
		const id = `${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 8)}`;
		writeFileSync(join(this.dir, `${id}.log`), output, { mode: 0o600 });
		this.prune();
		return id;
	}

	private prune() {
		try {
			const files = readdirSync(this.dir)
				.filter((n) => n.endsWith(".log"))
				.map((n) => ({ n, st: statSync(join(this.dir, n)) }))
				.sort((a, b) => b.st.mtimeMs - a.st.mtimeMs || b.n.localeCompare(a.n));
			let bytes = 0;
			files.forEach((f, i) => {
				bytes += f.st.size;
				if (i >= this.keep || bytes > this.maxBytes) rmSync(join(this.dir, f.n), { force: true });
			});
		} catch {}
	}

	read(id: string): string {
		if (!/^[a-z0-9]+-[a-z0-9]+$/.test(id)) throw new Error("Unknown output");
		const f = join(this.dir, `${id}.log`);
		if (!existsSync(f)) throw new Error("This output is no longer kept");
		return readFileSync(f, "utf8");
	}
}
