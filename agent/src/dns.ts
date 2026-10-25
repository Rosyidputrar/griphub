/**
 * App-wide DNS-over-HTTPS. ISP resolvers (e.g. Indonesia's Internet Positif)
 * answer blocked names with a block page's address, which breaks web search
 * and some model providers. Patching dns.lookup covers every connection the
 * host makes (fetch included), without touching the phone's own settings.
 */

import dns from "node:dns";
import { isIP } from "node:net";

export type DnsMode = "system" | "cloudflare" | "google" | "custom";

const ENDPOINTS: Record<Exclude<DnsMode, "system" | "custom">, string> = {
	// IP literals, so resolving the resolver never needs DNS.
	cloudflare: "https://1.1.1.1/dns-query",
	google: "https://8.8.8.8/resolve",
};

/** Plain nameservers for places that can only use classic DNS (the container). */
export const NAMESERVERS: Record<DnsMode, string[]> = {
	system: ["1.1.1.1", "8.8.8.8"],
	cloudflare: ["1.1.1.1", "1.0.0.1"],
	google: ["8.8.8.8", "8.8.4.4"],
	custom: ["1.1.1.1", "8.8.8.8"],
};

const systemLookup = dns.lookup;
let endpoint: string | null = null;
/** Hostname of a custom DoH endpoint: always resolved via system DNS (below). */
let endpointHost: string | null = null;
const cache = new Map<string, { addresses: { address: string; family: number }[]; expires: number }>();

/** Error message for a custom DoH URL, or null when it is usable. Empty means "off". */
export function validateCustomDohUrl(url: string): string | null {
	const trimmed = url.trim();
	if (!trimmed) return null;
	let parsed: URL;
	try {
		parsed = new URL(trimmed);
	} catch {
		return "Not a valid URL";
	}
	if (parsed.protocol !== "http:" && parsed.protocol !== "https:") return "DoH URL must use http(s)";
	if (!parsed.hostname) return "DoH URL needs a hostname";
	return null;
}

export function configureDns(mode: DnsMode, customUrl?: string) {
	cache.clear();
	endpoint = null;
	endpointHost = null;
	if (mode === "system") return;
	if (mode === "custom") {
		const url = customUrl?.trim() || "";
		const err = validateCustomDohUrl(url);
		if (!url || err) {
			// Never throw here: this runs on boot with the saved setting, and
			// a bad saved URL must fall back to system DNS, not kill the host.
			if (url) console.error(`[dns] ignoring invalid custom DoH URL (${err}), using system DNS`);
			return;
		}
		endpoint = url;
		endpointHost = new URL(url).hostname;
		return;
	}
	endpoint = ENDPOINTS[mode];
}

async function query(name: string, type: "A" | "AAAA") {
	const res = await fetch(`${endpoint}?name=${encodeURIComponent(name)}&type=${type}`, {
		headers: { Accept: "application/dns-json" },
		signal: AbortSignal.timeout(5000),
	});
	if (!res.ok) throw new Error(`DoH ${res.status}`);
	const body = (await res.json()) as any;
	const want = type === "A" ? 1 : 28;
	return ((body.Answer ?? []) as any[])
		.filter((a) => a.type === want)
		.map((a) => ({ address: a.data as string, family: type === "A" ? 4 : 6, ttl: a.TTL as number }));
}

async function resolve(name: string, family: number) {
	const key = `${name}/${family}`;
	const hit = cache.get(key);
	if (hit && hit.expires > Date.now()) return hit.addresses;
	const types: ("A" | "AAAA")[] = family === 6 ? ["AAAA"] : family === 4 ? ["A"] : ["A", "AAAA"];
	const found = (await Promise.all(types.map((t) => query(name, t).catch(() => [])))).flat();
	if (found.length === 0) throw new Error(`DoH: no records for ${name}`);
	const ttl = Math.max(60, Math.min(...found.map((f) => f.ttl || 300)));
	const addresses = found.map(({ address, family }) => ({ address, family }));
	cache.set(key, { addresses, expires: Date.now() + ttl * 1000 });
	return addresses;
}

/** Replaces dns.lookup once; configureDns() switches it on and off. */
export function installDohLookup() {
	(dns as any).lookup = function lookup(hostname: string, options: any, callback?: any) {
		if (typeof options === "function") {
			callback = options;
			options = {};
		}
		const opts = typeof options === "number" ? { family: options } : (options ?? {});
		// The resolver's own hostname must never go through DoH itself: the
		// fetch for the DoH query would resolve it again, unboundedly, until
		// the process runs out of memory. System DNS breaks the cycle.
		if (!endpoint || !hostname || isIP(hostname) || hostname === "localhost" || hostname.endsWith(".local") || hostname === endpointHost) {
			return (systemLookup as any).call(dns, hostname, options, callback);
		}
		resolve(hostname, Number(opts.family) || 0).then(
			(addresses) => {
				if (opts.all) callback(null, addresses);
				else callback(null, addresses[0].address, addresses[0].family);
			},
			// If the resolver itself is unreachable, fall back rather than fail.
			() => (systemLookup as any).call(dns, hostname, options, callback),
		);
	};
}
