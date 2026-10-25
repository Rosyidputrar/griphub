import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../agent/agent_controller.dart';
import '../agent/features.dart';
import '../agent/pricing.dart';
import 'kit.dart';
import 'i18n.dart';
import 'theme.dart';

String _money(num v) {
  if (v == 0) return r'$0.00';
  return v < 0.01 ? '\$${v.toStringAsFixed(4)}' : '\$${v.toStringAsFixed(2)}';
}

String _compact(num n) {
  String trim(double v) => v >= 100 ? v.toStringAsFixed(0) : v.toStringAsFixed(1).replaceAll(RegExp(r'\.0$'), '');
  if (n >= 1e9) return localNumber('${trim(n / 1e9)}B');
  if (n >= 1e6) return localNumber('${trim(n / 1e6)}M');
  if (n >= 1e3) return localNumber('${trim(n / 1e3)}k');
  return localNumber('${n.round()}');
}

num _num(Object? o) => o is num ? o : 0;

/// Credits with at most 2 decimals, trailing zeros trimmed (80.38, 1, 0.15), in the app's number format.
String _creditsFmt(num v) => localNumber(v.toStringAsFixed(2).replaceAll(RegExp(r'\.?0+$'), ''));

/// An amount with its unit, the same way everywhere on the screen ("7.350 kredit", "0,978 kredit").
String _creditText(num v, {bool precise = false}) =>
    '${precise ? localNumber(formatCredits(v)) : _creditsFmt(v)} ${tr(v == 1 ? 'credit' : 'credits')}';

/// Numbers line up and share the body font (the mono face made a few figures look like code).
const _figures = [FontFeature.tabularFigures()];

/// Rupiah with dot thousands (Rp 24.114).
String _rp(num v) {
  final s = v.round().toString();
  return 'Rp ${s.replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (m) => '.')}';
}

/// Local date in short form, months in the app's language (30 Okt 2026 / 30 Oct 2026).
String _dateId(String iso) {
  const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  const monthsId = ['Jan', 'Feb', 'Mar', 'Apr', 'Mei', 'Jun', 'Jul', 'Agu', 'Sep', 'Okt', 'Nov', 'Des'];
  final d = DateTime.parse(iso).toLocal();
  return '${d.day} ${(Appearance.instance.language == 'id' ? monthsId : months)[d.month - 1]} ${d.year}';
}

/// Token and cost usage across sessions, per day and per model, plus the
/// daily budget that stops runaway spend.
class UsageScreen extends StatefulWidget {
  const UsageScreen({super.key, required this.agent});
  final AgentController agent;

  @override
  State<UsageScreen> createState() => _UsageScreenState();
}

class _UsageScreenState extends State<UsageScreen> {
  int _days = 7;
  List<UsageRow>? _rows;
  Map<String, dynamic>? _session;
  Object? _error;
  Map<String, dynamic>? _credits;
  Object? _creditsError;

  AgentController get agent => widget.agent;

