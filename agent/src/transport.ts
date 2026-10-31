/**
 * How the host talks to the app.
 *
 * On the phone the host is a child process of the app and talks over stdin/stdout. On a server it runs as a daemon that
 * outlives any connection and listens on a unix socket; the app reaches it through `ssh host griphub-attach`. This
 * file is the part both share: a [Hub] that sends the host's records to whoever is connected, answers their commands,
 * and, in daemon mode, keeps a ring buffer of recent records so a client that dropped can pick up where it left off.
 *
 * Daemon mode protocol, on top of the usual JSONL commands and records:
 *
 *   host -> app   {"type":"hello_server","protocol":1,"mode":"server","epoch":"a1b2c3","seq":1042,"firstSeq":900,...}
 *                 {"type":"ready","version":"..."}
 *   app  -> host  {"id":1,"type":"resume","since":1040,"epoch":"a1b2c3"}    // or "since": null for "from now on"
 *   host -> app   {"seq":1041,...}, {"seq":1042,...}                      // what was missed, in order
 *   host -> app   {"type":"response","id":1,"ok":true,"data":{"replayed":2,"gap":false,"seq":1042,"epoch":"a1b2c3"}}
 *   ... then live records, each with the next seq.
 *
 * Nothing is pushed to a new client until it sends `resume`, so replayed and live records never overlap. If the
 * client's `since` is no longer in the buffer, or comes from another daemon instance (different epoch), the response
 * says `"gap":true` and replays nothing: the client must reload its state (`state`, `messages`, `approvals_pending`).
 *
 * Only one client is connected at a time. A newer connection replaces the older one, which is told `kicked`.
 *
 * Adapted from CoderRa's server mode (seseegy/coderra, agent/src/transport.ts); see server_agent.md.
 */

import { randomBytes } from "node:crypto";
import { chmodSync, lstatSync, mkdirSync, rmSync } from "node:fs";
import net from "node:net";
import { dirname } from "node:path";
import { errorCode } from "./fs.js";

export const PROTOCOL = 1;

/**
 * Records worth replaying to a client that missed them. Everything else is live-only: auth prompts, pings, and
 * `subagent_event`, the per-delta stream of every subagent. Those come by the thousand while several subagents work
 * and would push the chat out of the buffer; after a reconnect the app re-reads the subagents whole from
 * `subagent_list` instead (their tool calls and status are in the record).
 */
export const REPLAYED_TYPES = new Set([
	"event",
	"approval",
	"approval_dismiss",
	"task",
	"runs",
	"run_finished",
	"agent_done",
	"dev_server",
	"tunnel",
	"notice",
	"state",
	"error",
	"mcp",
	"subagent_started",
	"subagent_status",
	"subagent_queued",
	"subagent_finished",
	"subagent_approval_request",
	"subagent_approval_dismiss",
	"job",
	"integrations",
	"sync",
	"models_changed",
]);

// A machine-readable reason carried by an error (`ENOENT`, `github_auth_expired`, ...), for the response's `code`.
export { errorCode };

// ---------------------------------------------------------------------------
// Lines

/**
 * Splits a text stream into JSONL lines on LF only (readline would also split on U+2028/U+2029, which JSON allows).
 *
 * The unfinished line is kept as the chunks that made it, joined once when its newline arrives, and a newline is looked
 * for only in the chunk that came. It used to be one string that every chunk was appended to and searched again from the
 * start: a message of 24 MB (a few phone photos, arriving 64 KB at a time) took 8 s of the host's one thread, 48 MB took
 * 28 s, and the host answered no one meanwhile (pings, other chats, subagents).
 */
export class LineBuffer {
	/** The chunks of the line that has not ended yet, and how long they are together. */
	private pending: string[] = [];
	private size = 0;

	constructor(private readonly maxLine = 64 * 1024 * 1024) {}

	/** Feeds a chunk and returns the complete, non-blank lines it finished. */
	push(chunk: string): string[] {
		const out: string[] = [];
		let start = 0;
		for (let nl = chunk.indexOf("\n"); nl >= 0; nl = chunk.indexOf("\n", start)) {
			let line = this.pending.length ? this.pending.join("") + chunk.slice(start, nl) : chunk.slice(start, nl);
			this.pending = [];
			this.size = 0;
			if (line.endsWith("\r")) line = line.slice(0, -1);
			if (line.trim()) out.push(line);
			start = nl + 1;
		}
		if (start < chunk.length) {
			const rest = start === 0 ? chunk : chunk.slice(start);
			this.pending.push(rest);
			this.size += rest.length;
		}
		if (this.size > this.maxLine) throw new Error("Line too long");
		return out;
	}
}

