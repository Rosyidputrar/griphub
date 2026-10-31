// Loaded into every test file's process (npm test: --import). A test file whose tests have all finished but whose
// process stays alive is waiting on something nobody closed: a child process, a socket, a timer. The runner now ends such
// a process (--test-force-exit) so the run cannot sit until the CI time limit, and this says what was still open, so the
// leak gets fixed instead of hidden.
import { basename } from "node:path";

process.on("exit", () => {
	const open = process.getActiveResourcesInfo().filter((r) => r !== "TTYWrap" && r !== "PipeWrap" && r !== "FSReqCallback");
	if (open.length && process.exitCode === undefined) {
		const counts = {};
		for (const r of open) counts[r] = (counts[r] ?? 0) + 1;
		console.error(`[handles] ${basename(process.argv[1] ?? "test")} ended with ${JSON.stringify(counts)} still open (a child process that ended an instant ago, or a server that was just closed, still counts: Node lists them; a timer or socket that stays is a leak)`);
	}
});
