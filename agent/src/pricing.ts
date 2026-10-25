/**
 * GripHub Router pricing, hardcoded from the public #pricing calculator
 * snapshot of 25 Oct 2026. This is the host-side mirror of
 * lib/agent/pricing.dart: the two tables MUST stay identical, because the
 * host enforces the daily budget from this table while the Usage screen
 * displays costs from the Dart one.
 *
 * The router has no pricing API (its /v1/models catalog carries no prices),
 * so these rates are the only way to turn pi's token counts into money.
 * Unit: credits per 1,000,000 tokens, input + output COMBINED, exactly as
 * the calculator quotes them. Costs computed from this table are therefore
 * ESTIMATES: the calculator page itself says actual usage follows the
 * dashboard, and these rates go stale if the router changes its prices.
 * The exact numbers always live in /v1/credits (see the Usage credit card).
 *
 * Image models are deliberately NOT in this table: GPT Image and Gemini
 * 3.1 Flash Image are priced per image, not per token, so they cannot feed
 * a token-based computation.
 *
 * Maintenance: re-check against https://griphubrouter.web.id/#pricing
 * whenever the router changes prices or adds models, and update both this
 * file and lib/agent/pricing.dart together.
 */

/** Credits per 1M tokens (input + output combined), keyed by router slug. */
const RATES_PER_MILLION: Record<string, number> = {
	// GPT
	"gpt-5.6-luna": 0.3,
	"gpt-5.6-sol": 3.5,
	"gpt-5.6-terra": 2,
	"gpt-5.3-codex": 1.6,
	"gpt-6-astra": 5,
	"gpt-6-astra-ultrafast": 16,
	"gpt-6-luna": 0.3,
	"gpt-6-sol": 3.5,
	"gpt-6.1-sol": 2,
	"gpt-6.1-sol-ultrafast": 7,
	// Claude
	"claude-haiku-5.5": 1,
	"claude-sonnet-5.5": 2.5,
	"claude-opus-5.5": 4,
	"claude-haiku-4.5": 1,
	"claude-sonnet-5": 2.5,
	"claude-sonnet-5-alt": 2.5, // router alias of sonnet-5
	"claude-opus-4.5": 4,
	"claude-opus-4.6": 4,
	"claude-opus-4.7": 4,
	"claude-opus-4.8": 4,
	"claude-opus-5": 4,
	"claude-fable-5": 8,
	"claude-fable-5.1": 8,
	// DeepSeek
	"deepseek-v4-flash": 0.3,
	"deepseek-v4-pro": 1,
	"deepseek-v4.1-flash": 0.3,
	"deepseek-v4.1-flash-sg": 0.4,
	// GLM
	"glm-5.1": 1,
	"glm-5.2": 1.5,
	"glm-5.3": 1.5,
	"glm-5.3-flash": 0.5,
	"glm-5.3-flashx": 1,
	// Gemini
	"gemini-3.1-pro": 2,
	"gemini-3.8-flash": 1.5,
	"gemini-4-argon": 4,
	// Kimi
	"kimi-k2.6": 1,
	"kimi-k2.7-code": 1,
	"kimi-k3": 1.5,
	"kimi-k3.1-pro": 2,
	// Qwen
	"qwen-3.8-flash": 0.5,
	// Grok
	"grok-4.6": 1,
	"grok-4.7": 1,
	// Muse
	"muse-wonder": 3,
	"muse-wonder-1.0": 3,
	"muse-spark-1.2": 1,
	"muse-spark-1.3": 1,
	// MiniMax
	"minimax-m2.7": 0.5,
	"minimax-m3": 0.5,
	// Hy
	"hy3": 0.5,
	"hy4": 0.5,
	// MiMo
	"mimo-v2.6": 0.5,
	"mimo-v2.6-flash": 0.5,
	"mimo-v2.6-pro": 1.5,
	// Veo
	"veo-3.1": 2,
};

function norm(s: string): string {
	return s.trim().toLowerCase().replace(/[.\-_]/g, "");
}

const RATES_BY_NORM: Record<string, number> = {};
for (const [k, v] of Object.entries(RATES_PER_MILLION)) RATES_BY_NORM[norm(k)] = v;

/**
 * Credits-per-1M-tokens rate for a model slug, or null when the model is
 * not in the table. Never invent a rate: unknown models count as zero
 * towards the budget (documented limitation; the Usage screen shows them
 * as "—" for the same reason).
 */
export function rateForModel(model: string): number | null {
	return RATES_BY_NORM[norm(model)] ?? null;
}

/** Estimated cost in credits for a usage row, or null when the model has no known rate. */
export function estimatedCredits(model: string, inputTokens: number, outputTokens: number): number | null {
	const rate = rateForModel(model);
	if (rate == null) return null;
	return (rate * (inputTokens + outputTokens)) / 1_000_000;
}
