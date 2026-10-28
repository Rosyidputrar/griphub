// Builds the host for the app's Dart tests (test/support/daemon.dart): host.ts bundled like build.mjs bundles it, with
// pi left external and resolved from agent/node_modules, into agent/build/harness/ next to a copy of the skills. Also
// builds fs_server.mjs, the fs_* commands alone over stdin/stdout (test/support/fs_server.dart).
//
//   node agent/test/build-harness.mjs
import { build } from "esbuild";
import { cpSync, mkdirSync, rmSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const out = join(here, "..", "build", "harness");
rmSync(out, { recursive: true, force: true });
mkdirSync(out, { recursive: true });
await build({
	entryPoints: [join(here, "..", "src", "host.ts")],
	outfile: join(out, "host.mjs"),
	bundle: true,
	platform: "node",
	format: "esm",
	packages: "external",
	banner: { js: 'import { createRequire as __createRequire } from "node:module"; const require = __createRequire(import.meta.url);' },
	logLevel: "error",
});
await build({
	entryPoints: [join(here, "harness", "fs_server.ts")],
	outfile: join(out, "fs_server.mjs"),
	bundle: true,
	platform: "node",
	format: "esm",
	packages: "external",
	logLevel: "error",
});
cpSync(join(here, "..", "skills"), join(out, "skills"), { recursive: true });
console.log(`test host -> ${join(out, "host.mjs")}, ${join(out, "fs_server.mjs")}`);
