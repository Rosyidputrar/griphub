// Signing in to GitHub with a code (the device flow): the HOST waits for the approval. The app used to poll, so leaving
// the app, locking the screen or cancelling the wait before approving on github.com ended the polling for good: the code
// expired after 15 minutes and no token was ever saved. fetch is replaced by a scripted fake GitHub; git config goes to
// a temp HOME. Intervals are fractions of a second so a flow runs in milliseconds.
import { test, beforeEach, afterEach } from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { bundle, waitFor } from "./helpers.mjs";

// secure.ts refuses to write tokens in plaintext; it reads the key once, at import.
process.env.GRIPHUB_STORE_KEY = "ab".repeat(32);
const { Integrations } = await bundle("integrations");

const realFetch = globalThis.fetch;
const realHome = process.env.HOME;
let gh;
let made = [];
let dirs = [];
const tmp = (prefix) => {
	const d = mkdtempSync(join(tmpdir(), prefix));
	dirs.push(d);
	return d;
};

/**
 * A fake github.com. [plan] is what the token endpoint answers to each poll, in turn (the last one repeats):
 * "pending", "slow", "approve", "denied", "expired", "bad" (a wrong Client ID) or "down" (no network).
 */
function fakeGithub(plan, o = {}) {
	const s = {
		plan,
		tokenCalls: 0,
		perCode: {},
		codes: 0,
		userCalls: 0,
		userFailures: o.userFailures ?? 0,
		expiresIn: o.expiresIn ?? 900,
		interval: o.interval ?? 0.02,
	};
	globalThis.fetch = async (url, init = {}) => {
		const u = String(url);
		const json = (status, body) => new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });
		if (u === "https://github.com/login/device/code") {
			s.codes++;
			return json(200, { device_code: `dev${s.codes}`, user_code: "ABCD-1234", verification_uri: "https://github.com/login/device", expires_in: s.expiresIn, interval: s.interval });
		}
		if (u === "https://github.com/login/oauth/access_token") {
			const body = JSON.parse(init.body);
			s.tokenCalls++;
			s.perCode[body.device_code] = (s.perCode[body.device_code] ?? 0) + 1;
			const step = s.plan[Math.min(s.tokenCalls - 1, s.plan.length - 1)];
			switch (step) {
				case "down":
					throw new TypeError("fetch failed");
				case "slow":
					return json(200, { error: "slow_down", interval: 0.03 });
				case "approve":
					return json(200, { access_token: "ghu_dev", token_type: "bearer", refresh_token: "ghr_dev", expires_in: 28800, refresh_token_expires_in: 15897600 });
				case "denied":
					return json(200, { error: "access_denied" });
				case "expired":
					return json(200, { error: "expired_token" });
				case "bad":
					return json(200, { error: "incorrect_client_credentials", error_description: "The client_id and/or client_secret passed are incorrect." });
				default:
					return json(200, { error: "authorization_pending" });
			}
		}
		if (u === "https://api.github.com/user") {
			s.userCalls++;
			if (s.userFailures > 0) {
				s.userFailures--;
				return json(500, { message: "Server Error" });
			}
			return json(200, { login: "akun1", id: 1, name: "Akun", avatar_url: "a" });
		}
		throw new Error(`unexpected fetch ${u}`);
	};
	return s;
}

function integrations() {
	const it = new Integrations(tmp("gh-agentdir-"), tmp("gh-ws-"));
	it.store.settings = { githubClientId: "Iv23.app" };
	it.changes = 0;
	it.onChange = () => it.changes++;
	made.push(it);
	return it;
}

const status = (it) => it.githubDeviceStatus().status;
const gitHeader = () => {
	try {
		return execFileSync("git", ["config", "--global", "--get", "http.https://github.com/.extraheader"], { stdio: "pipe" }).toString().trim();
	} catch {
		return "";
	}
};
const basic = (token) => `Authorization: Basic ${Buffer.from(`x-access-token:${token}`).toString("base64")}`;
const pause = (ms) => new Promise((r) => setTimeout(r, ms));

