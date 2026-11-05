/// The model board as the host reports it (`model_rank` and `model_status`, agent/src/modelboard.ts): which models
/// people use on GripHub Router, and which of them work now. Pure parsing, so the screen can be tested without a host.
///
/// The host has already cut the router's responses down (bars are [ok, fail, level] triples) and refused any answer for
/// a period or window other than the one asked; this reads defensively anyway, and keeps a missing number null so the
/// screen can show "—" instead of a made-up 0.
library;

num? _n(Object? v) => v is num && v.isFinite ? v : null;
int _i(Object? v) => v is num && v.isFinite ? v.round().clamp(0, 1 << 52) : 0;
String? _s(Object? v) => v is String && v.isNotEmpty ? v : null;
Map<String, dynamic> _map(Object? v) => v is Map ? v.cast<String, dynamic>() : const {};
List<Map<String, dynamic>> _list(Object? v) =>
    [for (final e in (v is List ? v : const [])) if (e is Map) e.cast<String, dynamic>()];

/// Periods and windows the host accepts, in the order the screen offers them.
/// (The host also accepts 'today'; a day and the last 24 hours differ too little to need two tabs.)
const rankPeriods = ['24h', '7d', '14d', '30d', 'all'];
const statusWindows = ['6h', '24h', '7d'];

/// A board and when the host got it; [stale] when the router failed and this is the last good copy.
class Served<T> {
  const Served(this.board, this.fetchedAt, {this.stale = false, this.error});
  final T board;
  final DateTime fetchedAt;
  final bool stale;
  final String? error;
}

class RankRow {
  RankRow(Map<String, dynamic> j)
    : model = _s(j['model']) ?? '',
      name = _s(j['name']),
      requests = _i(j['requests']),
      tokens = _i(j['tokens']),
      images = _i(j['images']),
      imageRequests = _i(j['imageRequests']),
      lastUsedAt = DateTime.tryParse(_s(j['lastUsedAt']) ?? '');
  final String model;

  /// The router's display name; null for the models it does not name (image models).
  final String? name;
  final int requests;
  final int tokens;
  final int images;
  final int imageRequests;
  final DateTime? lastUsedAt;

  /// An image model: most of its requests were for pictures. Not "no tokens": the router still counts a few for them
  /// (gemini-3.1-flash-image had 2,008 in a week and 464,722 in a month), and a text model that once made a picture
  /// (gemini-4-argon made 1 among 24,768 requests) is still a text model.
  bool get isImage => imageRequests > 0 && imageRequests * 2 >= requests;
}

class RankBoard {
  RankBoard(Map<String, dynamic> j)
    : period = _s(j['period']) ?? '',
      rows = [for (final r in _list(j['rows'])) RankRow(r)].where((r) => r.model.isNotEmpty).toList();
  final String period;

  /// Most tokens first, as the router sends them.
  final List<RankRow> rows;

  /// What the whole board used, for each row's share.
  int get totalTokens => rows.fold(0, (a, r) => a + r.tokens);
  int get totalRequests => rows.fold(0, (a, r) => a + r.requests);
}

/// How a model is doing, as the router judges it.
enum ModelState {
  up,
  degraded,
  down,

  /// Too little traffic to judge.
  quiet,
  unknown;

  static ModelState parse(Object? v) => switch (v) {
    'up' => up,
    'degraded' => degraded,
    'down' => down,
    'quiet' => quiet,
    _ => unknown,
  };
}

/// One bar of the strip: a slice of time ([StatusModel.barMs] long) and how it went.
enum BarLevel { none, ok, partial, down }

class StatusBar {
  const StatusBar(this.ok, this.fail, this.level);
  final int ok;
  final int fail;
  final BarLevel level;
}

class StatusError {
  StatusError(Map<String, dynamic> j) : category = _s(j['category']) ?? '', count = _i(j['count']);
  final String category;
  final int count;
}