  @override
  void initState() {
    super.initState();
    _load();
    _loadCredits();
    agent.features.sessionStats().then((s) {
      if (mounted) setState(() => _session = s);
    }, onError: (_) {});
    agent.integrations.refreshSettings().then((_) {
      if (mounted) setState(() {});
    }, onError: (_) {});
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final rows = await agent.features.usage(days: _days);
      if (mounted) setState(() => _rows = rows);
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _loadCredits() async {
    setState(() => _creditsError = null);
    try {
      final c = await agent.integrations.griphubCredits();
      if (mounted) setState(() => _credits = c);
    } catch (e) {
      if (mounted) setState(() => _creditsError = e);
    }
  }

  num get _budget => _num(agent.integrations.settings?.json['dailyBudget']);

  Future<void> _editBudget() async {
    final value = await showDialog<double>(context: context, builder: (_) => _BudgetDialog(current: _budget));
    if (value == null) return;
    try {
      await agent.integrations.updateSettings({'dailyBudget': value < 0 ? 0 : value});
      if (mounted) setState(() {});
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  Widget _creditCard(BuildContext context) {
    final p = context.palette;
    final text = Theme.of(context).textTheme;
    if (_creditsError != null) {
      return SurfaceCard(child: Text('$_creditsError', style: text.bodySmall?.copyWith(color: p.danger)));
    }
    final c = _credits;
    if (c == null) {
      return const SurfaceCard(
        child: Center(child: SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2))),
      );
    }
    final remaining = _num(c['remaining']);
    final used = _num(c['used']);
    final limit = _num(c['limit']);
    final suspended = c['suspended'] == true;
    final suspendedUntil = c['suspendedUntil'] as String?;
    final nearest = c['nearestExpiry'] as Map?;
    final top = (c['topModels'] as List? ?? const []).cast<Map>();
    final usedFraction = limit > 0 ? (used / limit).toDouble() : 0.0;
    return SurfaceCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              IconTile(icon: LucideIcons.wallet, color: p.accent),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(_creditText(remaining), style: text.titleMedium),
                    Text('≈ ${_rp(remaining * kRupiahPerCredit)}', style: text.bodySmall?.copyWith(fontFeatures: _figures)),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text('${tr('Used')} ${_creditsFmt(used)} ${tr('of')} ${_creditText(limit)}', style: text.bodySmall),
          if (limit > 0) ...[
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(Radii.pill),
              child: LinearProgressIndicator(
                value: usedFraction.clamp(0, 1).toDouble(),
                minHeight: 8,
                backgroundColor: p.border,
                color: usedFraction > 0.85 ? p.danger : (usedFraction > 0.6 ? p.warning : p.accent),
              ),
            ),
          ],
          if (suspended) ...[
            const SizedBox(height: 8),
            Text(
              suspendedUntil != null ? '${tr('Account suspended')} · ${_dateId(suspendedUntil)}' : tr('Account suspended'),
              style: text.bodySmall?.copyWith(color: p.danger),
            ),
          ],
          if (nearest != null) ...[
            const SizedBox(height: 4),
            Text(
              tr('Earliest batch expires {date} ({n})')
                  .replaceAll('{date}', _dateId(nearest['expiresAt'] as String))
                  .replaceAll('{n}', _creditText(_num(nearest['credits']))),
              style: text.bodySmall,
            ),
          ],
          if (top.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(tr('Top usage'), style: text.titleSmall),
            const SizedBox(height: 4),
            for (final m in top)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Row(
                  children: [
                    Expanded(child: Text('${m['model']}', style: text.bodySmall, overflow: TextOverflow.ellipsis)),
                    Text(
                      _creditText(_num(m['creditsUsed'])),
                      style: text.bodySmall?.copyWith(fontFeatures: _figures),
                    ),
                  ],
                ),
              ),
          ],
          const SizedBox(height: 12),
          Text(tr('1 credit = Rp 300 · prices as of Oct 2026'), style: text.bodySmall),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final text = Theme.of(context).textTheme;
    final rows = _rows;
    return Scaffold(
      appBar: AppBar(title: Text(tr('Usage'))),
      body: RefreshIndicator(
        onRefresh: () async {
          await _load();
          await _loadCredits();
        },
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 40),
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: PillSegments<int>(
                value: _days,
                options: {for (final d in const [7, 30]) d: '$d ${tr('days')}'},
                onChanged: (d) {
                  setState(() => _days = d);
                  _load();
                },
                expand: false,
              ),
            ),
            const SizedBox(height: 14),
            SectionLabel(tr('GripHub credit')),
            _creditCard(context),
            const SizedBox(height: 10),
            if (_error != null)
              SurfaceCard(
                child: Text('$_error', style: text.bodySmall?.copyWith(color: p.danger)),
              )
            else if (rows == null)
              const Padding(
                padding: EdgeInsets.all(40),
                child: Center(child: CircularProgressIndicator()),
              )
            else
              ..._summary(context, rows),
            SectionLabel(tr('This chat')),
            _sessionCard(context),
            SectionLabel(tr('Limits')),
            SettingsGroup(
              children: [
                SettingsRow(
                  icon: LucideIcons.wallet,
                  color: p.warning,
                  title: tr('Daily budget'),
                  subtitle: _budget == 0
                      ? tr('No limit')
                      : tr('{n} per day').replaceAll('{n}', _creditText(_budget, precise: true)),
                  onTap: _editBudget,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _summary(BuildContext context, List<UsageRow> rows) {
    final p = context.palette;
    final text = Theme.of(context).textTheme;
    // pi's own cost is 0 for GripHub (the router reports no prices), so
    // estimate from the hardcoded rate table instead. pi costs still win
    // when present (other providers); a model with no known rate shows "—",
    // never an invented number.
    final piCost = rows.fold<double>(0, (a, r) => a + r.cost);
    double estimatedTotal = 0;
    var hasEstimate = false;
    for (final r in rows) {
      final e = estimatedCredits(model: r.model, inputTokens: r.input, outputTokens: r.output);
      if (e != null) {
        hasEstimate = true;
        estimatedTotal += e;
      }
    }
    final showPiCost = piCost > 0;
    final showEstimate = !showPiCost && hasEstimate;

    final input = rows.fold<int>(0, (a, r) => a + r.input);
    final output = rows.fold<int>(0, (a, r) => a + r.output);
    final requests = rows.fold<int>(0, (a, r) => a + r.requests);

    final today = DateTime.now();
    final days = [
      for (var i = _days - 1; i >= 0; i--)
        DateTime(today.year, today.month, today.day - i).toIso8601String().substring(0, 10),
    ];
    final perDay = {for (final d in days) d: 0.0};
    for (final r in rows) {
      if (perDay.containsKey(r.day)) {
        final v = showPiCost
            ? r.cost
            : showEstimate
                ? (estimatedCredits(model: r.model, inputTokens: r.input, outputTokens: r.output) ?? 0)
                : (r.input + r.output).toDouble();
        perDay[r.day] = perDay[r.day]! + v;
      }
    }

    final byModel = <String, ({String provider, String model, int tokens, double cost, double estCost, bool hasRate})>{};
    for (final r in rows) {
      final k = '${r.provider}/${r.model}';
      final prev = byModel[k];
      final e = estimatedCredits(model: r.model, inputTokens: r.input, outputTokens: r.output);
      byModel[k] = (
        provider: r.provider,
        model: r.model,
        tokens: (prev?.tokens ?? 0) + r.input + r.output,
        cost: (prev?.cost ?? 0) + r.cost,
        estCost: (prev?.estCost ?? 0) + (e ?? 0),
        hasRate: (prev?.hasRate ?? false) || e != null,
      );
    }
    final models = byModel.values.toList()
      ..sort((a, b) {
        if (showPiCost) return b.cost.compareTo(a.cost);
        if (showEstimate) return b.estCost.compareTo(a.estCost);
        return b.tokens.compareTo(a.tokens);
      });

    return [
      Row(
        children: [
          Expanded(
            child: _StatCard(
              icon: LucideIcons.coins,
              color: p.accent,
              label: tr('Cost'),
              value: showPiCost
                  ? _money(piCost)
                  : showEstimate
                      ? _creditText(estimatedTotal, precise: true)
                      : '—',
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: _StatCard(
              icon: LucideIcons.activity,
              color: p.accentAlt,
              label: tr('Requests'),
              value: _compact(requests),
            ),
          ),
        ],
      ),
      const SizedBox(height: 10),
      Row(
        children: [
          Expanded(
            child: _StatCard(
              icon: LucideIcons.arrowUpFromLine,
              color: p.success,
              label: tr('Input tokens'),
              value: _compact(input),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: _StatCard(
              icon: LucideIcons.arrowDownToLine,
              color: p.warning,
              label: tr('Output tokens'),
              value: _compact(output),
            ),
          ),
        ],
      ),
      SectionLabel(tr(showPiCost || showEstimate ? 'Cost per day' : 'Tokens per day')),
      SurfaceCard(
        child: _BarChart(
          values: [for (final d in days) perDay[d]!],
          labels: days,
          format: showPiCost ? _money : showEstimate ? (v) => _creditText(v, precise: true) : _compact,
        ),
      ),
      if (showEstimate)
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text(
            tr(
              'Estimated from the rates of 25 Oct 2026 · total ≈ {rp} · the exact figure is on the GripHub credit card above',
            ).replaceAll('{rp}', _rp(estimatedTotal * kRupiahPerCredit)),
            style: text.bodySmall,
          ),
        ),
      SectionLabel(tr('By model')),
      if (models.isEmpty)
        SurfaceCard(child: Text(tr('No requests in this period.'), style: text.bodySmall))
      else
        SettingsGroup(
          children: [
            for (final m in models)
              SettingsRow(
                leading: BrandTile(id: m.provider, size: 30),
                title: m.model.isEmpty ? 'unknown' : m.model,
                subtitle: '${m.provider} · ${_compact(m.tokens)} ${tr('tokens')}',
                trailing: Text(
                  showPiCost ? _money(m.cost) : m.hasRate ? _creditText(m.estCost, precise: true) : '—',
                  style: text.titleSmall?.copyWith(fontFeatures: _figures),
                ),
              ),
          ],
        ),
    ];
  }

  Widget _sessionCard(BuildContext context) {
    final p = context.palette;
    final text = Theme.of(context).textTheme;
    final s = _session;
    if (s == null) {
      return SurfaceCard(child: Text(tr('No active chat.'), style: text.bodySmall));
    }
    final tokens = s['tokens'];
    final total = tokens is Map ? _num(tokens['total']) : _num(tokens);
    final cost = _num(s['cost']);
    final ctx = s['context'] is Map ? (s['context'] as Map).cast<String, dynamic>() : null;
    final ctxTokens = ctx?['tokens'] is num ? ctx!['tokens'] as num : null;
    final window = ctx?['contextWindow'] is num ? ctx!['contextWindow'] as num : null;
    var percent = ctx?['percent'] is num ? (ctx!['percent'] as num).toDouble() : null;
    if (percent == null && ctxTokens != null && window != null && window > 0) percent = ctxTokens / window * 100;
    return SurfaceCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              IconTile(icon: LucideIcons.messageSquare, color: p.accent),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('${_compact(total)} ${tr('tokens')}', style: text.titleMedium),
                    if (cost > 0) Text(_money(cost), style: text.bodySmall?.copyWith(fontFeatures: _figures)),
                  ],
                ),
              ),
            ],
          ),
          if (percent != null) ...[
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(child: Text(tr('Context window'), style: text.bodySmall)),
                Text(
                  [
                    if (ctxTokens != null && window != null) '${_compact(ctxTokens)} / ${_compact(window)}',
                    '${percent.toStringAsFixed(0)}%',
                  ].join(' · '),
                  style: text.bodySmall?.copyWith(fontFeatures: _figures),
                ),
              ],
            ),
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(Radii.pill),
              child: LinearProgressIndicator(
                value: (percent / 100).clamp(0, 1).toDouble(),
                minHeight: 8,
                backgroundColor: p.border,
                color: percent > 85 ? p.danger : (percent > 60 ? p.warning : p.accent),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _StatCard extends StatelessWidget {
  const _StatCard({required this.icon, required this.color, required this.label, required this.value});
  final IconData icon;
  final Color color;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return SurfaceCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          IconTile(icon: icon, color: color, size: 30),
          const SizedBox(height: 12),
          Text(value, style: text.titleLarge?.copyWith(fontFeatures: _figures)),
          const SizedBox(height: 2),
          Text(label, style: text.bodySmall),
        ],
      ),
    );
  }
}

