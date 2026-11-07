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
import { existsSync, mkdirSync, readdirSync, readFileSync, statSync, writeFileSync } from "node:fs";
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

const TEST_PATH = /(^|\/)(test|tests|__tests__|spec|specs|androidTest)\/|(^|\/)[^/]*([._-](test|spec))\.[a-z0-9]+$|(^|\/)test_[^/]*\.py$|_test\.(go|dart|py|rs)$/i;

export function isTestPath(path: string): boolean {
	return TEST_PATH.test(path);
}

/** Files that only configure how tests run: changing them while fixing a failure changes the tests too. */
const TEST_CONFIG = /(^|\/)(pytest\.ini|tox\.ini|conftest\.py|phpunit\.xml(\.dist)?|karma\.conf\.[cm]?[jt]s|(jest|vitest|playwright|cypress)\.config\.[cm]?[jt]s|\.mocharc\.[a-z]+|\.nycrc(\.[a-z]+)?|dart_test\.yaml)$/i;

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
			const scripts = JSON.parse(pkg)?.scripts ?? {};
			for (const [k, v] of Object.entries(scripts)) if (/^(pre|post)?test(:|$)/.test(k)) out[`package.json (${k})`] = String(v);
		} catch {
			out["package.json (test)"] = "unreadable";
		}
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
			env: { ...process.env, CI: "1" },
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

export type VerifyStatus = "passed" | "failed" | "none" | "declined" | "tests-changed";

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
	/** Test files changed while fixing a failure (the result is then not taken as a pass). */
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
	const facts =
		e.status === "none"
			? ["No test could be run for this project (no test command found, and none is set in the project's settings)."]
			: e.status === "declined"
				? [`Command: ${e.command}`, `Not run: ${e.reason ?? "the user did not allow it"}.`]
				: [
						`Command: ${e.command}`,
						`Status: ${e.status === "passed" ? "PASSED" : e.status === "tests-changed" ? "NOT ACCEPTED (tests were changed)" : "FAILED"}${e.exitCode !== null ? ` (exit code ${e.exitCode})` : ""}${e.timedOut ? " (stopped: took too long)" : ""}, ${seconds(e.durationMs)}`,
						...(e.testsTouched.length ? [`Test files changed while fixing: ${e.testsTouched.join(", ")}`] : []),
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
				: e.status === "none" || e.status === "declined"
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
	constructor(private readonly dir: string) {}

	save(output: string): string {
		mkdirSync(this.dir, { recursive: true });
		const id = `${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 8)}`;
		writeFileSync(join(this.dir, `${id}.log`), output, { mode: 0o600 });
		return id;
	}

	read(id: string): string {
		if (!/^[a-z0-9]+-[a-z0-9]+$/.test(id)) throw new Error("Unknown output");
		const f = join(this.dir, `${id}.log`);
		if (!existsSync(f)) throw new Error("This output is no longer kept");
		return readFileSync(f, "utf8");
	}
}
