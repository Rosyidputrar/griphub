import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../agent/agent_controller.dart';
import '../agent/clock.dart';
import '../agent/features.dart';
import '../agent/integrations.dart' show AppSettings;
import '../agent/pricing.dart';
import '../agent/router_account.dart';
import 'errors.dart';
import 'kit.dart';
import 'subagent_card.dart' show thinkingLabel;
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
String _dateId(DateTime t) {
  const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  const monthsId = ['Jan', 'Feb', 'Mar', 'Apr', 'Mei', 'Jun', 'Jul', 'Agu', 'Sep', 'Okt', 'Nov', 'Des'];
  final d = t.toLocal();
  return '${d.day} ${(Appearance.instance.language == 'id' ? monthsId : months)[d.month - 1]} ${d.year}';
}

/// Time of day, 24 h (08.29 / 08:29).
String _clock(DateTime t) {
  final d = t.toLocal();
  final sep = Appearance.instance.language == 'id' ? '.' : ':';
  return '${d.hour.toString().padLeft(2, '0')}$sep${d.minute.toString().padLeft(2, '0')}';
}

/// GripHub credit and usage. The account card, today's spend and the
/// per-model and per-request lists are the router's own figures (what was
/// charged); the per-day chart is estimated from this phone's chats (the
/// router has no per-day history), and says so.
class UsageScreen extends StatefulWidget {
  const UsageScreen({super.key, required this.agent});
  final AgentController agent;

  @override
  State<UsageScreen> createState() => _UsageScreenState();
}

class _UsageScreenState extends State<UsageScreen> {
  int _days = 7;

  /// The rows of the period [_days] names; null while that period is being read. Rows of another period are never
  /// shown under its tab.
  List<UsageRow>? _rows;
  Map<String, dynamic>? _session;
  Object? _error;
  RouterAccount? _account;
  Object? _accountError;
  bool _loadingAccount = false;
  bool _allRequests = false;

  /// Counts reads of the rows, so one that comes back after a newer one (the same period asked twice: a pull to refresh
  /// over a slow first read) cannot overwrite it. The period check alone only guards against another period's tab.
  int _reading = 0;

  AgentController get agent => widget.agent;

  @override
  void initState() {
    super.initState();
    _account = agent.integrations.router;
    _load();
    _loadAccount();
    agent.features.sessionStats().then((s) {
      if (mounted) setState(() => _session = s);
    }, onError: (_) {});
    agent.integrations.refreshSettings().then((_) {
      if (mounted) setState(() {});
    }, onError: (_) {});
  }

  Future<void> _load() async {
    final days = _days;
    final reading = ++_reading;
    setState(() => _error = null);
    try {
      final rows = await agent.features.usage(days: days);
      // A newer read (another period, or the same one asked again) is on its way or done: this one is stale.
      if (mounted && reading == _reading) setState(() => _rows = rows);
    } catch (e) {
      if (mounted && reading == _reading) setState(() => _error = e);
    }
  }

  void _setDays(int days) {
    if (days == _days) return;
    setState(() {
      _days = days;
      _rows = null;
    });
    _load();
  }

  Future<void> _loadAccount({bool force = false}) async {
    setState(() {
      _accountError = null;
      _loadingAccount = true;
    });
    try {
      final a = await agent.integrations.routerAccount(force: force);
      if (mounted) setState(() => _account = a);
    } catch (e) {
      if (mounted) setState(() => _accountError = e);
    } finally {
      if (mounted) setState(() => _loadingAccount = false);
    }
  }

  num get _budget => _num(agent.integrations.settings?.json['dailyBudget']);

  /// The context limit's choices (tokens); 0 leaves it to the model's own limit.
  static const compactChoices = [100000, 200000, 300000, 500000, 0];

  /// The limit being saved: shown at once, with a spinner, until the host has it.
  int? _compactSaving;

  String _compactText(int v) => v == 0
      ? tr('At the model\'s limit')
      : tr('{n} tokens').replaceAll('{n}', localNumber(formatTokens(v)));