/// Flat bars, one per day; the tallest is labelled.
class _BarChart extends StatelessWidget {
  const _BarChart({required this.values, required this.labels, required this.format});
  final List<double> values;
  final List<String> labels;
  final String Function(num) format;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final text = Theme.of(context).textTheme;
    final max = values.fold<double>(0, (a, v) => v > a ? v : a);
    final gap = values.length > 14 ? 3.0 : 8.0;
    String short(String d) => d.length >= 10 ? d.substring(5) : d;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          max == 0 ? tr('Nothing yet') : '${tr('Peak')} ${format(max)}',
          style: text.bodySmall?.copyWith(fontFeatures: _figures),
        ),
        const SizedBox(height: 12),
        SizedBox(
          height: 120,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              for (var i = 0; i < values.length; i++) ...[
                if (i > 0) SizedBox(width: gap),
                Expanded(
                  child: Tooltip(
                    message: '${labels[i]}: ${format(values[i])}',
                    child: Container(
                      height: max == 0 ? 3 : (values[i] / max * 116).clamp(3, 116).toDouble(),
                      decoration: BoxDecoration(
                        color: values[i] == 0 ? p.border : p.accent,
                        borderRadius: BorderRadius.circular(Radii.xs),
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            Text(short(labels.first), style: text.labelSmall),
            const Spacer(),
            Text(short(labels.last), style: text.labelSmall),
          ],
        ),
      ],
    );
  }
}