class StatusModel {
  StatusModel(Map<String, dynamic> j, {required this.barMs})
    : model = _s(j['model']) ?? '',
      name = _s(j['name']) ?? _s(j['model']) ?? '',
      state = ModelState.parse(j['state']),
      active = j['active'] == true,
      lastSeenAt = DateTime.tryParse(_s(j['lastSeenAt']) ?? ''),
      requests = _i(j['requests']),
      successRate = _n(j['successRate'])?.toDouble(),
      recentSuccessRate = _n(j['recentSuccessRate'])?.toDouble(),
      latencyP50Ms = _n(j['latencyP50Ms'])?.round(),
      latencyP95Ms = _n(j['latencyP95Ms'])?.round(),
      ttftP50Ms = _n(j['ttftP50Ms'])?.round(),
      tokensPerSecond = _n(j['tokensPerSecond'])?.toDouble(),
      emptyResponses = _i(j['emptyResponses']),
      errors = [for (final e in _list(j['errors'])) StatusError(e)].where((e) => e.category.isNotEmpty).toList(),
      barsFrom = DateTime.tryParse(_s(j['barsFrom']) ?? ''),
      bars = [
        for (final b in (j['bars'] is List ? j['bars'] as List : const []))
          if (b is List && b.length >= 3)
            StatusBar(_i(b[0]), _i(b[1]), BarLevel.values[_i(b[2]).clamp(0, BarLevel.values.length - 1)]),
      ];
  final String model;
  final String name;
  final ModelState state;

  /// Taking traffic lately; a model can be "down" only because nobody uses it any more.
  final bool active;
  final DateTime? lastSeenAt;
  final int requests;
  final double? successRate;

  /// Success over the latest bars only; null when there was none.
  final double? recentSuccessRate;
  final int? latencyP50Ms;
  final int? latencyP95Ms;
  final int? ttftP50Ms;
  final double? tokensPerSecond;
  final int emptyResponses;
  final List<StatusError> errors;
  final DateTime? barsFrom;
  final List<StatusBar> bars;
  final int barMs;

  /// Worth showing by default: in use, or failing.
  bool get relevant => active || state == ModelState.down || state == ModelState.degraded;

  /// The start of bar [i].
  DateTime? barStart(int i) => barsFrom?.add(Duration(milliseconds: barMs * i));
}

class StatusBoard {
  StatusBoard(Map<String, dynamic> j)
    : window = _s(j['window']) ?? '',
      barMs = _i(j['barMs']),
      generatedAt = DateTime.tryParse(_s(j['generatedAt']) ?? ''),
      successRate = _n(_map(j['totals'])['successRate'])?.toDouble(),
      requests = _i(_map(j['totals'])['requests']),
      failed = _i(_map(j['totals'])['fail']),
      up = _i(_map(j['summary'])['up']),
      degraded = _i(_map(j['summary'])['degraded']),
      down = _i(_map(j['summary'])['down']),
      active = _i(_map(j['summary'])['active']),
      modelCount = _i(_map(j['summary'])['models']),
      errorCategories = [for (final e in _list(j['errorCategories'])) StatusError(e)],
      models = [
        for (final m in _list(j['models'])) StatusModel(m, barMs: _i(j['barMs'])),
      ].where((m) => m.model.isNotEmpty).toList();
  final String window;
  final int barMs;
  final DateTime? generatedAt;
  final double? successRate;
  final int requests;
  final int failed;
  final int up;
  final int degraded;
  final int down;
  final int active;
  final int modelCount;
  final List<StatusError> errorCategories;
  final List<StatusModel> models;

  /// What to look at first: what is wrong and in use, then what is wrong and not, then the rest by traffic.
  ///
  /// [relevantOnly] leaves out the models the router marks not active, unless they are failing: a model that is down
  /// is worth a line whether or not it is "active" (Grok 4.7 was, with 10% of its requests succeeding). The router does
  /// not say what "active" means, and it is not simply "seen lately", so the screen shows the flag and claims no more.
  List<StatusModel> ordered({bool relevantOnly = false}) {
    int rank(StatusModel m) => switch (m.state) {
      ModelState.down when m.active => 0,
      ModelState.degraded when m.active => 1,
      ModelState.down || ModelState.degraded => 2,
      ModelState.unknown => 3,
      ModelState.up => 4,
      ModelState.quiet => 5,
    };
    final list = [for (final m in models) if (!relevantOnly || m.relevant) m];
    list.sort((a, b) {
      final r = rank(a).compareTo(rank(b));
      return r != 0 ? r : b.requests.compareTo(a.requests);
    });
    return list;
  }
}

Served<RankBoard> parseServedRank(Map<String, dynamic> j) => Served(
  RankBoard(_map(j['board'])),
  DateTime.fromMillisecondsSinceEpoch(_i(j['fetchedAt'])),
  stale: j['stale'] == true,
  error: _s(j['error']),
);

Served<StatusBoard> parseServedStatus(Map<String, dynamic> j) => Served(
  StatusBoard(_map(j['board'])),
  DateTime.fromMillisecondsSinceEpoch(_i(j['fetchedAt'])),
  stale: j['stale'] == true,
  error: _s(j['error']),
);
