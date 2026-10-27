/// GripHub credit formatting. Prices and costs are computed by the host
/// (agent/src/router.ts and pricing.ts) from the router's live rates and
/// per-request floors; the app only displays them.
library;

/// Rupiah value of one GripHub credit.
const double kRupiahPerCredit = 300;

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