beforeEach(() => {
	process.env.HOME = tmp("gh-home-");
	made = [];
});
afterEach(() => {
	for (const it of made) it.githubDeviceCancel();
	globalThis.fetch = realFetch;
	process.env.HOME = realHome;
	for (const d of dirs) rmSync(d, { recursive: true, force: true });
	dirs = [];
});

test("the host waits for the approval by itself: nobody asks it, and the sign-in still completes and the app is told", async () => {
	gh = fakeGithub(["pending", "pending", "approve"]);
	const it = integrations();
	const flow = await it.githubDeviceStart();
	assert.equal(flow.userCode, "ABCD-1234");
	assert.equal(status(it), "pending");
	// The app is not asking: no githubDevicePoll from here on, as when it was closed or its screen was left.
	await waitFor("the host to sign in", () => status(it) === "done", 5000);
	assert.equal(gh.tokenCalls, 3, "the host asked GitHub three times, on its own");
	assert.equal(it.store.github.login, "akun1");
	assert.equal(it.store.github.refreshToken, "ghr_dev", "the refresh token comes along, as for any device-flow sign-in");
	assert.equal(gitHeader(), basic("ghu_dev"), "git has the token");
	assert.equal(it.changes, 1, "the app is told the account changed, so it shows it without having waited");
	await pause(120);
	assert.equal(gh.tokenCalls, 3, "and it stops asking once signed in");
});

test("slow_down is obeyed, and the wait goes on", async () => {
	gh = fakeGithub(["slow", "pending", "approve"]);
	const it = integrations();
	await it.githubDeviceStart();
	await waitFor("the sign-in", () => status(it) === "done", 5000);
	assert.equal(it.githubDeviceStatus().interval, 0.03, "GitHub's new interval");
});

test("a code nobody approves expires: the host says so and stops asking GitHub", async () => {
	gh = fakeGithub(["pending"], { expiresIn: 0.15 });
	const it = integrations();
	await it.githubDeviceStart();
	await waitFor("the code to expire", () => status(it) === "expired", 5000);
	const asked = gh.tokenCalls;
	assert.ok(asked >= 1);
	await pause(120);
	assert.equal(gh.tokenCalls, asked, "no more questions after it expired");
	assert.equal(it.store.github, undefined);
});

test("GitHub saying expired or denied ends the wait with that word", async () => {
	gh = fakeGithub(["denied"]);
	const it = integrations();
	await it.githubDeviceStart();
	await waitFor("denied", () => status(it) === "denied", 5000);
	gh = fakeGithub(["expired"]);
	await it.githubDeviceStart();
	await waitFor("expired", () => status(it) === "expired", 5000);
	assert.equal(it.store.github, undefined);
});

test("a wrong Client ID is an error the app can read, not a wait for ever", async () => {
	gh = fakeGithub(["bad"]);
	const it = integrations();
	await it.githubDeviceStart();
	await waitFor("the error", () => status(it) === "error", 5000);
	assert.match(it.githubDeviceStatus().error, /client_id/);
	await assert.rejects(() => it.githubDevicePoll("dev1"), /client_id/);
});

test("no network while waiting is not the end: the host keeps asking, and signs in when it is back", async () => {
	gh = fakeGithub(["down", "down", "pending", "approve"]);
	const it = integrations();
	await it.githubDeviceStart();
	await waitFor("the sign-in", () => status(it) === "done", 5000);
	assert.equal(gh.tokenCalls, 4);
});

test("cancelling stops the host asking, and a late approval signs in nothing", async () => {
	gh = fakeGithub(["pending"]);
	const it = integrations();
	await it.githubDeviceStart();
	await waitFor("a few questions", () => gh.tokenCalls >= 2, 5000);
	assert.equal(it.githubDeviceCancel().status, "none");
	assert.equal(status(it), "none");
	const asked = gh.tokenCalls;
	gh.plan = ["approve"]; // the user approves on github.com after all: too late, they cancelled
	await pause(150);
	assert.equal(gh.tokenCalls, asked);
	assert.equal(it.store.github, undefined);
});