  Future<void> _editCompactAt() async {
    if (_compactSaving != null) return;
    final current = agent.integrations.settings?.compactAt ?? AppSettings.compactAtDefault;
    final picked = await showDialog<int>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text(tr('Summarize the chat at')),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
            child: Text(
              tr(
                'Every request sends the whole chat, so a long chat costs more with every message. Past this size the older turns become a summary. Large models would otherwise wait until close to their own limit.',
              ),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          for (final v in compactChoices)
            ListTile(
              title: Text(_compactText(v)),
              subtitle: v == AppSettings.compactAtDefault ? Text(tr('Recommended')) : null,
              trailing: v == current ? const Icon(LucideIcons.check, size: 18) : null,
              onTap: () => Navigator.pop(context, v),
            ),
        ],
      ),
    );
    if (picked == null || picked == current || !mounted) return;
    setState(() => _compactSaving = picked);
    try {
      await agent.integrations.updateSettings({'compactAt': picked});
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(friendlyError(e))));
    } finally {
      if (mounted) setState(() => _compactSaving = null);
    }
  }

  Future<void> _editBudget() async {
    final value = await showDialog<double>(context: context, builder: (_) => _BudgetDialog(current: _budget));
    if (value == null) return;
    try {
      await agent.integrations.updateSettings({'dailyBudget': value < 0 ? 0 : value});
      if (mounted) setState(() {});
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(friendlyError(e))));
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final text = Theme.of(context).textTheme;
    final rows = _rows;
    final a = _account;
    return Scaffold(
      appBar: AppBar(
        title: Text(tr('Usage')),
        actions: [
          IconButton(
            tooltip: tr('Refresh'),
            onPressed: _loadingAccount
                ? null
                : () {
                    _loadAccount(force: true);
                    _load();
                  },
            icon: _loadingAccount
                ? const BusySpinner(size: 18)
                : const Icon(LucideIcons.refreshCw),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          await Future.wait([_load(), _loadAccount(force: true)]);
        },
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 40),
          children: [
            SectionLabel(tr('GripHub account'), padding: const EdgeInsets.fromLTRB(4, 8, 4, 10)),
            AccountCard(
              account: a,
              error: _accountError,
              budget: _budget.toDouble(),
              onRetry: () => _loadAccount(force: true),
            ),
            if (a != null && a.byModel.isNotEmpty) ...[
              SectionLabel(tr('Charged by model')),
              _byModelReal(context, a),
            ],
            if (a != null && a.requests.isNotEmpty) ...[
              SectionLabel(
                tr('Recent requests'),
                trailing: a.requests.length > 8
                    ? TextButton(
                        onPressed: () => setState(() => _allRequests = !_allRequests),
                        child: Text(tr(_allRequests ? 'Show less' : 'Show all')),
                      )
                    : null,
              ),
              RequestList(requests: _allRequests ? a.requests : a.requests.take(8).toList()),
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
                child: Text(
                  tr('Each request costs at least its model\'s minimum (floor). Failed requests are not charged.'),
                  style: text.bodySmall,
                ),
              ),
            ],
            SectionLabel(tr('This phone')),
            Align(
              alignment: Alignment.centerLeft,
              child: PillSegments<int>(
                value: _days,
                options: {for (final d in const [7, 30]) d: '$d ${tr('days')}'},
                onChanged: _setDays,
                expand: false,
              ),
            ),
            const SizedBox(height: 10),
            if (_error != null)
              SurfaceCard(child: ErrorNotice(error: _error, onRetry: _load))
            else if (rows == null)
              const Padding(padding: EdgeInsets.all(40), child: Center(child: BusySpinner.page()))
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
                SettingsRow(
                  icon: LucideIcons.layers,
                  color: p.accentAlt,
                  title: tr('Summarize the chat at'),
                  subtitle: _compactText(
                    _compactSaving ?? agent.integrations.settings?.compactAt ?? AppSettings.compactAtDefault,
                  ),
                  trailing: _compactSaving != null ? const BusySpinner() : null,
                  onTap: _compactSaving != null ? null : _editCompactAt,
                ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
              child: Text(
                tr('The budget counts what GripHub charged your account today (WIB), plus work still running.'),
                style: text.bodySmall,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _byModelReal(BuildContext context, RouterAccount a) {
    final text = Theme.of(context).textTheme;
    final models = a.byModel.where((m) => m.credits > 0 || m.requests > 0).take(8).toList();
    return SettingsGroup(
      children: [
        for (final m in models)
          SettingsRow(
            leading: BrandTile(id: m.model, size: 30),
            title: m.model,
            subtitle: [
              m.requests == 1 ? tr('1 request') : tr('{n} requests').replaceAll('{n}', _compact(m.requests)),
              if (m.images > 0) tr('{n} images').replaceAll('{n}', '${m.images}') else '${_compact(m.tokens)} ${tr('tokens')}',
            ].join(' · '),
            trailing: Text(_creditText(m.credits, precise: true), style: text.titleSmall?.copyWith(fontFeatures: _figures)),
          ),
      ],
    );
  }

  List<Widget> _summary(BuildContext context, List<UsageRow> rows) {
    final p = context.palette;
    final text = Theme.of(context).textTheme;
    // GripHub credits by the router's rule, per request (host-side); pi's own
    // cost only for other providers that report one. Unknown prices show "—".
    final piCost = rows.fold<double>(0, (a, r) => a + r.cost);
    final priced = rows.where((r) => r.credits != null);
    final estimatedTotal = priced.fold<double>(0, (a, r) => a + r.credits!);
    final hasEstimate = priced.isNotEmpty;
    final showPiCost = piCost > 0 && !hasEstimate;
    final showEstimate = hasEstimate;

    final tokens = rows.fold<int>(0, (a, r) => a + r.tokens);
    final cached = rows.fold<int>(0, (a, r) => a + r.cacheRead + r.cacheWrite);
    final requests = rows.fold<int>(0, (a, r) => a + r.requests);

    final today = clock();
    final days = [
      for (var i = _days - 1; i >= 0; i--)
        DateTime(today.year, today.month, today.day - i).toIso8601String().substring(0, 10),
    ];
    final perDay = {for (final d in days) d: 0.0};
    for (final r in rows) {
      if (perDay.containsKey(r.day)) {
        final v = showEstimate ? (r.credits ?? 0) : showPiCost ? r.cost : r.tokens.toDouble();
        perDay[r.day] = perDay[r.day]! + v;
      }
    }

    final byModel = <String, ({String provider, String model, int tokens, double cost, double? credits})>{};
    for (final r in rows) {
      final k = '${r.provider}/${r.model}';
      final prev = byModel[k];
      final prevCredits = prev == null ? 0.0 : prev.credits;
      byModel[k] = (
        provider: r.provider,
        model: r.model,
        tokens: (prev?.tokens ?? 0) + r.tokens,
        cost: (prev?.cost ?? 0) + r.cost,
        credits: prevCredits == null || r.credits == null ? null : prevCredits + r.credits!,
      );
    }
    final models = byModel.values.toList()
      ..sort((a, b) => showEstimate ? (b.credits ?? -1).compareTo(a.credits ?? -1) : b.tokens.compareTo(a.tokens));

    return [
      Row(
        children: [
          Expanded(
            child: _StatCard(
              icon: LucideIcons.coins,
              color: p.accent,
              label: tr(showEstimate ? 'Estimated cost' : 'Cost'),
              value: showEstimate
                  ? _creditText(estimatedTotal, precise: true)
                  : showPiCost
                  ? _money(piCost)
                  : '—',
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: _StatCard(icon: LucideIcons.activity, color: p.accentAlt, label: tr('Requests'), value: _compact(requests)),
          ),
        ],
      ),
      const SizedBox(height: 10),
      Row(
        children: [
          Expanded(
            child: _StatCard(icon: LucideIcons.layers, color: p.success, label: tr('Tokens billed'), value: _compact(tokens)),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: _StatCard(
              icon: LucideIcons.databaseZap,
              color: p.warning,
              label: tr('From cache'),
              value: tokens == 0 ? '—' : '${(cached / tokens * 100).round()}%',
            ),
          ),
        ],
      ),
      SectionLabel(tr(showPiCost || showEstimate ? 'Cost per day' : 'Tokens per day')),
      SurfaceCard(
        child: _BarChart(
          values: [for (final d in days) perDay[d]!],
          labels: days,
          format: showEstimate ? (v) => _creditText(v, precise: true) : showPiCost ? _money : _compact,
        ),
      ),
      if (showEstimate)
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text(
            tr(
              'Estimated from this phone\'s chats at GripHub\'s live rates and minimums · total ≈ {rp}. What was actually charged is in the account card above.',
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
                  showEstimate
                      ? (m.credits == null ? '—' : '~${_creditText(m.credits!, precise: true)}')
                      : showPiCost
                      ? _money(m.cost)
                      : '—',
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

/// The account: balance, today's spend against the budget, credit expiring
/// next, and a low-balance warning. Every figure is the router's own.
class AccountCard extends StatelessWidget {
  const AccountCard({super.key, required this.account, this.error, this.budget = 0, this.onRetry});
  final RouterAccount? account;
  final Object? error;
  final VoidCallback? onRetry;
  final double budget;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final text = Theme.of(context).textTheme;
    final a = account;
    if (a == null) {
      return SurfaceCard(
        child: error != null
            ? ErrorNotice(error: error, onRetry: onRetry)
            : const Center(child: BusySpinner(size: 20)),
      );
    }
    final low = a.lowBalance;
    final next = a.nextExpiry;
    final left = a.daysLeft();
    final usedFraction = a.granted > 0 ? (a.used / a.granted).clamp(0, 1).toDouble() : 0.0;
    final soon = next?.expiresAt != null && next!.expiresAt!.difference(clock()).inDays < 7;
    return SurfaceCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              IconTile(icon: LucideIcons.wallet, color: low ? p.danger : p.accent),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(_creditText(a.balance, precise: true), style: text.titleLarge?.copyWith(fontFeatures: _figures)),
                    Text(
                      '≈ ${_rp(a.balance * kRupiahPerCredit)}${left == null ? '' : ' · ${tr('about {n} days at your pace').replaceAll('{n}', left < 1 ? '<1' : '${left.round()}')}'}',
                      style: text.bodySmall?.copyWith(fontFeatures: _figures),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (low) ...[
            const SizedBox(height: 10),
            _Banner(icon: LucideIcons.triangleAlert, color: p.danger, text: tr('Credit is running low. Top up at griphubrouter.web.id to keep the agent working.')),
          ],
          if (a.suspended) ...[
            const SizedBox(height: 10),
            _Banner(
              icon: LucideIcons.ban,
              color: p.danger,
              text: a.suspendedUntil != null ? '${tr('Account suspended')} · ${_dateId(a.suspendedUntil!)}' : tr('Account suspended'),
            ),
          ],
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: _Figure(
                  label: tr('Today'),
                  value: _creditText(a.spentToday, precise: true),
                  note: a.spentTodayReal ? null : tr('estimate'),
                ),
              ),
              Expanded(child: _Figure(label: tr('Used in total'), value: _creditText(a.used))),
            ],
          ),
          if (budget > 0) ...[
            const SizedBox(height: 10),
            Text(
              tr('{a} of the {b} daily budget').replaceAll('{a}', _creditText(a.spentToday, precise: true)).replaceAll('{b}', _creditText(budget, precise: true)),
              style: text.bodySmall,
            ),
            const SizedBox(height: 6),
            ClipRRect(
              borderRadius: BorderRadius.circular(Radii.pill),
              child: LinearProgressIndicator(
                value: (a.spentToday / budget).clamp(0, 1).toDouble(),
                minHeight: 6,
                backgroundColor: p.border,
                color: a.spentToday >= budget ? p.danger : (a.spentToday > budget * 0.8 ? p.warning : p.accent),
              ),
            ),
          ] else if (a.granted > 0) ...[
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(Radii.pill),
              child: LinearProgressIndicator(
                value: usedFraction,
                minHeight: 6,
                backgroundColor: p.border,
                color: low ? p.danger : p.accent,
              ),
            ),
          ],
          if (next?.expiresAt != null) ...[
            const SizedBox(height: 10),
            Row(
              children: [
                Icon(LucideIcons.clock, size: 14, color: soon ? p.warning : p.muted),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    tr('{n} expire {date}').replaceAll('{n}', _creditText(next!.credits, precise: true)).replaceAll('{date}', _dateId(next.expiresAt!)),
                    style: text.bodySmall?.copyWith(color: soon ? p.warning : null),
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: 10),
          Text(
            [
              tr('Updated {time}').replaceAll('{time}', formatAgo(a.fetchedAt)),
              if (a.source != 'user-usage') tr('limited data'),
              if (error != null) tr('offline, showing the last figures'),
              tr('1 credit = Rp 300'),
            ].join(' · '),
            style: text.bodySmall?.copyWith(color: error != null ? p.warning : null),
          ),
        ],
      ),
    );
  }
}

class _Figure extends StatelessWidget {
  const _Figure({required this.label, required this.value, this.note});
  final String label;
  final String value;
  final String? note;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(note == null ? label : '$label · $note', style: text.bodySmall),
        const SizedBox(height: 2),
        Text(value, style: text.titleMedium?.copyWith(fontFeatures: _figures)),
      ],
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({required this.icon, required this.color, required this.text});
  final IconData icon;
  final Color color;
  final String text;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.1),
      borderRadius: BorderRadius.circular(Radii.md),
      border: Border.all(color: color.withValues(alpha: 0.35)),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(padding: const EdgeInsets.only(top: 1), child: Icon(icon, size: 16, color: color)),
        const SizedBox(width: 8),
        Expanded(child: Text(text, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: color))),
      ],
    ),
  );
}

