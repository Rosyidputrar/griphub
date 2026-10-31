// web_fetch fetched any address the model or a page named, and followed redirects inside fetch: a page that said
// "go to http://169.254.169.254/..." (a cloud server's metadata service) or 127.0.0.1:<port> (a database, an admin page,
// the preview server) had the answer read back to the agent (BE-03). Every address is now looked at before it is fetched,
// on every hop.
import { test } from "node:test";
import assert from "node:assert/strict";
import { createServer } from "node:http";
import { bundle } from "./helpers.mjs";

const { isPrivateAddress, assertPublicUrl, webFetch } = await bundle("web");

test("which addresses are private", () => {
	for (const ip of [
		"127.0.0.1", "127.255.255.254", "0.0.0.0", "10.0.0.1", "10.255.255.255", "172.16.0.1", "172.31.255.255", "192.168.1.1", "169.254.169.254",
		"100.64.0.1", "100.127.255.255", "192.0.0.1", "198.18.0.1", "224.0.0.1", "255.255.255.255", "240.0.0.1",
		"::1", "::", "fe80::1", "fc00::1", "fd12:3456::1", "ff02::1", "::ffff:127.0.0.1", "::ffff:169.254.169.254", "::ffff:7f00:1", "64:ff9b::a00:1", "[::1]", "fe80::1%eth0",
	]) {
		assert.equal(isPrivateAddress(ip), true, ip);
	}
	for (const ip of ["8.8.8.8", "1.1.1.1", "172.15.255.255", "172.32.0.1", "100.63.255.255", "100.128.0.1", "169.253.0.1", "192.169.0.1", "198.20.0.1", "223.255.255.255", "2606:4700:4700::1111", "2a00:1450:4001::200e", "::ffff:8.8.8.8", "not an address"]) {
		assert.equal(isPrivateAddress(ip), false, ip);
	}
});

const resolver = (table) => async (host) => {
	if (!(host in table)) throw new Error(`ENOTFOUND ${host}`);
	return table[host];
};

test("addresses written out, names for this machine, and names that resolve to private addresses are refused", async () => {
	const resolve = resolver({ "public.example": ["93.184.216.34"], "internal.example": ["10.0.0.5"], "mixed.example": ["93.184.216.34", "127.0.0.1"], "v6.example": ["::1"] });
	for (const u of ["http://127.0.0.1:8080/", "http://169.254.169.254/latest/meta-data/", "http://[::1]/", "http://[::ffff:127.0.0.1]/", "http://2130706433/", "http://0x7f.1/", "http://localhost/", "http://app.localhost/", "http://internal.example/", "http://mixed.example/", "http://v6.example/", "http://0177.0.0.1/"]) {
		await assert.rejects(assertPublicUrl(new URL(u), resolve), /private or local/, u);
	}
	await assertPublicUrl(new URL("https://public.example/page"), resolve);
	await assertPublicUrl(new URL("http://93.184.216.34/"), resolve);
	await assert.rejects(assertPublicUrl(new URL("file:///etc/passwd"), resolve), /only fetches http and https/);
	await assert.rejects(assertPublicUrl(new URL("ftp://public.example/x"), resolve), /only fetches http and https/);
});

/** A fetch that answers from a table of [status, location|body], and remembers what it was asked. */
function fake(table) {
	const asked = [];
	const fetchFn = async (url, init) => {
		asked.push([url, init.redirect]);
		const [status, value] = table[url] ?? [404, "not found"];
		if (status >= 300 && status < 400) return new Response(null, { status, headers: { location: value } });
		return new Response(value, { status, headers: { "content-type": "text/plain" } });
	};
	return { fetchFn, asked };
}
const publicOnly = resolver({ "a.example": ["93.184.216.34"], "b.example": ["93.184.216.35"], "evil.example": ["93.184.216.36"], "rebind.example": ["10.1.2.3"] });

test("a redirect to a private address is not followed (the first hop is public)", async () => {
	for (const target of ["http://169.254.169.254/latest/meta-data/", "http://127.0.0.1:9200/", "http://[::1]/", "http://localhost:3000/", "http://rebind.example/", "file:///etc/passwd"]) {
		const { fetchFn, asked } = fake({ "https://evil.example/go": [302, target] });
		await assert.rejects(webFetch("https://evil.example/go", undefined, { fetch: fetchFn, resolve: publicOnly }), /private or local|only fetches http/, target);
		assert.equal(asked.length, 1, `${target}: the private address was never requested`);
		assert.equal(asked[0][1], "manual", "redirects are handled here, not inside fetch");
	}
});

test("redirects between public addresses are followed, relative ones too, and the page's address is the last hop", async () => {
	const { fetchFn, asked } = fake({
		"https://a.example/start": [301, "https://b.example/one"],
		"https://b.example/one": [302, "/two?x=1"],
		"https://b.example/two?x=1": [200, "hello"],
	});
	const page = await webFetch("a.example/start", undefined, { fetch: fetchFn, resolve: publicOnly });
	assert.equal(page.text, "hello");
	assert.equal(page.url, "https://b.example/two?x=1");
	assert.equal(asked.length, 3);
});

test("a loop of redirects ends", async () => {
	const { fetchFn, asked } = fake({ "https://a.example/x": [302, "https://a.example/x"] });
	await assert.rejects(webFetch("https://a.example/x", undefined, { fetch: fetchFn, resolve: publicOnly }), /stopped after 10 redirects/);
	assert.equal(asked.length, 11);
});

test("an address of this machine is refused before anything is sent (a real server that would have answered)", async () => {
	let hits = 0;
	const server = createServer((_, res) => {
		hits++;
		res.end("INTERNAL-ONLY: credentials");
	});
	await new Promise((r) => server.listen(0, "127.0.0.1", r));
	try {
		const port = server.address().port;
		for (const u of [`http://127.0.0.1:${port}/`, `http://localhost:${port}/`, `127.0.0.1:${port}`]) {
			await assert.rejects(webFetch(u), /private or local/, u);
		}
		assert.equal(hits, 0, "the server was never reached");
	} finally {
		server.close();
	}
});