test("starting again replaces the flow: the first code is not asked about any more", async () => {
	gh = fakeGithub(["pending"]);
	const it = integrations();
	await it.githubDeviceStart();
	await waitFor("the first to be asked", () => gh.perCode.dev1 >= 1, 5000);
	await it.githubDeviceStart();
	await pause(50);
	const first = gh.perCode.dev1;
	await pause(150);
	assert.equal(gh.perCode.dev1, first, "dev1 is left alone");
	assert.ok(gh.perCode.dev2 >= 2, "dev2 is the one being asked");
	assert.equal(it.githubDeviceStatus().deviceCode, "dev2");
});

test("signing out ends a sign-in under way", async () => {
	gh = fakeGithub(["pending"]);
	const it = integrations();
	await it.githubDeviceStart();
	await it.githubLogout();
	const asked = gh.tokenCalls;
	await pause(120);
	assert.equal(gh.tokenCalls, asked);
	assert.equal(status(it), "none");
});

test("once GitHub has given the token, a sign-in that fails is retried with it: the code is spent, GitHub is not asked again", async () => {
	gh = fakeGithub(["approve"], { userFailures: 2 });
	const it = integrations();
	await it.githubDeviceStart();
	await waitFor("the sign-in", () => status(it) === "done", 5000);
	assert.equal(gh.tokenCalls, 1, "the token endpoint was asked once: the code is spent after it answers");
	assert.equal(gh.userCalls, 3, "two failures, then it went through");
	assert.equal(it.store.github.login, "akun1");
});

test("a sign-in that keeps failing after approval is said, not retried for ever", async () => {
	gh = fakeGithub(["approve"], { userFailures: 99 });
	const it = integrations();
	await it.githubDeviceStart();
	await waitFor("the error", () => status(it) === "error", 5000);
	assert.equal(gh.tokenCalls, 1);
	assert.equal(gh.userCalls, 5, "five tries");
	assert.ok(it.githubDeviceStatus().error);
	assert.equal(it.store.github, undefined);
});

test("an app that polls for itself (an older one) is answered from the host's wait, not by asking GitHub a second time", async () => {
	gh = fakeGithub(["pending", "approve"], { interval: 5 }); // the host's own first question is 5 s away
	const it = integrations();
	const flow = await it.githubDeviceStart();
	assert.deepEqual(await it.githubDevicePoll(flow.deviceCode), { status: "pending" });
	assert.equal(gh.tokenCalls, 0, "the app's poll did not reach GitHub");
	// A code the host has no flow for (it was restarted since the app asked for it) is asked about once, as before.
	const other = await it.githubDevicePoll("some-other-code");
	assert.deepEqual(other, { status: "pending" });
	assert.equal(gh.tokenCalls, 1);
	const done = await it.githubDevicePoll("some-other-code");
	assert.equal(done.status, "done");
	assert.equal(done.state.github.login, "akun1");
});

test("the status says what an app that comes back needs: the code, where, and how long is left", async () => {
	gh = fakeGithub(["pending"], { expiresIn: 600, interval: 5 });
	const it = integrations();
	assert.deepEqual(it.githubDeviceStatus(), { status: "none" });
	await it.githubDeviceStart();
	const s = it.githubDeviceStatus();
	assert.equal(s.status, "pending");
	assert.equal(s.userCode, "ABCD-1234");
	assert.equal(s.verificationUri, "https://github.com/login/device");
	assert.ok(s.expiresIn >= 598 && s.expiresIn <= 600, `${s.expiresIn} seconds left, not a time of the host's clock`);
	assert.equal(s.expiresAt, undefined);
});
