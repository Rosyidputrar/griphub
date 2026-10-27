/// GripHub Router account data as the host reports it (`router_account`,
/// agent/src/router.ts): real balance and credits charged, today's spend,
/// recent requests with their floor, and live rates. Pure parsing, so the
/// Usage screen can be tested without a host.
library;

double _d(Object? v) => v is num ? v.toDouble() : 0;
double? _dn(Object? v) => v is num ? v.toDouble() : null;
int _i(Object? v) => v is num ? v.toInt() : 0;
String? _s(Object? v) => v is String && v.isNotEmpty ? v : null;
List<Map<String, dynamic>> _list(Object? v) =>
    [for (final e in (v is List ? v : const [])) if (e is Map) e.cast<String, dynamic>()];

class CreditBatch {
  CreditBatch(Map<String, dynamic> j) : credits = _d(j['credits']), expiresAt = DateTime.tryParse(_s(j['expiresAt']) ?? '');
  final double credits;
  final DateTime? expiresAt;
}

class ModelUsage {
  ModelUsage(Map<String, dynamic> j)
    : model = _s(j['model']) ?? '',
      requests = _i(j['requests']),
      inputTokens = _i(j['inputTokens']),
      outputTokens = _i(j['outputTokens']),
      cacheReadTokens = _i(j['cacheReadTokens']),
      cacheWriteTokens = _i(j['cacheWriteTokens']),
      images = _i(j['images']),
      credits = _d(j['credits']);
  final String model;
  final int requests;
  final int inputTokens;
  final int outputTokens;
  final int cacheReadTokens;
  final int cacheWriteTokens;
  final int images;
  final double credits;

  /// All tokens the router billed (its input already includes cache).
  int get tokens => inputTokens + outputTokens;
}

class RouterRequest {
  RouterRequest(Map<String, dynamic> j)
    : id = _i(j['id']),
      model = _s(j['model']) ?? '',
      endpoint = _s(j['endpoint']) ?? '',
      ok = j['ok'] == true,
      error = _s(j['error']),
      at = DateTime.fromMillisecondsSinceEpoch(_i(j['at'])),
      inputTokens = _i(j['inputTokens']),
      cacheReadTokens = _i(j['cacheReadTokens']),
      cacheWriteTokens = _i(j['cacheWriteTokens']),
      outputTokens = _i(j['outputTokens']),
      reasoningTokens = _i(j['reasoningTokens']),
      credits = _dn(j['credits']),
      floor = _dn(j['floor']),
      thinkingEffort = _s(j['thinkingEffort']);
  final int id;
  final String model;
  final String endpoint;
  final bool ok;
  final String? error;
  final DateTime at;
  final int inputTokens;
  final int cacheReadTokens;
  final int cacheWriteTokens;
  final int outputTokens;
  final int reasoningTokens;
  final double? credits;

  /// The per-request minimum this request was raised to, when the floor applied.
  final double? floor;
  final String? thinkingEffort;

  /// Where it came from inside the app: chat, or web search through the router.
  bool get isSearch => endpoint.endsWith('/responses') || endpoint.endsWith('/messages');
  bool get isImage => endpoint.contains('/images');
}

class Rate {
  Rate(Map<String, dynamic> j)
    : credits = _d(j['credits']),
      list = _dn(j['list']),
      promo = _s(j['promo']),
      promoEndsAt = DateTime.tryParse(_s(j['promoEndsAt']) ?? ''),
      perImage = j['perImage'] == true;
  final double credits;

  /// Normal price while a promo runs.
  final double? list;
  final String? promo;
  final DateTime? promoEndsAt;
  final bool perImage;
}

class RouterAccount {
  RouterAccount(this.json);
  final Map<String, dynamic> json;

  Map<String, dynamic> get _a => (json['account'] as Map?)?.cast<String, dynamic>() ?? const {};

  double get balance => _d(_a['balance']);
  double get granted => _d(_a['granted']);
  double get used => _d(_a['used']);
  bool get suspended => _a['suspended'] == true;
  DateTime? get suspendedUntil => DateTime.tryParse(_s(_a['suspendedUntil']) ?? '');
  double get discountRate => _d(_a['discountRate']);

  /// "user-usage" (full data) or "credits" (fallback: balance and per-model only).
  String get source => _s(_a['source']) ?? 'credits';
  DateTime get fetchedAt => DateTime.fromMillisecondsSinceEpoch(_i(_a['fetchedAt']));

  /// Active batches, soonest expiry first.
  List<CreditBatch> get batches => [for (final b in _list(_a['batches'])) CreditBatch(b)];
  CreditBatch? get nextExpiry => batches.where((b) => b.expiresAt != null).firstOrNull;

  List<ModelUsage> get byModel => [for (final m in _list(_a['byModel'])) ModelUsage(m)];

  /// Credits spent today (WIB): the router's own total plus this app's work since.
  double get spentToday => _d(json['spentToday']);

  /// Whether [spentToday] rests on the router's figure (false: local estimate only).
  bool get spentTodayReal => json['spentTodayReal'] == true;

  List<RouterRequest> get requests => [for (final r in _list(json['requests'])) RouterRequest(r)];

  Map<String, Rate> get rates => {
    for (final e in ((json['rates'] as Map?) ?? const {}).entries)
      if (e.value is Map) e.key as String: Rate((e.value as Map).cast<String, dynamic>()),
  };

  /// Credits charged per WIB day (YYYY-MM-DD), as far back as the app has seen.
  Map<String, double> get daily => {
    for (final e in ((json['daily'] as Map?) ?? const {}).entries)
      if (e.value is num) e.key as String: (e.value as num).toDouble(),
  };

  /// Days of credit left at the recent pace (null without enough history).
  double? daysLeft() {
    final d = daily.values.where((v) => v > 0).toList();
    if (d.length < 2) return null;
    final avg = d.reduce((a, b) => a + b) / d.length;
    return avg > 0 ? balance / avg : null;
  }

  /// Low when under 10% of what was granted, or under two days at the recent pace.
  bool get lowBalance {
    final left = daysLeft();
    return (granted > 0 && balance < granted * 0.1) || (left != null && left < 2);
  }
}
