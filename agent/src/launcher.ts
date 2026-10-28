/**
 * Keeps the server's launcher files in step with the host that is running.
 *
 * `server/bootstrap.sh` installs three files outside the host's own folder: the box launcher (`bin/box`), the box's
 * Containerfile and the program the app connects through (`bin/griphub-attach`). The app's update only copies the host
 * folder, so without this a fix to one of those files reached only servers that were set up again by hand. The bundle
 * carries them in `launcher/` (build.mjs); at start the host puts any that changed where bootstrap.sh put them.
 *
 * Only files that are already there are replaced. A server set up with --no-box has no `bin/box`, and making one would
 * switch the agent's commands to a box nobody asked for. The systemd unit is not touched: changing it needs a
 * daemon-reload, which only the setup script does.
 */
import { chmodSync, existsSync, mkdirSync, readFileSync, renameSync, rmSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";

export interface LauncherFile {
	/** Name inside the bundle's `launcher/` folder. */
	name: string;
	/** Where bootstrap.sh installs it, relative to the GripHub folder (`~/.griphub`). */
	target: string;
	mode: number;
}

export const LAUNCHER_FILES: LauncherFile[] = [
	{ name: "box", target: join("bin", "box"), mode: 0o755 },
	{ name: "griphub-attach", target: join("bin", "griphub-attach"), mode: 0o755 },
	{ name: "Containerfile", target: join("box", "Containerfile"), mode: 0o644 },
];

/**
 * Replaces the installed launcher files that differ from the bundle's. Each one is written next to its target and
 * renamed over it, so a `box` that is running right now keeps reading the old file and the next call gets the new one.
 * Returns the targets that were replaced; one that cannot be written is reported to [warn] and skipped.
 */
export function syncLauncher(o: { hostDir: string; griphubDir: string; warn?: (message: string) => void }): string[] {
	const replaced: string[] = [];
	for (const f of LAUNCHER_FILES) {
		const from = join(o.hostDir, "launcher", f.name);
		const to = join(o.griphubDir, f.target);
		if (!existsSync(from) || !existsSync(to)) continue;
		const tmp = `${to}.new-${process.pid}`;
		try {
			const want = readFileSync(from);
			if (want.equals(readFileSync(to))) continue;
			mkdirSync(dirname(to), { recursive: true });
			writeFileSync(tmp, want, { mode: f.mode });
			chmodSync(tmp, f.mode);
			renameSync(tmp, to);
			replaced.push(f.target);
		} catch (e) {
			rmSync(tmp, { force: true });
			o.warn?.(`could not update ${to}: ${(e as Error).message}`);
		}
	}
	return replaced;
}
