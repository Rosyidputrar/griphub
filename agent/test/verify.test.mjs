// Self-verification's pure parts (verify.ts): which command verifies a project, which paths are tests, and what the
// model is told after each kind of evidence.
import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdirSync, readdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { bundle, tempDir } from "./helpers.mjs";

const v = await bundle("verify");

function proj(t, files) {
	const dir = tempDir(t);
	for (const [p, text] of Object.entries(files)) {
		mkdirSync(join(dir, p, ".."), { recursive: true });
		if (p.endsWith("/")) mkdirSync(join(dir, p), { recursive: true });
		else writeFileSync(join(dir, p), text);
	}
	return dir;
}

test("the command, by the documented rules, first match wins", (t) => {
	const cmd = (files, declared) => v.detectVerifyCommand(proj(t, files), declared)?.command ?? null;
	assert.equal(cmd({ "package.json": '{"scripts":{"test":"vitest run"}}' }), "npm test");
	assert.equal(cmd({ "package.json": '{"scripts":{"test":"vitest run"}}', "pnpm-lock.yaml": "" }), "pnpm test");
	assert.equal(cmd({ "package.json": '{"scripts":{"test":"jest"}}', "yarn.lock": "" }), "yarn test");
	assert.equal(cmd({ "package.json": '{"scripts":{"test":"echo \\"Error: no test specified\\" && exit 1"}}' }), null, "npm's placeholder is no test");
	assert.equal(cmd({ "package.json": '{"scripts":{"build":"tsc"}}' }), null);
	assert.equal(cmd({ "pubspec.yaml": "name: a\ndependencies:\n  flutter:\n    sdk: flutter\n", "test/": "" }), "flutter test");
	assert.equal(cmd({ "pubspec.yaml": "name: a\n", "test/": "" }), "dart test");
	assert.equal(cmd({ "pubspec.yaml": "name: a\n" }), null, "no test folder");
	assert.equal(cmd({ gradlew: "", "app/src/test/": "" }), "./gradlew test");
	assert.equal(cmd({ "Cargo.toml": "" }), "cargo test");
	assert.equal(cmd({ "go.mod": "" }), "go test ./...");
	assert.equal(cmd({ "pytest.ini": "" }), "python -m pytest");
	assert.equal(cmd({ "pyproject.toml": "[tool.pytest.ini_options]\n" }), "python -m pytest");
	assert.equal(cmd({ "tests/test_a.py": "" }), "python -m pytest");
	assert.equal(cmd({ Makefile: "build:\n\tcc a.c\ntest:\n\t./run\n" }), "make test");
	assert.equal(cmd({ "README.md": "" }), null);
	// The user's own command for the project wins over everything.
	assert.deepEqual(v.detectVerifyCommand(proj(t, { "package.json": '{"scripts":{"test":"jest"}}' }), " make check "), { command: "make check", source: "project setting" });
});

test("test files are told apart", () => {
	for (const p of ["test/a.dart", "src/__tests__/x.js", "lib/foo.test.ts", "foo.spec.js", "tests/test_x.py", "pkg/x_test.go", "app/src/androidTest/A.kt", "test_utils.py"]) {
		assert.equal(v.isTestPath(p), true, p);
	}
	for (const p of ["lib/main.dart", "src/latest.js", "contest/a.js", "README.md", "testing.md"]) assert.equal(v.isTestPath(p), false, p);
});

test("the output's end, without colour codes", () => {
	const out = Array.from({ length: 100 }, (_, i) => `\x1b[32mline ${i}\x1b[0m`).join("\n");
	const s = v.outputSummary(out, 3);
	assert.equal(s, "line 97\nline 98\nline 99");
	assert.equal(v.outputSummary("x".repeat(5000), 40, 100).length, 100);
});

test("what the model is told after each kind of evidence", () => {
	const base = { command: "npm test", source: "package.json", exitCode: 1, durationMs: 1500, summary: "1 failing", outputId: "a-b", round: 0, maxRounds: 3, testsTouched: [], at: 0 };
	const fix = v.evidenceText({ ...base, status: "failed" }, "fix");
	assert.match(fix, /Status: FAILED \(exit code 1\), 1\.5 s/);
	assert.match(fix, /Never change, delete or skip tests/);
	assert.match(fix, /2 more rounds after this one/);
	const pass = v.evidenceText({ ...base, status: "passed", exitCode: 0 }, "close");
	assert.match(pass, /PASSED/);
	assert.match(pass, /states this verification result/);
	const end = v.evidenceText({ ...base, status: "failed", round: 3 }, "close");
	assert.match(end, /Do NOT say the task is done or works/);
	const none = v.evidenceText({ ...base, status: "none", command: null }, "close");
	assert.match(none, /No test could be run/);
	assert.match(none, /not verified by tests/);
	const changed = v.evidenceText({ ...base, status: "tests-changed", exitCode: 0, testsTouched: ["test/a.js"] }, "fix");
	assert.match(changed, /NOT ACCEPTED/);
	assert.match(changed, /Put the test files back/);
	assert.match(v.VERIFY_NOTE, /do not claim it is done/);
});

test("whole outputs are kept by id, and only ids are read", (t) => {
	const store = new v.VerifyOutputs(tempDir(t));
	const id = store.save("all of it");
	assert.equal(store.read(id), "all of it");
	assert.throws(() => store.read("../../etc/passwd"), /Unknown output/);
	assert.throws(() => store.read("zzz-zzz"), /no longer kept/);
});

test("whole outputs are kept within a count, the oldest go first", (t) => {
	const dir = tempDir(t);
	const outputs = new v.VerifyOutputs(dir, 3);
	const ids = [];
	for (let i = 0; i < 5; i++) ids.push(outputs.save(`run ${i}`));
	assert.equal(readdirSync(dir).length, 3);
	assert.throws(() => outputs.read(ids[0]), /no longer kept/);
	assert.equal(outputs.read(ids[4]), "run 4");
});

test("the check's environment keeps the shell's and drops what looks secret", () => {
	const env = v.verifyEnv({ PATH: "/bin", HOME: "/h", LANG: "id", GRIPHUB_STORE_KEY: "x", GITHUB_TOKEN: "x", OPENAI_API_KEY: "x", DB_PASSWORD: "x", AWS_SECRET_ACCESS_KEY: "x", NPM_CONFIG_CACHE: "/c" });
	assert.deepEqual(Object.keys(env).sort(), ["CI", "HOME", "LANG", "NPM_CONFIG_CACHE", "PATH"]);
});

test("test files and setups the old rules missed", () => {
	for (const f of ["test.js", "src/spec.ts", "tests.py", "vite.config.ts", "jest.setup.js", "src/setupTests.ts", "lib/testFixtures/a.json"]) {
		assert.ok(v.isTestPath(f) || v.isTestConfig(f), f);
	}
	assert.ok(!v.isTestPath("src/latest.js") && !v.isTestConfig("src/contest.ts"));
});
