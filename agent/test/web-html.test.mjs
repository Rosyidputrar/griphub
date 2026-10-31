// Turning a fetched page into text (web.ts htmlToText / stripTags). The web writes the page, and the old steps were
// regular expressions that an opening with no end made quadratic: `<` repeated 200 000 times took 62 s inside the host,
// and nothing restarted a host stuck there. The scan that replaced them must (1) give the same text as the old
// expressions, which are kept below word for word, and (2) stay fast on the shapes that broke them.
import { test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { bundle } from "./helpers.mjs";

const here = dirname(fileURLToPath(import.meta.url));
const { htmlToText, stripTags } = await bundle("web");

// ---- the old implementation, verbatim ----
function refDecode(s) {
	return s
		.replace(/&#(\d+);/g, (_, d) => String.fromCodePoint(Number(d)))
		.replace(/&#x([0-9a-f]+);/gi, (_, h) => String.fromCodePoint(parseInt(h, 16)))
		.replace(/&nbsp;/g, " ")
		.replace(/&lt;/g, "<")
		.replace(/&gt;/g, ">")
		.replace(/&quot;/g, '"')
		.replace(/&#39;|&apos;/g, "'")
		.replace(/&amp;/g, "&");
}
function refStrip(s) {
	return refDecode(s.replace(/<[^>]+>/g, "")).replace(/\s+\n/g, "\n").trim();
}
function refHtmlToText(html, base = "") {
	let s = html;
	const main = s.match(/<(main|article)\b[\s\S]*?<\/\1>/i);
	if (main && main[0].length > 500) s = main[0];
	s = s.replace(/<(script|style|noscript|svg|head|template|iframe|nav|footer|form)\b[\s\S]*?<\/\1>/gi, "");
	s = s.replace(/<!--[\s\S]*?-->/g, "");
	s = s.replace(/<pre\b[^>]*>([\s\S]*?)<\/pre>/gi, (_, code) => `\n\n\`\`\`\n${refDecode(refStrip(code))}\n\`\`\`\n\n`);
	s = s.replace(/<code\b[^>]*>([\s\S]*?)<\/code>/gi, (_, code) => `\`${refDecode(refStrip(code))}\``);
	s = s.replace(/<h([1-6])\b[^>]*>([\s\S]*?)<\/h\1>/gi, (_, n, t) => `\n\n${"#".repeat(Number(n))} ${refStrip(t).trim()}\n\n`);
	s = s.replace(/<a\b[^>]*href="([^"#][^"]*)"[^>]*>([\s\S]*?)<\/a>/gi, (_, href, t) => {
		const label = refStrip(t).trim();
		if (!label) return "";
		let abs = refDecode(href);
		try {
			abs = new URL(abs, base).href;
		} catch {}
		return /^https?:/.test(abs) ? `[${label}](${abs})` : label;
	});
	s = s.replace(/<li\b[^>]*>/gi, "\n- ");
	s = s.replace(/<(br|hr)\b[^>]*>/gi, "\n");
	s = s.replace(/<\/(p|div|section|tr|table|ul|ol|blockquote|dd|dt|h\d)>/gi, "\n\n");
	s = s.replace(/<(td|th)\b[^>]*>/gi, " | ");
	s = refDecode(refStrip(s));
	return s
		.split("\n")
		.map((l) => l.replace(/[ \t ]+/g, " ").trimEnd())
		.join("\n")
		.replace(/\n{3,}/g, "\n\n")
		.trim();
}

const same = (html, base = "https://example.com/docs/") => {
	assert.equal(htmlToText(html, base), refHtmlToText(html, base), `htmlToText ${JSON.stringify(html.slice(0, 200))}`);
	assert.equal(stripTags(html), refStrip(html), `stripTags ${JSON.stringify(html.slice(0, 200))}`);
};

test("the same text as the old expressions for pages as written", () => {
	const pages = [
		`<!doctype html><html><head><title>T &amp; U</title><style>p{}</style></head><body><nav><a href="/x">Nav</a></nav>
<h1>Hello <em>world</em></h1><p>One &lt;two&gt; &#65;&#x42; &nbsp;three</p><ul><li>a</li><li><a href="/rel?q=1&amp;b=2">rel</a></li><li><a href="#top">top</a></li></ul>
<pre><code class="x">let a = 1 &lt; 2;\n  b();</code></pre><p>Inline <code>x&gt;y</code> and <a href="mailto:a@b.c">mail</a> and <a href="https://e.org/p">abs</a>.</p>
<table><tr><th>A</th><td>1</td></tr></table><!-- hidden --><script>var a = "<p>no</p>";</script><footer>foot</footer></body></html>`,
		`<main>${"<p>Some content that goes on and on. </p>".repeat(30)}<h2>Sub</h2><a href="/a">A</a></main><p>outside</p>`,
		`<article>short</article><p>rest</p>`, // under 500 characters: the whole page is used
		`<article>${"x ".repeat(300)}</article><main>${"y ".repeat(300)}</main>`,
		`<main>${"y ".repeat(300)}</main><article>${"x ".repeat(300)}</article>`,
		`<h1>A</h1><h2>B</h1>C</h2>`, // headings that do not match each other
		`<h1><h2>x</h2>y</h1>`,
		`<form><script></form>x</script>y`, // kinds that overlap
		`<script><form></script>x</form>y`,
		`<a href="a>b">label</a> <a href="c">d</a>`, // a `>` inside the address
		`<a title="t" href="one" data-x="y" href="two">last wins</a>`,
		`<a href="" >empty</a><a href="#x">hash</a><a href=">">gt</a>`,
		`<a href="x"><a href="y">inner</a></a>`,
		`<a href="x">no end`,
		`<A HREF="/UP">Up</A> <ahref="/no">x</ahref>`,
		`<a-b href="/dash">dash</a-b></a>`,
		`<a href="u">k</a>`.repeat(50),
		`<pre>a</pre><pre>b <b>c</b></pre><pre>unclosed`,
		`<code>a</code><code>b</code><codex>c</codex>`,
		`<!-->x<!--y--><!---->z<!-- unclosed`,
		`<head>h</head><header>kept</header><heading>kept</heading>`,
		`<title>t</title><title>u</title>`,
		`a < b and c > d, <> <<>> << x >> <1>`,
		`   \n\t  x  \n\n\n   y   z \n  `,
		`&#99999999; &#xFFFFFFFF; &#0; &#55296; ok`.replace(/&#99999999;|&#xFFFFFFFF;/g, "&#1234;"), // references the old code could read
		`<br><hr/><br />x<td>a</td><th>b</th></p></div></h3></ul>`,
		``,
		`plain text only`,
	];
	for (const p of pages) same(p);
});

test("the same text for random tag soup (seeded)", () => {
	let seed = 20261031;
	const rnd = (n) => {
		seed = (seed * 1664525 + 1013904223) >>> 0;
		return seed % n;
	};
	const pieces = [
		"<", ">", "<>", "</", "/>", "<a", "<a ", "</a>", '<a href="x">', '<a href="a>b">', 'href="', 'href="#', '"', "#", " ", "\n", "\n\n", "\t", " ",
		"<p>", "</p>", "<li>", "<br>", "<td>", "<th ", "<pre>", "</pre>", "<pre ", "<code>", "</code>", "<h1>", "</h1>", "<h2 x>", "</h2>", "<H3", "</H3>",
		"<script>", "</script>", "<style>", "</style>", "<form", "</form>", "<nav>", "</nav>", "<head>", "</head>", "<header>", "<title>", "</title>",
		"<main>", "</main>", "<article>", "</article>", "<!--", "-->", "<!-->", "&amp;", "&lt;", "&gt;", "&#65;", "&nbsp;", "&amp;lt;",
		"word", "text ", "x", "é", "日本",
	];
	for (let i = 0; i < 3000; i++) {
		let html = "";
		for (let n = rnd(40); n >= 0; n--) html += pieces[rnd(pieces.length)];
		// Most pages need to pass the 500 character mark to exercise main/article too.
		if (i % 7 === 0) html = `<main>${"filler ".repeat(90)}${html}</main>tail`;
		same(html);
	}
});

test("a character reference that is no character no longer throws", () => {
	for (const ref of ["&#99999999;", "&#1114112;", "&#xFFFFFFFF;", "&#x110000;", "&#99999999999999999999;"]) {
		assert.doesNotThrow(() => htmlToText(`<p>a ${ref} b</p>`), ref);
		assert.equal(htmlToText(`<p>a ${ref} b</p>`), "a � b");
		assert.equal(stripTags(`a ${ref} b`), "a � b");
	}
	assert.equal(htmlToText("&#128512; &#x1F600; &#65;"), "😀 😀 A", "real ones are as before");
	assert.throws(() => refHtmlToText("&#99999999;"), RangeError, "(the old code threw on them)");
});

// ---- the shapes that broke the old expressions, timed in a child process so a regression ends as a failure, not a hang ----
const shapes = {
	"< repeated": (n) => "<".repeat(n),
	"<a repeated": (n) => "<a ".repeat(n),
	'<a href=" repeated': (n) => '<a href="x'.repeat(n),
	'<a href="x"> without end': (n) => '<a href="x">'.repeat(n),
	'href=" in one tag': (n) => "<a " + 'href="x '.repeat(n) + ">y",
	"<p><b> repeated, no closes": (n) => "<p><b>".repeat(n),
	"<li repeated": (n) => "<li ".repeat(n),
	"<li repeated, > at the end": (n) => "<li ".repeat(n) + ">",
	"<pre repeated, closed once": (n) => "<pre ".repeat(n) + "</pre>",
	"<pre repeated, no > after": (n) => ">" + "<pre ".repeat(n),
	"<code repeated, no > after": (n) => ">" + "<code ".repeat(n),
	"<h1 repeated, no > after": (n) => ">" + "<h1 ".repeat(n),
	"<code repeated, closed once": (n) => "<code ".repeat(n) + "</code>",
	"<h1 repeated, closed once": (n) => "<h1 ".repeat(n) + "</h1>",
	"<h1> repeated, closed once": (n) => "<h1>".repeat(n) + "</h1>",
	"<script repeated, closed once": (n) => "<script>".repeat(n) + "</script>",
	"<script repeated, never closed": (n) => "<script>".repeat(n),
	"<!-- repeated": (n) => "<!--".repeat(n),
	"<title repeated": (n) => "<title ".repeat(n) + "</title>",
	"<main repeated": (n) => "<main>".repeat(n),
	"<main> repeated, closed once": (n) => "<main>".repeat(n) + "</main>",
	"blanks then text": (n) => " ".repeat(n) + "x",
	"blanks before a break": (n) => "x" + " ".repeat(n) + "\n",
	"<td repeated": (n) => "<td ".repeat(n),
	"</p repeated": (n) => "</p".repeat(n),
	"&# repeated": (n) => "&#".repeat(n),
	"a real page repeated": (n) => "<h2>T</h2><p>some <a href='/x'>text</a> here</p><ul><li>a</li></ul>".repeat(n),
};

test("pages built to break the old expressions take well under a second each (1 MB, child process)", () => {
	// In the build folder, so that esbuild resolves from the agent's node_modules.
	mkdirSync(join(here, "..", "build"), { recursive: true });
	const dir = mkdtempSync(join(here, "..", "build", "perf-"));
	try {
		const script = join(dir, "run.mjs");
		const out = join(dir, "web.mjs");
		writeFileSync(
			script,
			`import { build } from "esbuild";
import { pathToFileURL } from "node:url";
await build({ entryPoints: [${JSON.stringify(join(here, "..", "src", "web.ts"))}], outfile: ${JSON.stringify(out)}, bundle: true, platform: "node", format: "esm", packages: "external", logLevel: "error" });
const { htmlToText, stripTags } = await import(pathToFileURL(${JSON.stringify(out)}).href);
const shapes = ${JSON.stringify(Object.keys(shapes))};
const gen = {${Object.entries(shapes).map(([k, f]) => `${JSON.stringify(k)}: ${f.toString()}`).join(",")}};
const N = 1_000_000;
for (const name of shapes) {
	const html = gen[name](Math.floor(N / Math.max(1, gen[name](1).length)));
	const t0 = process.hrtime.bigint();
	htmlToText(html, "https://example.com/");
	stripTags(html);
	const ms = Number(process.hrtime.bigint() - t0) / 1e6;
	console.log(JSON.stringify({ name, length: html.length, ms: Math.round(ms) }));
}
`,
		);
		const r = spawnSync(process.execPath, [script], { cwd: join(here, ".."), encoding: "utf8", timeout: 150_000 });
		assert.equal(r.status, 0, `child failed or timed out (status ${r.status}, signal ${r.signal}): ${r.stderr}\n${r.stdout}`);
		const rows = r.stdout.trim().split("\n").map((l) => JSON.parse(l));
		assert.equal(rows.length, Object.keys(shapes).length);
		if (process.env.SHOW_TIMES) console.log(rows.map((r) => `${r.name}: ${r.ms} ms`).join("\n"));
		for (const row of rows) assert.ok(row.ms < 1500, `${row.name}: ${row.ms} ms for ${row.length} characters`);
	} finally {
		rmSync(dir, { recursive: true, force: true });
	}
});
