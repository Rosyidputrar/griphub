// GitHub sign-in lifetime: GitHub App device-flow tokens expire after 8 hours
// and come with a refresh token. They used to be stored without it, so every
// GitHub call failed with "Bad credentials (401)" a few hours after sign-in.
// fetch is replaced by a scripted fake GitHub; git config goes to a temp HOME.
import { test, beforeEach, afterEach } from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdirSync, mkdtempSync, rmSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { build } from "esbuild";

const here = dirname(fileURLToPath(import.meta.url));
mkdirSync(join(here, "..", "build"), { recursive: true });
const out = mkdtempSync(join(here, "..", "build", "github-auth-test-"));
async function bundle(name) {
	const outfile = join(out, `${name}.mjs`);
	await build({ entryPoints: [join(here, "..", "src", `${name}.ts`)], outfile, bundle: true, platform: "node", format: "esm", packages: "external", logLevel: "error" });
	return import(pathToFileURL(outfile).href);
}
// secure.ts refuses to write tokens in plaintext; it reads the key once, at import.
process.env.GRIPHUB_STORE_KEY = "ab".repeat(32);
const { Integrations, GithubAuthError } = await bundle("integrations");

const HOUR = 3600_000;
const realFetch = globalThis.fetch;
const realHome = process.env.HOME;
let gh;

/**
 * A fake github.com: tokens in [valid] pass /user; refresh tokens in [refresh]
 * map to the next pair. Counts calls so tests can check single-flight.
 */
function fakeGithub() {
	const state = { valid: new Set(), refresh: new Map(), refreshCalls: 0, apiCalls: 0, delay: 0, down: false };
	globalThis.fetch = async (url, init = {}) => {
		const u = String(url);
		const json = (status, body) => new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });
		if (state.down) throw new TypeError("fetch failed");
		if (u === "https://github.com/login/oauth/access_token") {
			const body = JSON.parse(init.body);
			if (body.grant_type === "refresh_token") {
				state.refreshCalls++;
				if (state.delay) await new Promise((r) => setTimeout(r, state.delay));
				assert.equal(body.client_secret, undefined, "device-flow refresh must not need a secret");
				const next = state.refresh.get(body.refresh_token);
				if (!next || body.client_id !== "Iv23.app") return json(200, { error: "bad_refresh_token", error_description: "The refresh token passed is incorrect or expired." });
				// GitHub rotates: the used refresh token and the old access token stop working.
				state.refresh.delete(body.refresh_token);
				state.valid.add(next.access_token);
				return json(200, { ...next, expires_in: 28800, refresh_token_expires_in: 15897600, token_type: "bearer" });
			}
			return json(200, { error: "authorization_pending" });
		}
		if (u.startsWith("https://api.github.com/")) {
			state.apiCalls++;
			const token = String(init.headers?.Authorization ?? "").replace("Bearer ", "");
			if (!state.valid.has(token)) return json(401, { message: "Bad credentials" });
			if (u.endsWith("/user")) return json(200, { login: "akun1", id: 1, name: "Akun", avatar_url: "a" });
			return json(200, []);
		}
		throw new Error(`unexpected fetch ${u}`);
	};
	return state;
}

function signedIn(account) {
	const it = new Integrations(mkdtempSync(join(out, "agentdir-")), mkdtempSync(join(out, "ws-")));
	it.store.github = { login: "akun1", name: "Akun", email: "a@b", avatarUrl: "a", ...account };
	return it;
}

const gitHeader = () => {
	try {
		return execFileSync("git", ["config", "--global", "--get", "http.https://github.com/.extraheader"], { stdio: "pipe" }).toString().trim();
	} catch {
		return "";
	}
};
const basic = (token) => `Authorization: Basic ${Buffer.from(`x-access-token:${token}`).toString("base64")}`;

beforeEach(() => {
	process.env.HOME = mkdtempSync(join(out, "home-"));
	gh = fakeGithub();
});
afterEach(() => {
	globalThis.fetch = realFetch;
	process.env.HOME = realHome;
});

test("device-flow sign-in keeps the refresh token and its expiry", async () => {
	gh.valid.add("ghu_1");
	const it = new Integrations(mkdtempSync(join(out, "agentdir-")), mkdtempSync(join(out, "ws-")));
	it.settings; // defaults
	await it.githubLogin("ghu_1", { refresh_token: "ghr_1", expires_in: 28800, refresh_token_expires_in: 15897600, clientId: "Iv23.app" });
	const a = it.store.github;
	assert.equal(a.refreshToken, "ghr_1");
	assert.equal(a.clientId, "Iv23.app");
	assert.ok(Math.abs(a.expiresAt - (Date.now() + 8 * HOUR)) < 5000);
	assert.equal(it.summary().github.expired, false);
});

test("a pasted token (no expiry) is used as is and never refreshed", async () => {
	gh.valid.add("ghp_x");
	const it = new Integrations(mkdtempSync(join(out, "agentdir-")), mkdtempSync(join(out, "ws-")));
	await it.githubLogin("ghp_x");
	assert.equal(it.store.github.refreshToken, undefined);
	assert.equal(it.store.github.expiresAt, undefined);
	await it.repos();
	assert.equal(gh.refreshCalls, 0);
});