/// The daily budget editor. It owns its text controller, so the field is not
/// disposed while the dialog is still animating out.
class _BudgetDialog extends StatefulWidget {
  const _BudgetDialog({required this.current});
  final num current;

  @override
  State<_BudgetDialog> createState() => _BudgetDialogState();
}

class _BudgetDialogState extends State<_BudgetDialog> {
  late final _ctrl = TextEditingController(
    text: widget.current == 0
        ? ''
        : localNumber(widget.current.toString().replaceAll(RegExp(r'\.0+$'), '')),
  );
  String? _problem;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _save() {
    final text = _ctrl.text.trim();
    // Empty is "no limit"; anything else must read as a number, or a typo would
    // silently clear the limit (it used to save 0, and "1,5" used to become 15).
    if (text.isEmpty) return Navigator.pop(context, 0.0);
    final v = parseLocalNumber(text);
    if (v == null || v < 0) return setState(() => _problem = tr('Enter a number, like 2 or 1.5'));
    Navigator.pop(context, v);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(tr('Daily budget')),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            tr(
              'The agent stops starting new requests once today\'s spend reaches this, in GripHub credits. Leave empty for no limit.',
            ),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _ctrl,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'))],
            onSubmitted: (_) => _save(),
            decoration: InputDecoration(suffixText: tr('credits'), hintText: tr('No limit'), errorText: _problem),
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(tr('Cancel'))),
        TextButton(onPressed: _save, child: Text(tr('Save'))),
      ],
    );
  }
}