// ---------------------------------------------------------------------------
// Hub

/** A connection the hub can write to. `write` takes one line without its newline. */
export interface Conn {
	write(line: string): void;
	close(): void;
}

export interface HubOptions {
	/** Daemon mode: number records, keep them for `resume`, say hello, ping. Off for the stdio child process. */
	replay: boolean;
	/** Runs one command from the client. Whatever it returns becomes the response `data`; a throw becomes an error. */
	handle: (cmd: Record<string, any>) => Promise<unknown>;
	/** Reported in `hello_server`. */
	mode?: string;
	hostVersion?: string;
	/** The agent bundle this host came from (its `.stamp`): the app compares it with its own to see an old server agent. */
	bundleStamp?: string;
	capacityRecords?: number;
	capacityBytes?: number;
	/** How often a connected client is pinged and checked for silence. 0 turns the timer off (tests call `tick()`). */
	pingIntervalMs?: number;
	/** A client that sent nothing (not even a ping) for this long is dropped. */
	idleTimeoutMs?: number;
	now?: () => number;
}

interface Stored {
	seq: number;
	line: string;
	bytes: number;
}

class Client {
	live: boolean;
	closed = false;
	background = false;
	lastSeen: number;

	constructor(
		readonly conn: Conn,
		live: boolean,
		now: number,
	) {
		this.live = live;
		this.lastSeen = now;
	}
}

export interface Attached {
	/** One line received from the client. */
	receive(line: string): void;
	/** The connection went away. */
	detach(): void;
}

export class Hub {
	readonly epoch: string;
	private seq = 0;
	private buf: Stored[] = [];
	private bytes = 0;
	private client: Client | null = null;
	private ready: object | null = null;
	private timer?: NodeJS.Timeout;
	private readonly now: () => number;
	private readonly capRecords: number;
	private readonly capBytes: number;
	private readonly idleMs: number;

	constructor(private readonly o: HubOptions) {
		this.epoch = randomBytes(6).toString("hex");
		this.now = o.now ?? Date.now;
		this.capRecords = o.capacityRecords ?? 5000;
		this.capBytes = o.capacityBytes ?? 20 * 1024 * 1024;
		this.idleMs = o.idleTimeoutMs ?? 45_000;
		const every = o.pingIntervalMs ?? 15_000;
		if (o.replay && every > 0) {
			this.timer = setInterval(() => this.tick(), every);
			this.timer.unref();
		}
	}

	// -------------------------------------------------------------------------
	// Sending

	/** Sends a record from the host to the connected client, and remembers it if it is worth replaying. */
	emit(record: object) {
		if (!this.o.replay) {
			this.deliver(JSON.stringify(record));
			return;
		}
		if (REPLAYED_TYPES.has((record as { type?: string }).type ?? "")) {
			const seq = ++this.seq;
			const line = JSON.stringify({ ...record, seq });
			this.store(seq, line);
			this.deliver(line);
		} else {
			this.deliver(JSON.stringify(record));
		}
	}

	/** The `ready` record. Sent to the client now (if there is one) and to every client that attaches later. */
	setReady(record: object) {
		this.ready = record;
		if (this.client) this.write(this.client, JSON.stringify(record));
	}

	private store(seq: number, line: string) {
		const bytes = Buffer.byteLength(line);
		this.buf.push({ seq, line, bytes });
		this.bytes += bytes;
		// A record bigger than the whole budget evicts itself too: it is simply never replayable.
		while (this.buf.length > this.capRecords || this.bytes > this.capBytes) {
			const old = this.buf.shift();
			if (!old) break;
			this.bytes -= old.bytes;
		}
	}

	private firstSeq(): number {
		return this.buf.length ? this.buf[0].seq : this.seq + 1;
	}

	private deliver(line: string) {
		const c = this.client;
		if (c && !c.closed && c.live) this.write(c, line);
	}

	private write(c: Client, line: string) {
		if (c.closed) return;
		try {
			c.conn.write(line);
		} catch {
			this.drop(c);
		}
	}

	private drop(c: Client) {
		if (c.closed) return;
		c.closed = true;
		if (this.client === c) this.client = null;
		try {
			c.conn.close();
		} catch {
			// Already gone.
		}
	}

