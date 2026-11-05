import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../agent/agent_controller.dart';
import '../agent/model_board.dart';
import 'errors.dart';
import 'i18n.dart';
import 'kit.dart';
import 'theme.dart';

/// The states and bar levels use the palette's own colours, so both themes keep their contrast.
Color stateColor(Palette p, ModelState s) => switch (s) {
  ModelState.up => p.success,
  ModelState.degraded => p.warning,
  ModelState.down => p.danger,
  ModelState.quiet || ModelState.unknown => p.faint,
};

String stateLabel(ModelState s) => switch (s) {
  ModelState.up => tr('Working'),
  ModelState.degraded => tr('Slow or failing'),
  ModelState.down => tr('Down'),
  ModelState.quiet => tr('Quiet'),
  ModelState.unknown => tr('Unknown'),
};

/// "98.5%", "100%", in the app's number format; "—" when the router had no figure.
String percent(double? v) {
  if (v == null) return '—';
  final t = v >= 100 ? '100' : v.toStringAsFixed(v < 10 ? 1 : (v == v.roundToDouble() ? 0 : 1));
  return '${localNumber(t)}%';
}

String _ms(int? v) {
  if (v == null) return '—';
  return v >= 1000 ? '${localNumber((v / 1000).toStringAsFixed(1))} ${tr('sec')}' : '$v ms';
}

String _compact(num n) {
  String trim(double v) => v >= 100 ? v.toStringAsFixed(0) : v.toStringAsFixed(1).replaceAll(RegExp(r'\.0$'), '');
  if (n >= 1e9) return localNumber('${trim(n / 1e9)}B');
  if (n >= 1e6) return localNumber('${trim(n / 1e6)}M');
  if (n >= 1e3) return localNumber('${trim(n / 1e3)}k');
  return localNumber('${n.round()}');
}

/// How far back a strip of [ms] reaches, as a label for its left end: "6 h ago", "24 h ago", "7 d ago". Not a clock time:
/// that would read differently by the phone's zone, and a strip's own length says what a person wants to know.
String _reach(int ms) {
  final h = (ms / 3600000).round();
  return h >= 48 ? tr('{n} d ago').replaceAll('{n}', '${(h / 24).round()}') : tr('{n} h ago').replaceAll('{n}', '$h');
}

String errorCategoryLabel(String c) => switch (c) {
  'empty_response' => tr('Empty answer'),
  'context_too_long' => tr('Context too long'),
  'out_of_quota' => tr('Out of quota upstream'),
  'invalid_request' => tr('Invalid request'),
  'capacity' => tr('No capacity'),
  'content_policy' => tr('Content policy'),
  'rate_limited' => tr('Rate limited'),
  // A category the router adds later still reads as something: "some_new_kind" -> "Some new kind".
  _ => c.isEmpty ? c : '${c[0].toUpperCase()}${c.substring(1).replaceAll('_', ' ')}',
};

/// What a strip of bars says in words: "48 bars: 2 failed, 4 partly".
String barsSummary(List<StatusBar> bars) => tr('{n} bars: {down} failed, {partial} partly')
    .replaceAll('{n}', '${bars.length}')
    .replaceAll('{down}', '${bars.where((b) => b.level == BarLevel.down).length}')
    .replaceAll('{partial}', '${bars.where((b) => b.level == BarLevel.partial).length}');

enum BoardTab { status, rank }

/// Which models work now, and which people use: the router's own numbers (agent/src/modelboard.ts).
class ModelBoardScreen extends StatefulWidget {
  const ModelBoardScreen({super.key, required this.agent, this.tab = BoardTab.status});
  final AgentController agent;
  final BoardTab tab;

  @override
  State<ModelBoardScreen> createState() => _ModelBoardScreenState();
}

class _ModelBoardScreenState extends State<ModelBoardScreen> {
  late BoardTab _tab = widget.tab;
  String _window = '24h';
  String _period = '7d';
  bool _all = false;

