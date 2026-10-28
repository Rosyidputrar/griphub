/**
 * The notes pi reads at the start of every session (<agentDir>/AGENTS.md): what this machine is and how its tools
 * behave. They differ a lot between the phone (an Android shell, no sudo, a proot container) and a server (a real
 * Linux box, bash, a rootless container), and telling the model the wrong one makes it avoid things that work or try
 * things that cannot. Adapted from CoderRa's server mode (seseegy/coderra agent/src/agents-file.ts).
 *
 * The phone's text is exactly what the host wrote before server mode existed (test/agents-file.test.mjs holds it).
 */

import { BASH_TIMEOUT_SECONDS } from "./limits.js";

export const AGENTS_MARKER = "<!-- griphub:managed (delete this line to keep your own edits) -->";

export interface AgentsFileOptions {
	/** "server" for the daemon on a VPS, anything else for the phone. */
	mode: string;
	workspace: string;
	/** On a server: bash runs inside the rootless container (`box`) rather than directly on the machine. */
	box?: boolean;
}

export function agentsFileText({ mode, workspace, box = false }: AgentsFileOptions): string {
	return mode === "server" ? serverText(workspace, box) : phoneText(workspace);
}

/**
 * Whether the file is ours to rewrite. The user deletes the marker line to keep their own edits. (The host also used to
 * claim any file starting the way ours does, which made deleting the marker useless: our own text without the marker
 * starts that way too. Every file GripHub wrote carries the marker, so the marker alone decides.)
 */
export function isManaged(current: string): boolean {
	return current.includes(AGENTS_MARKER);
}

function phoneText(workspace: string): string {
	return `${AGENTS_MARKER}
# Environment

You are running inside GripHub AI Agent, an Android app, on the user's phone.

- The shell is Android's /system/bin/sh (mksh) with toybox utilities, not bash.
  Prefer POSIX sh syntax. There is no sudo, apt or pkg.
- On PATH: \`node\`, \`git\`, \`ssh\`, \`ssh-keygen\`, \`scp\`, \`rsync\`, \`curl\`, \`rg\`, \`fd\`.
  With scp, pass \`-S ssh\`.
- The workspace directory is ${workspace}. Projects live in subfolders of it.
  Keep files inside it unless asked otherwise.
- When the user has connected accounts in the app:
  - GitHub: \`$GITHUB_TOKEN\` is set and git is already authenticated for
    https://github.com (clone, pull, push work directly). Use the REST API
    with curl for everything else (issues, PRs, repos).
  - Vercel: \`$VERCEL_TOKEN\` is set for the Vercel REST API.
  - Cloudflare: \`$CLOUDFLARE_API_TOKEN\` and \`$CLOUDFLARE_ACCOUNT_ID\` are set,
    so wrangler in the Linux container works without logging in
    (\`box -c 'npx wrangler deploy'\`, D1/KV/R2 commands), as does the REST API.
  - SSH: saved servers are aliases in ~/.ssh/config, so \`ssh <name>\` works.
    The device key is ~/.ssh/id_ed25519.
- Linux container: when the user has installed one (Debian or Alpine, via
  proot), \`box -c '<command>'\` runs a command inside it, and \`box\` alone opens
  a shell. When it is enabled as your shell, every command already runs inside:
  use \`apt-get install -y\` (Debian) or \`apk add\` (Alpine) to get Python,
  Node.js, compilers and anything else. The home folder and workspace are the
  same paths inside and out.
- You have \`web_search\` and \`web_fetch\` tools. Use them before guessing how
  to install or use something, and to look up unfamiliar errors. With a
  Search1API key you also have \`web_screenshot\`, to see how a page looks
  (e.g. to check a site you built after deploying it).
- For tasks with three or more steps, call \`todo_write\` with your plan before
  starting, and keep it current (one step in_progress, each marked completed
  as soon as it is done). The user follows it in the app. In plan mode, write
  the plan as text first; call \`todo_write\` once it is approved.
- \`bash\` commands stop after ${BASH_TIMEOUT_SECONDS / 60} minutes unless you pass \`timeout\`
  (in seconds); pass a longer one for slow installs or builds.
- Dev servers: run them in the background (\`nohup npm run dev > dev.log 2>&1 &\`)
  and print the URL (e.g. http://localhost:5173); the app offers a live
  preview and a public link for any localhost port it sees.
- Some actions need the user's approval in the app; if one is declined, ask
  what they want instead rather than retrying.
- There is no display server; do not try to open GUIs or browsers. The app can
  preview HTML files you write.
- Files listed after "Attached files:" in a message are part of it. A
  \`pasted-text.txt\` there is text the user pasted into the message (the app
  attaches long pastes as files): read it before you answer.
`;
}


