/// GripHub Router pricing, hardcoded from the public #pricing calculator
/// snapshot of 25 Oct 2026.
///
/// The router has no pricing API (its /v1/models catalog carries no prices),
/// so these rates are the only way to turn pi's token counts into money.
/// Unit: credits per 1,000,000 tokens, input + output COMBINED, exactly as
/// the calculator quotes them. Costs computed from this table are therefore
/// ESTIMATES: the calculator page itself says actual usage follows the
/// dashboard, and these rates go stale if the router changes its prices.
/// The exact numbers always live in /v1/credits (see the Usage credit card).
///
/// Image models are deliberately NOT in this table: GPT Image and Gemini
/// 3.1 Flash Image are priced per image (4 and 2.5 credits per image),
/// not per token, so they cannot feed a token-based computation.
///
/// Maintenance: re-check against https://griphubrouter.web.id/#pricing
/// whenever the router changes prices or adds models, and update the
/// "prices as of" date shown in the Usage screen footnote.
library;

/// Rupiah value of one GripHub credit (25 Oct 2026).
const double kRupiahPerCredit = 300;

/// Credits per 1M tokens (input + output combined), keyed by router slug.
const Map<String, double> kGripHubRatesPerMillion = {
  // GPT
  'gpt-5.6-luna': 0.3,
  'gpt-5.6-sol': 3.5,
  'gpt-5.6-terra': 2,
  'gpt-5.3-codex': 1.6,
  'gpt-6-astra': 5,
  'gpt-6-astra-ultrafast': 16,
  'gpt-6-luna': 0.3,
  'gpt-6-sol': 3.5,
  'gpt-6.1-sol': 2,
  'gpt-6.1-sol-ultrafast': 7,
  // Claude
  'claude-haiku-5.5': 1,
  'claude-sonnet-5.5': 2.5,
  'claude-opus-5.5': 4,
  'claude-haiku-4.5': 1,
  'claude-sonnet-5': 2.5,
  'claude-sonnet-5-alt': 2.5, // router alias of sonnet-5
  'claude-opus-4.5': 4,
  'claude-opus-4.6': 4,
  'claude-opus-4.7': 4,
  'claude-opus-4.8': 4,
  'claude-opus-5': 4,
  'claude-fable-5': 8,
  'claude-fable-5.1': 8,
  // DeepSeek
  'deepseek-v4-flash': 0.3,
  'deepseek-v4-pro': 1,
  'deepseek-v4.1-flash': 0.3,
  'deepseek-v4.1-flash-sg': 0.4,
  // GLM
  'glm-5.1': 1,
  'glm-5.2': 1.5,
  'glm-5.3': 1.5,
  'glm-5.3-flash': 0.5,
  'glm-5.3-flashx': 1,
  // Gemini
  'gemini-3.1-pro': 2,
  'gemini-3.8-flash': 1.5,
  'gemini-4-argon': 4,
  // Kimi
  'kimi-k2.6': 1,
  'kimi-k2.7-code': 1,
  'kimi-k3': 1.5,
  'kimi-k3.1-pro': 2,
  // Qwen
  'qwen-3.8-flash': 0.5,
  // Grok
  'grok-4.6': 1,
  'grok-4.7': 1,
  // Muse
  'muse-wonder': 3,
  'muse-wonder-1.0': 3,
  'muse-spark-1.2': 1,
  'muse-spark-1.3': 1,
  // MiniMax
  'minimax-m2.7': 0.5,
  'minimax-m3': 0.5,
  // Hy
  'hy3': 0.5,
  'hy4': 0.5,
  // MiMo
  'mimo-v2.6': 0.5,
  'mimo-v2.6-flash': 0.5,
  'mimo-v2.6-pro': 1.5,
  // Veo
  'veo-3.1': 2,
};

String _norm(String s) => s.trim().toLowerCase().replaceAll(RegExp(r'[.\-_]'), '');

final Map<String, double> _ratesByNorm = {
  for (final e in kGripHubRatesPerMillion.entries) _norm(e.key): e.value,
};

/// Credits-per-1M-tokens rate for a model slug, or null when the model is
/// not in the table. Never invent a rate: unknown models show no cost.
double? rateForModel(String model) => _ratesByNorm[_norm(model)];

/// Estimated cost in credits for a usage row, or null when the model has
/// no known rate.
double? estimatedCredits({
  required String model,
  required num inputTokens,
  required num outputTokens,
}) {
  final rate = rateForModel(model);
  if (rate == null) return null;
  return rate * (inputTokens + outputTokens) / 1000000;
}

/// Compact credit formatting: adaptive decimals, trailing zeros trimmed.
/// 0.10545 -> "0.105", 0.0079 -> "0.0079", 658.69 -> "659".
String formatCredits(num v) {
  if (v == 0) return '0';
  final abs = v.abs();
  final digits = abs >= 100 ? 0 : abs >= 1 ? 2 : abs >= 0.01 ? 3 : 4;
  var s = v.toStringAsFixed(digits);
  if (s.contains('.')) {
    s = s.replaceAll(RegExp(r'\.?0+$'), '');
    if (s.endsWith('.')) s = s.substring(0, s.length - 1);
  }
  return s;
}
