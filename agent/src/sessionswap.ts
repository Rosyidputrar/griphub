/**
 * Replacing the open chat session (switching chats, a rebuild after a setting). It used to dispose the old session
 * first and build the new one after: a build that failed (a chat file that would not open, a bad MCP tool) left the host
 * holding a session that was already disposed, so the chat looked open and answered nothing until the app was
 * restarted; and two switches in a row both disposed whatever was current and built one each, so one of the two was
 * never disposed.
 *
 * Now the new session is built first, so a failure changes nothing, and one switch runs at a time.
 */

export interface Disposable {
	dispose(): void;
}

export interface Swap<S extends Disposable> {
	/** Builds the new session. It may fail: nothing has been touched yet. */
	build(): Promise<S>;
	/** Throws when the current session must not be replaced right now (a turn is running). Asked after the build, when a turn may have started meanwhile. */
	assertIdle(): void;
	/** Lets go of the current session and whatever hangs on it (its listener, its approvals, its queue). */
	retire(): void;
	/** Makes [next] the current session. */
	install(next: S): void;
}

/** One at a time, in the order asked; a task that fails does not stop the ones after it. */
export function serialQueue() {
	let tail: Promise<unknown> = Promise.resolve();
	return <T>(task: () => Promise<T>): Promise<T> => {
		const run = tail.then(task, task);
		tail = run.catch(() => {});
		return run;
	};
}

/** Builds the new session, and only then retires the current one. When anything fails the current one stays and the new one is disposed. */
export async function swapSession<S extends Disposable>(swap: Swap<S>): Promise<S> {
	const next = await swap.build();
	try {
		// A turn may have started while the new session was being built.
		swap.assertIdle();
	} catch (e) {
		next.dispose();
		throw e;
	}
	swap.retire();
	swap.install(next);
	return next;
}