  Served<StatusBoard>? _status;
  Served<RankBoard>? _rank;
  Object? _statusError;
  Object? _rankError;
  bool _loadingStatus = false;
  bool _loadingRank = false;

  /// Counts reads per board, so an answer that comes back after a newer ask (another window picked, a pull over a slow
  /// first read) cannot replace it, and so a window's numbers never sit under another window's tab.
  int _statusRead = 0;
  int _rankRead = 0;

  @override
  void initState() {
    super.initState();
    _loadStatus();
    _loadRank();
  }

  Future<void> _loadStatus({bool force = false}) async {
    final window = _window;
    final read = ++_statusRead;
    setState(() {
      _loadingStatus = true;
      _statusError = null;
    });
    try {
      final s = await widget.agent.integrations.modelStatus(window, force: force);
      if (mounted && read == _statusRead) setState(() => _status = s);
    } catch (e) {
      if (mounted && read == _statusRead) setState(() => _statusError = e);
    } finally {
      if (mounted && read == _statusRead) setState(() => _loadingStatus = false);
    }
  }

  Future<void> _loadRank({bool force = false}) async {
    final period = _period;
    final read = ++_rankRead;
    setState(() {
      _loadingRank = true;
      _rankError = null;
    });
    try {
      final r = await widget.agent.integrations.modelRank(period, force: force);
      if (mounted && read == _rankRead) setState(() => _rank = r);
    } catch (e) {
      if (mounted && read == _rankRead) setState(() => _rankError = e);
    } finally {
      if (mounted && read == _rankRead) setState(() => _loadingRank = false);
    }
  }

  void _setWindow(String w) {
    if (w == _window) return;
    setState(() {
      _window = w;
      _status = null;
    });
    _loadStatus();
  }