function serverText(workspace: string, box: boolean): string {
	const shell = box
		? `- Shell: bash runs inside an Ubuntu container as root, started for you by \`box\`. The workspace is at the same
  path inside and outside, so files are shared. Your home folder has the same path but its own contents (the git and
  ssh settings are copied in). Use \`apt-get install -y\` for anything you need (Node.js, Python, compilers,
  databases...). Installed packages stay between runs. The container is separate from the server itself, so a
  mistake in it cannot damage the server.`
		: `- Shell: bash runs directly on the server as an unprivileged user. There is no sudo, so \`apt\` is not
  available. Install tools in your home folder instead (nvm, uv, pip --user, cargo, ...).`;
	return `${AGENTS_MARKER}
# Environment

You are running inside GripHub AI Agent on a Linux server. The user talks to you from the GripHub app on their phone
and may disconnect at any time; you keep running while they are away, and they see everything when they return.

- Your file tools (read, write, edit, grep, find, ls) work directly on the server's disk.
- The workspace directory is ${workspace}. Projects live in subfolders of it. Keep files inside it unless asked
  otherwise.
${shell}
- Every bash call starts in the project folder; \`cd\` does not persist between calls. A grep exit code of 1 means
  "no matches", not an error.
- The usual tools (git, curl, rsync, ssh, rg) are installed. Check with \`command -v\` before relying on others.
- When the user has connected accounts in the app:
  - GitHub: \`$GITHUB_TOKEN\` is set and git is already authenticated for https://github.com (clone, pull, push
    work directly). Use the REST API with curl for everything else (issues, PRs, repos).
  - Vercel: \`$VERCEL_TOKEN\` is set for the Vercel REST API.
  - Cloudflare: \`$CLOUDFLARE_API_TOKEN\` and \`$CLOUDFLARE_ACCOUNT_ID\` are set, so wrangler works without logging
    in (\`npx wrangler deploy\`, D1/KV/R2 commands), as does the REST API.
  - SSH: saved servers are aliases in ~/.ssh/config, so \`ssh <name>\` works.
- You have \`web_search\` and \`web_fetch\` tools. Use them before guessing how to install or use something, and to
  look up unfamiliar errors. With a Search1API key you also have \`web_screenshot\`, to see how a page looks (e.g. to
  check a site you built after deploying it).
- For tasks with three or more steps, call \`todo_write\` with your plan before starting, and keep it current (one
  step in_progress, each marked completed as soon as it is done). The user follows it in the app. In plan mode, write
  the plan as text first; call \`todo_write\` once it is approved.
- \`bash\` commands stop after ${BASH_TIMEOUT_SECONDS / 60} minutes unless you pass \`timeout\` (in seconds); pass a longer one for slow
  installs or builds.
- Dev servers: run them in the background (\`nohup npm run dev -- --host 127.0.0.1 > dev.log 2>&1 &\`) and print the
  URL (for example http://127.0.0.1:5173). Listen on 127.0.0.1 only: the app opens the port on the phone through an
  ssh tunnel, and 0.0.0.0 would put an unfinished site on the public internet.
- Some actions need the user's approval in the app. If one is declined, ask what they want instead of retrying.
  In an unattended run (a scheduled or queued task) nobody can approve: risky commands are refused outright.
  Do not look for a way around that; finish what you safely can and say what is left.
- There is no display server; do not try to open GUIs or browsers. The app can preview HTML files you write.
- Files listed after "Attached files:" in a message are part of it. A \`pasted-text.txt\` there is text the user
  pasted into the message (the app attaches long pastes as files): read it before you answer.
`;
}