	// -------------------------------------------------------------------------
	// Clients

	/** A client connected. A previous one is told it was kicked and closed. */
	attach(conn: Conn): Attached {
		const prev = this.client;
		if (prev) {
			this.write(prev, JSON.stringify({ type: "kicked" }));
			this.drop(prev);
		}
		// The stdio child has one client for life and gets records from the first byte; a daemon client waits for `resume`.
		const c = new Client(conn, !this.o.replay, this.now());
		this.client = c;
		if (this.o.replay) {
			this.write(
				c,
				JSON.stringify({
					type: "hello_server",
					protocol: PROTOCOL,
					mode: this.o.mode ?? "server",
					epoch: this.epoch,
					seq: this.seq,
					firstSeq: this.firstSeq(),
					hostVersion: this.o.hostVersion,
					bundleStamp: this.o.bundleStamp,
				}),
			);
			if (this.ready) this.write(c, JSON.stringify(this.ready));
		}
		return { receive: (line) => this.receive(c, line), detach: () => this.drop(c) };
	}

	hasClient(): boolean {
		return !!this.client && !this.client.closed;
	}

	/** Whether the connected client said (in its last ping) that the app is in the background. */
	clientInBackground(): boolean {
		return !this.hasClient() || !!this.client?.background;
	}

	stats() {
		return { seq: this.seq, firstSeq: this.firstSeq(), buffered: this.buf.length, bytes: this.bytes };
	}

	/** Pings the client and drops it if it has gone quiet. Runs on a timer; public so tests can drive it. */
	tick() {
		const c = this.client;
		if (!c || c.closed) return;
		if (this.now() - c.lastSeen > this.idleMs) {
			this.drop(c);
			return;
		}
		this.write(c, JSON.stringify({ type: "ping" }));
	}

	close() {
		if (this.timer) clearInterval(this.timer);
		if (this.client) this.drop(this.client);
	}

	// -------------------------------------------------------------------------
	// Receiving

	private receive(c: Client, line: string) {
		if (c.closed) return;
		c.lastSeen = this.now();
		let cmd: Record<string, any>;
		try {
			const parsed = JSON.parse(line);
			if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) throw new Error("not an object");
			cmd = parsed;
		} catch (e) {
			this.write(c, JSON.stringify({ type: "response", ok: false, error: `Bad JSON: ${(e as Error).message}` }));
			return;
		}
		switch (cmd.type) {
			case "ping":
				c.background = cmd.background === true;
				this.write(c, JSON.stringify({ type: "pong" }));
				return;
			case "pong":
				return;
			case "resume":
				this.resume(c, cmd);
				return;
		}
		void this.run(c, cmd);
	}

	private async run(c: Client, cmd: Record<string, any>) {
		let line: string;
		try {
			const data = await this.o.handle(cmd);
			line = JSON.stringify({ type: "response", id: cmd.id, ok: true, data });
		} catch (e) {
			line = JSON.stringify({
				type: "response",
				id: cmd.id,
				ok: false,
				error: String((e as Error)?.message ?? e),
				code: errorCode(e),
			});
		}
		// If the client dropped while the command ran, the answer has nowhere to go.
		this.write(c, line);
	}

	private resume(c: Client, cmd: Record<string, any>) {
		const respond = (data: object) => this.write(c, JSON.stringify({ type: "response", id: cmd.id, ok: true, data }));
		const since = cmd.since;
		if (since !== undefined && since !== null && (!Number.isInteger(since) || since < 0)) {
			this.write(
				c,
				JSON.stringify({ type: "response", id: cmd.id, ok: false, error: "since must be a non-negative integer or null", code: "invalid_argument" }),
			);
			return;
		}
		let gap = false;
		let replayed = 0;
		if (since !== undefined && since !== null) {
			const otherDaemon = cmd.epoch !== undefined && cmd.epoch !== this.epoch;
			if (otherDaemon || since > this.seq || since + 1 < this.firstSeq()) {
				gap = true;
			} else {
				for (const r of this.buf) {
					if (r.seq <= since) continue;
					this.write(c, r.line);
					replayed++;
				}
			}
		}
		// Replay and the switch to live happen in one go, so nothing can slip in between or be sent twice.
		c.live = true;
		respond({ replayed, gap, seq: this.seq, epoch: this.epoch });
	}
}