  void _setPeriod(String p) {
    if (p == _period) return;
    setState(() {
      _period = p;
      _rank = null;
    });
    _loadRank();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Scaffold(
      appBar: AppBar(title: Text(tr('Model status'))),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: PillSegments<BoardTab>(
              value: _tab,
              options: {BoardTab.status: tr('Status'), BoardTab.rank: tr('Ranking')},
              onChanged: (t) => setState(() => _tab = t),
            ),
          ),
          BusyBar(busy: _tab == BoardTab.status ? _loadingStatus : _loadingRank),
          Expanded(
            child: RefreshIndicator(
              color: p.text,
              onRefresh: () => _tab == BoardTab.status ? _loadStatus(force: true) : _loadRank(force: true),
              child: _tab == BoardTab.status ? _statusList(context) : _rankList(context),
            ),
          ),
        ],
      ),
    );
  }

  // -------------------------------------------------------------------------- status

  Widget _statusList(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final p = context.palette;
    final s = _status;
    final board = s?.board;
    final children = <Widget>[
      Align(
        alignment: Alignment.centerLeft,
        child: PillSegments<String>(
          value: _window,
          options: {for (final w in statusWindows) w: w},
          onChanged: _setWindow,
          expand: false,
        ),
      ),
      const SizedBox(height: 12),
    ];
    if (_statusError != null && s == null) {
      children.add(SurfaceCard(child: ErrorNotice(error: _statusError, onRetry: _loadStatus)));
    } else if (board == null) {
      children.add(const Padding(padding: EdgeInsets.all(40), child: Center(child: BusySpinner.page())));
    } else {
      if (_statusError != null) children.add(_Stale(error: friendlyError(_statusError), fetchedAt: s!.fetchedAt, onRetry: _loadStatus));
      if (s!.stale) children.add(_Stale(error: s.error, fetchedAt: s.fetchedAt, onRetry: () => _loadStatus(force: true)));
      children.add(_Summary(board: board));
      final shown = board.ordered(relevantOnly: !_all);
      final hidden = board.models.length - board.ordered(relevantOnly: true).length;
      children.add(SectionLabel(tr('Models')));
      if (shown.isEmpty) {
        children.add(SurfaceCard(child: Text(tr('No models to show.'), style: text.bodySmall)));
      } else {
        children.add(
          SettingsGroup(children: [for (final m in shown) _StatusRow(model: m, board: board, key: ValueKey(m.model))]),
        );
      }
      if (hidden > 0 || _all) {
        children.add(
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: TextButton(
              onPressed: () => setState(() => _all = !_all),
              child: Text(
                _all ? tr('Show only models in use') : tr('Show {n} more').replaceAll('{n}', '$hidden'),
              ),
            ),
          ),
        );
      }
      if (board.errorCategories.isNotEmpty) {
        children.add(SectionLabel(tr('Why requests failed')));
        children.add(
          SettingsGroup(
            children: [
              for (final e in board.errorCategories.take(6))
                SettingsRow(
                  title: errorCategoryLabel(e.category),
                  trailing: Text(_compact(e.count), style: text.titleSmall?.copyWith(fontFeatures: const [FontFeature.tabularFigures()])),
                ),
            ],
          ),
        );
      }
      children.add(
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 12, 4, 0),
          child: Text(
            tr('The router\'s own figures for everyone using it, not only you. Each bar is {t}.')
                .replaceAll('{t}', _barLength(board.barMs)),
            style: text.bodySmall?.copyWith(color: p.muted),
          ),
        ),
      );
    }
    return ListView(physics: const AlwaysScrollableScrollPhysics(), padding: const EdgeInsets.fromLTRB(16, 4, 16, 32), children: children);
  }

  // -------------------------------------------------------------------------- rank

  Widget _rankList(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final p = context.palette;
    final r = _rank;
    final board = r?.board;
    const labels = {'24h': '24h', '7d': '7d', '14d': '14d', '30d': '30d', 'all': 'All'};
    final children = <Widget>[
      Align(
        alignment: Alignment.centerLeft,
        child: PillSegments<String>(
          value: _period,
          options: {for (final k in rankPeriods) k: tr(labels[k]!)},
          onChanged: _setPeriod,
          expand: false,
        ),
      ),
      const SizedBox(height: 12),
    ];
    if (_rankError != null && r == null) {
      children.add(SurfaceCard(child: ErrorNotice(error: _rankError, onRetry: _loadRank)));
    } else if (board == null) {
      children.add(const Padding(padding: EdgeInsets.all(40), child: Center(child: BusySpinner.page())));
    } else {
      if (_rankError != null) children.add(_Stale(error: friendlyError(_rankError), fetchedAt: r!.fetchedAt, onRetry: _loadRank));
      if (r!.stale) children.add(_Stale(error: r.error, fetchedAt: r.fetchedAt, onRetry: () => _loadRank(force: true)));
      final top = board.rows.where((x) => !x.isImage).toList();
      final images = board.rows.where((x) => x.isImage).toList();
      final total = board.totalTokens;
      children.add(SettingsGroup(
        children: [
          for (var i = 0; i < top.length; i++) _RankRow(row: top[i], index: i + 1, total: total, key: ValueKey(top[i].model)),
        ],
      ));
      if (images.isNotEmpty) {
        children.add(SectionLabel(tr('Image models')));
        children.add(SettingsGroup(children: [for (final x in images) _RankRow(row: x, index: null, total: total, key: ValueKey(x.model))]));
      }
      children.add(
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 12, 4, 0),
          child: Text(
            tr('How much each model was used on GripHub Router by everyone, by tokens. This says how popular a model is, not how good it is.'),
            style: text.bodySmall?.copyWith(color: p.muted),
          ),
        ),
      );
    }
    return ListView(physics: const AlwaysScrollableScrollPhysics(), padding: const EdgeInsets.fromLTRB(16, 4, 16, 32), children: children);
  }
}