/// The router's request log: model, time, tokens, what it cost, and whether
/// the model's minimum (floor) applied or the request failed (not charged).
class RequestList extends StatelessWidget {
  const RequestList({super.key, required this.requests});
  final List<RouterRequest> requests;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final text = Theme.of(context).textTheme;
    return SettingsGroup(
      children: [
        for (final r in requests)
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Icon(
                    !r.ok
                        ? LucideIcons.circleX
                        : r.isSearch
                        ? LucideIcons.search
                        : r.isImage
                        ? LucideIcons.image
                        : LucideIcons.messageSquare,
                    size: 16,
                    color: r.ok ? p.muted : p.danger,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(r.model, style: text.bodyMedium, maxLines: 1, overflow: TextOverflow.ellipsis),
                      const SizedBox(height: 2),
                      Text(
                        [
                          _clock(r.at),
                          if (r.isSearch) tr('web search'),
                          if (!r.isImage) '${_compact(r.inputTokens + r.outputTokens)} ${tr('tokens')}',
                          if (r.inputTokens > 0 && r.cacheReadTokens > 0)
                            tr('{n}% cache').replaceAll('{n}', '${(r.cacheReadTokens / r.inputTokens * 100).round()}'),
                          if (r.thinkingEffort case final e?) thinkingLabel(e),
                        ].join(' · '),
                        style: text.bodySmall?.copyWith(fontFeatures: _figures),
                      ),
                      if (!r.ok && r.error != null)
                        Text(r.error!, maxLines: 2, overflow: TextOverflow.ellipsis, style: text.bodySmall?.copyWith(color: p.danger)),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      r.ok ? _creditText(r.credits ?? 0, precise: true) : tr('Not charged'),
                      style: text.titleSmall?.copyWith(fontFeatures: _figures, color: r.ok ? null : p.muted),
                    ),
                    if (r.ok && r.floor != null) ...[
                      const SizedBox(height: 4),
                      Pill(tr('Minimum'), color: p.warning),
                    ],
                  ],
                ),
              ],
            ),
          ),
      ],
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
