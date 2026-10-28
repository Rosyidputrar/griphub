// Preloaded into a test host (node --import) by the app's Dart tests (test/support/daemon.dart): sends GripHub
// Router's chat completions to a test model at GRIPHUB_TEST_ROUTER (an OpenAI-compatible base URL), and answers the
// router's other endpoints (account, rates) with a 404 so they never reach the test model. The provider lock stays as
// it is: the host still talks to the one canonical URL, only fetch underneath it is pointed elsewhere.
const ROUTER = "https://griphubrouter.web.id/v1";
const target = process.env.GRIPHUB_TEST_ROUTER;
const realFetch = globalThis.fetch;

globalThis.fetch = async (input, init) => {
	const url = typeof input === "string" ? input : input instanceof URL ? input.href : input.url;
	if (!target || !url.startsWith(ROUTER)) return realFetch(input, init);
	const path = url.slice(ROUTER.length);
	if (!path.startsWith("/chat/completions")) return new Response('{"error":"not found"}', { status: 404 });
	return realFetch(`${target.replace(/\/+$/, "")}${path}`, init);
};