String _barLength(int ms) {
  final m = ms ~/ 60000;
  if (m < 60) return '$m ${tr('minutes')}';
  final h = m ~/ 60;
  return h == 1 ? '1 ${tr('hour')}' : '$h ${tr('hours')}';
}

// ---------------------------------------------------------------------------------------------- pieces

/// "Showing the copy from 14.30: couldn't reach the router."
class _Stale extends StatelessWidget {
  const _Stale({required this.error, required this.fetchedAt, required this.onRetry});
  final String? error;
  final DateTime fetchedAt;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: SurfaceCard(
        padding: const EdgeInsets.fromLTRB(14, 12, 6, 12),
        child: Row(
          children: [
            Icon(LucideIcons.cloudOff, size: 18, color: p.warning),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                '${tr('Showing the copy from {time}.').replaceAll('{time}', formatAgo(fetchedAt))}${error == null || error!.isEmpty ? '' : ' $error'}',
                style: text.bodySmall,
              ),
            ),
            TextButton(onPressed: onRetry, child: Text(tr('Try again'))),
          ],
        ),
      ),
    );
  }
}

class _Summary extends StatelessWidget {
  const _Summary({required this.board});
  final StatusBoard board;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final text = Theme.of(context).textTheme;
    // The number first and the label under it, so the three numbers line up however many lines a label takes.
    Widget stat(String label, int n, Color color) => Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('$n', style: text.titleLarge),
          const SizedBox(height: 4),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 5),
                child: Container(width: 8, height: 8, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
              ),
              const SizedBox(width: 6),
              Flexible(child: Text(label, style: text.bodySmall)),
            ],
          ),
        ],
      ),
    );
    return SurfaceCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            tr('{n} requests · {rate} succeeded')
                .replaceAll('{n}', _compact(board.requests))
                .replaceAll('{rate}', percent(board.successRate)),
            style: text.titleSmall,
          ),
          const SizedBox(height: 14),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              stat(tr('Working'), board.up, p.success),
              stat(tr('Slow or failing'), board.degraded, p.warning),
              stat(tr('Down'), board.down, p.danger),
            ],
          ),
        ],
      ),
    );
  }
}

class _StatusRow extends StatefulWidget {
  const _StatusRow({super.key, required this.model, required this.board});
  final StatusModel model;
  final StatusBoard board;

  @override
  State<_StatusRow> createState() => _StatusRowState();
}