// ---------------------------------------------------------------------------
// Restart when idle

/** `host_restart`: exit now, or as soon as nothing is in flight, and let the service manager start a fresh process. */
export class RestartGate {
	private timer?: NodeJS.Timeout;

	constructor(
		private readonly o: { isIdle: () => boolean; exit: () => void; pollMs?: number; graceMs?: number },
	) {}

	get pending(): boolean {
		return !!this.timer;
	}

	request(whenIdle: boolean): { restarting: boolean; pending?: boolean } {
		if (!whenIdle || this.o.isIdle()) {
			// Give the response a moment to leave before the process goes.
			setTimeout(() => this.o.exit(), this.o.graceMs ?? 100).unref();
			return { restarting: true };
		}
		if (!this.timer) {
			this.timer = setInterval(() => this.poll(), this.o.pollMs ?? 2000);
			this.timer.unref();
		}
		return { restarting: false, pending: true };
	}

	/** Checks whether a requested restart can go ahead. Runs on a timer; public for tests. */
	poll() {
		if (this.timer && this.o.isIdle()) {
			clearInterval(this.timer);
			this.timer = undefined;
			this.o.exit();
		}
	}

	cancel() {
		if (this.timer) clearInterval(this.timer);
		this.timer = undefined;
	}
}

// ---------------------------------------------------------------------------
// Connections

/** The host's own stdout, for the app that spawned it. */
export function stdioConn(): Conn {
	return {
		write: (line) => void process.stdout.write(`${line}\n`),
		close: () => {},
	};
}

/** A unix socket connection. A client that stops reading is dropped rather than letting its backlog grow without end. */
export function socketConn(socket: net.Socket, maxBacklog = 64 * 1024 * 1024): Conn {
	return {
		write(line) {
			if (socket.destroyed) return;
			socket.write(`${line}\n`);
			if (socket.writableLength > maxBacklog) socket.destroy();
		},
		close() {
			socket.end();
			setTimeout(() => socket.destroy(), 1000).unref();
		},
	};
}

async function isListening(path: string): Promise<boolean> {
	return new Promise((resolve) => {
		const probe = net.connect(path);
		probe.once("connect", () => {
			probe.destroy();
			resolve(true);
		});
		probe.once("error", () => resolve(false));
	});
}

/**
 * Listens on a unix socket that only this user can use (folder 0700, socket 0600). A socket file left behind by a
 * process that died is replaced; one that is still being listened on, or a path that is not a socket, is an error.
 */
export async function listenOnSocket(hub: Hub, path: string): Promise<{ close(): Promise<void> }> {
	// sockaddr_un.sun_path holds about 108 bytes on Linux.
	if (Buffer.byteLength(path) > 100) throw new Error(`The socket path is too long: ${path}`);
	mkdirSync(dirname(path), { recursive: true, mode: 0o700 });
	let existing: ReturnType<typeof lstatSync> | null = null;
	try {
		existing = lstatSync(path);
	} catch {
		// Nothing there.
	}
	if (existing) {
		if (!existing.isSocket()) throw new Error(`${path} exists and is not a socket; refusing to replace it`);
		if (await isListening(path)) throw new Error(`Another host is already listening on ${path}`);
		rmSync(path, { force: true });
	}

	const sockets = new Set<net.Socket>();
	const server = net.createServer((socket) => {
		sockets.add(socket);
		socket.setEncoding("utf8");
		socket.setNoDelay(true);
		const client = hub.attach(socketConn(socket));
		const lines = new LineBuffer();
		socket.on("data", (chunk: string) => {
			let ready: string[];
			try {
				ready = lines.push(chunk);
			} catch {
				socket.destroy();
				return;
			}
			for (const line of ready) client.receive(line);
		});
		const gone = () => {
			sockets.delete(socket);
			client.detach();
		};
		socket.on("close", gone);
		socket.on("error", gone);
	});

	// Created with the right mode from the start, so there is no moment when others could connect.
	const previousMask = process.umask(0o177);
	try {
		await new Promise<void>((resolve, reject) => {
			server.once("error", reject);
			server.listen(path, () => resolve());
		});
	} finally {
		process.umask(previousMask);
	}
	chmodSync(path, 0o600);

	return {
		close: () =>
			new Promise<void>((resolve) => {
				for (const s of sockets) s.destroy();
				server.close(() => {
					rmSync(path, { force: true });
					resolve();
				});
			}),
	};
}