test("an expired token is refreshed before the call; git and $GITHUB_TOKEN get the new one", async () => {
	gh.refresh.set("ghr_1", { access_token: "ghu_2", refresh_token: "ghr_2" });
	const it = signedIn({ token: "ghu_1", refreshToken: "ghr_1", clientId: "Iv23.app", expiresAt: Date.now() - HOUR });
	await it.repos();
	assert.equal(gh.refreshCalls, 1);
	assert.equal(it.store.github.token, "ghu_2");
	assert.equal(it.store.github.refreshToken, "ghr_2");
	assert.ok(it.store.github.expiresAt > Date.now() + 7 * HOUR);
	assert.equal(process.env.GITHUB_TOKEN, "ghu_2");
	assert.equal(gitHeader(), basic("ghu_2"));
});

test("a token close to expiry is refreshed early; a fresh one is not", async () => {
	gh.valid.add("ghu_1");
	gh.refresh.set("ghr_1", { access_token: "ghu_2", refresh_token: "ghr_2" });
	const fresh = signedIn({ token: "ghu_1", refreshToken: "ghr_1", clientId: "Iv23.app", expiresAt: Date.now() + 5 * HOUR });
	await fresh.repos();
	assert.equal(gh.refreshCalls, 0);
	const dying = signedIn({ token: "ghu_1", refreshToken: "ghr_1", clientId: "Iv23.app", expiresAt: Date.now() + 10 * 60_000 });
	await dying.githubFresh();
	assert.equal(gh.refreshCalls, 1);
	assert.equal(dying.store.github.token, "ghu_2");
});

test("concurrent calls share one refresh (GitHub rotates the refresh token)", async () => {
	gh.delay = 30;
	gh.refresh.set("ghr_1", { access_token: "ghu_2", refresh_token: "ghr_2" });
	const it = signedIn({ token: "ghu_1", refreshToken: "ghr_1", clientId: "Iv23.app", expiresAt: Date.now() - HOUR });
	await Promise.all([it.repos(), it.repos(), it.githubFresh(), it.githubApi("/user")]);
	assert.equal(gh.refreshCalls, 1);
	assert.equal(it.store.github.expired, false);
});

test("a token revoked before its expiry: one refresh, then the retry succeeds", async () => {
	gh.refresh.set("ghr_1", { access_token: "ghu_2", refresh_token: "ghr_2" });
	// Not valid on the fake server although it "expires" in 5 hours.
	const it = signedIn({ token: "ghu_1", refreshToken: "ghr_1", clientId: "Iv23.app", expiresAt: Date.now() + 5 * HOUR });
	await it.repos();
	assert.equal(gh.refreshCalls, 1);
	assert.equal(it.store.github.token, "ghu_2");
});

test("a dead refresh token marks the account expired, tells the app, and stops calling GitHub", async () => {
	const it = signedIn({ token: "ghu_1", refreshToken: "ghr_dead", clientId: "Iv23.app", expiresAt: Date.now() - HOUR });
	let changes = 0;
	it.onChange = () => changes++;
	await assert.rejects(it.repos(), (e) => e instanceof GithubAuthError && e.code === "github_auth_expired");
	assert.equal(it.summary().github.expired, true);
	assert.equal(changes, 1);
	const calls = gh.apiCalls + gh.refreshCalls;
	await assert.rejects(it.repos(), GithubAuthError);
	assert.equal(gh.apiCalls + gh.refreshCalls, calls, "no more requests once expired");
	// Signing in again clears it.
	gh.valid.add("ghu_new");
	await it.githubLogin("ghu_new", { refresh_token: "ghr_new", expires_in: 28800, clientId: "Iv23.app" });
	assert.equal(it.summary().github.expired, false);
	await it.repos();
});

test("a pasted token GitHub rejects is reported as expired, not as a bare 401", async () => {
	const it = signedIn({ token: "ghp_revoked" });
	await assert.rejects(it.repos(), GithubAuthError);
	assert.equal(it.summary().github.expired, true);
});

test("a network failure while refreshing keeps the account (no false 'expired')", async () => {
	gh.refresh.set("ghr_1", { access_token: "ghu_2", refresh_token: "ghr_2" });
	const it = signedIn({ token: "ghu_1", refreshToken: "ghr_1", clientId: "Iv23.app", expiresAt: Date.now() - HOUR });
	gh.down = true;
	await assert.rejects(it.repos(), /fetch failed/);
	assert.equal(it.store.github.expired, undefined);
	assert.equal(it.store.github.refreshToken, "ghr_1");
	// githubFresh never throws (it runs before git commands and on a timer).
	await it.githubFresh();
	gh.down = false;
	await it.repos();
	assert.equal(it.store.github.token, "ghu_2");
});

test("signing out during a refresh doesn't resurrect the old account", async () => {
	gh.delay = 30;
	gh.refresh.set("ghr_1", { access_token: "ghu_2", refresh_token: "ghr_2" });
	const it = signedIn({ token: "ghu_1", refreshToken: "ghr_1", clientId: "Iv23.app", expiresAt: Date.now() - HOUR });
	const pending = it.githubToken().catch((e) => e);
	await it.githubLogout();
	const r = await pending;
	assert.ok(r instanceof Error);
	assert.equal(it.store.github, undefined);
});

test("cleanup", () => rmSync(out, { recursive: true, force: true }));