class _StatusRowState extends State<_StatusRow> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final text = Theme.of(context).textTheme;
    final m = widget.model;
    final color = stateColor(p, m.state);
    final figures = text.bodySmall?.copyWith(fontFeatures: const [FontFeature.tabularFigures()]);
    final summary = [
      m.name,
      stateLabel(m.state),
      '${percent(m.successRate)} ${tr('succeeded')}',
      if (!m.active) tr('not in use'),
      if (m.bars.isNotEmpty) barsSummary(m.bars),
    ].join(', ');
    final detail = [
      '${percent(m.successRate)} ${tr('succeeded')}',
      if (!m.active) tr('not in use'),
    ].join(' · ');
    final pill = Pill(stateLabel(m.state), color: color, dot: true);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // The header is the button: it is read once, as one sentence, and says whether it is open.
        Semantics(
          button: true,
          expanded: _open,
          label: summary,
          excludeSemantics: true,
          onTap: _toggle,
          child: InkWell(
            onTap: _toggle,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 0),
              child: LayoutBuilder(
                builder: (context, c) {
                  // The pill beside the name only while the name keeps room (a narrow phone or large text puts it
                  // under the name: a model whose name is cut to "9…" says nothing).
                  final scale = MediaQuery.textScalerOf(context).scale(1);
                  final beside = c.maxWidth - 42 - 26 - 130 * scale >= 120;
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      BrandTile(id: m.model, model: m.model, size: 30),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(m.name, style: text.titleSmall, maxLines: 2, overflow: TextOverflow.ellipsis),
                            const SizedBox(height: 2),
                            if (beside)
                              Text(detail, style: text.bodySmall, maxLines: 2, overflow: TextOverflow.ellipsis)
                            else
                              Padding(
                                padding: const EdgeInsets.only(top: 2),
                                child: Wrap(
                                  spacing: 8,
                                  runSpacing: 4,
                                  crossAxisAlignment: WrapCrossAlignment.center,
                                  children: [pill, Text(detail, style: text.bodySmall)],
                                ),
                              ),
                          ],
                        ),
                      ),
                      if (beside) ...[const SizedBox(width: 8), pill],
                      const SizedBox(width: 4),
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: AnimatedRotation(
                          turns: _open ? 0.5 : 0,
                          duration: Motion.of(context, Motion.fast),
                          child: Icon(LucideIcons.chevronDown, size: 18, color: p.faint),
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (m.bars.isNotEmpty) BarStrip(model: m),
              AnimatedSize(
                duration: Motion.of(context, Motion.normal),
                curve: Motion.curve,
                alignment: Alignment.topCenter,
                child: _open
                    ? Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: Wrap(
                          spacing: 18,
                          runSpacing: 10,
                          children: [
                            _Fact(tr('Latest bars'), percent(m.recentSuccessRate), figures),
                            _Fact(tr('Typical wait'), _ms(m.latencyP50Ms), figures),
                            _Fact(tr('Slowest 5%'), _ms(m.latencyP95Ms), figures),
                            _Fact(tr('First token'), _ms(m.ttftP50Ms), figures),
                            _Fact(
                              tr('Speed'),
                              m.tokensPerSecond == null ? '—' : '${localNumber(m.tokensPerSecond!.toStringAsFixed(0))} ${tr('tokens/s')}',
                              figures,
                            ),
                            _Fact(tr('Requests'), _compact(m.requests), figures),
                            if (m.emptyResponses > 0) _Fact(tr('Empty answers'), _compact(m.emptyResponses), figures),
                            if (m.lastSeenAt != null) _Fact(tr('Last request'), formatAgo(m.lastSeenAt!), figures),
                            for (final e in m.errors.take(3)) _Fact(errorCategoryLabel(e.category), _compact(e.count), figures),
                          ],
                        ),
                      )
                    : const SizedBox(width: double.infinity),
              ),
            ],
          ),
        ),
      ],
    );
  }

  void _toggle() => setState(() => _open = !_open);
}

class _Fact extends StatelessWidget {
  const _Fact(this.label, this.value, this.valueStyle);
  final String label;
  final String value;
  final TextStyle? valueStyle;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return ConstrainedBox(
      constraints: const BoxConstraints(minWidth: 88, maxWidth: 160),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: text.labelSmall, maxLines: 2),
          const SizedBox(height: 2),
          Text(value, style: text.titleSmall),
        ],
      ),
    );
  }
}

/// A model's recent time in one row of small bars: green went well, orange partly, red failed, a faint dot nothing.
/// One painter for all of them (a bar widget each would be 48 per model), with a label for a screen reader.
class BarStrip extends StatelessWidget {
  const BarStrip({super.key, required this.model});
  final StatusModel model;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final bars = model.bars;
    return Semantics(
      // Read inside the model's own sentence (its row is one button); alone only where a strip stands by itself.
      label: barsSummary(bars),
      excludeSemantics: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            height: 22,
            width: double.infinity,
            child: CustomPaint(
              painter: _BarsPainter(
                bars: bars,
                ok: p.success,
                partial: p.warning,
                down: p.danger,
                none: p.border,
              ),
            ),
          ),
          if (model.barMs > 0)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(_reach(bars.length * model.barMs), style: Theme.of(context).textTheme.labelSmall),
                  Text(tr('now'), style: Theme.of(context).textTheme.labelSmall),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _BarsPainter extends CustomPainter {
  _BarsPainter({required this.bars, required this.ok, required this.partial, required this.down, required this.none});
  final List<StatusBar> bars;
  final Color ok;
  final Color partial;
  final Color down;
  final Color none;

  @override
  void paint(Canvas canvas, Size size) {
    if (bars.isEmpty) return;
    const gap = 1.5;
    final w = (size.width - gap * (bars.length - 1)) / bars.length;
    for (var i = 0; i < bars.length; i++) {
      final b = bars[i];
      final x = i * (w + gap);
      // No traffic: a short faint stub, so the strip still reads as time passing and is not mistaken for a failure.
      final (color, h) = switch (b.level) {
        BarLevel.ok => (ok, size.height),
        BarLevel.partial => (partial, size.height),
        BarLevel.down => (down, size.height),
        BarLevel.none => (none, size.height * 0.28),
      };
      canvas.drawRRect(
        RRect.fromRectAndRadius(Rect.fromLTWH(x, size.height - h, w, h), Radius.circular(w.clamp(0, 3) / 2)),
        Paint()..color = color,
      );
    }
  }

  @override
  bool shouldRepaint(_BarsPainter o) =>
      o.bars != bars || o.ok != ok || o.partial != partial || o.down != down || o.none != none;
}

class _RankRow extends StatelessWidget {
  const _RankRow({super.key, required this.row, required this.index, required this.total});
  final RankRow row;

  /// The place in the list; null for the image models, which are not ranked against the text ones.
  final int? index;
  final int total;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final text = Theme.of(context).textTheme;
    final share = row.tokens > 0 && total > 0 ? row.tokens / total : 0.0;
    final amount = row.isImage
        ? tr('{n} images').replaceAll('{n}', _compact(row.images))
        : '${_compact(row.tokens)} ${tr('tokens')}';
    final name = row.name ?? row.model;
    return Semantics(
      container: true,
      label: '${index == null ? '' : '$index. '}$name, $amount, ${_compact(row.requests)} ${tr('requests')}',
      excludeSemantics: true,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            LayoutBuilder(
              builder: (context, c) {
                final figures = text.titleSmall?.copyWith(fontFeatures: const [FontFeature.tabularFigures()]);
                // The amount beside the name only while the name keeps room; on a narrow phone or at large text it goes
                // under the name instead of cutting the name to "Deeps…".
                final scale = MediaQuery.textScalerOf(context).scale(1);
                final beside = c.maxWidth - 24 - 42 - 8 - 96 * scale >= 130;
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (index != null)
                      SizedBox(
                        width: 24,
                        child: Padding(
                          padding: const EdgeInsets.only(top: 3),
                          child: Text('$index', style: text.labelMedium?.copyWith(color: p.faint, fontFeatures: const [FontFeature.tabularFigures()])),
                        ),
                      ),
                    BrandTile(id: row.model, model: row.model, size: 30),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(name, style: text.titleSmall, maxLines: 2, overflow: TextOverflow.ellipsis),
                          const SizedBox(height: 2),
                          if (beside)
                            Text('${_compact(row.requests)} ${tr('requests')}', style: text.bodySmall, maxLines: 2, overflow: TextOverflow.ellipsis)
                          else
                            Text('$amount · ${_compact(row.requests)} ${tr('requests')}', style: text.bodySmall, maxLines: 3, overflow: TextOverflow.ellipsis),
                        ],
                      ),
                    ),
                    if (beside) ...[const SizedBox(width: 8), Padding(padding: const EdgeInsets.only(top: 1), child: Text(amount, style: figures))],
                  ],
                );
              },
            ),
            if (!row.isImage && share > 0) ...[
              const SizedBox(height: 8),
              ClipRRect(
                borderRadius: BorderRadius.circular(3),
                child: LinearProgressIndicator(
                  value: share.clamp(0.0, 1.0),
                  minHeight: 4,
                  backgroundColor: p.border,
                  color: p.accent,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
