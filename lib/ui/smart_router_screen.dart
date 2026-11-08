import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../agent/agent_controller.dart';
import '../agent/integrations.dart';
import '../agent/models.dart';
import '../agent/pricing.dart';
import 'errors.dart';
import 'i18n.dart';
import 'kit.dart';
import 'theme.dart';

/// The class names the router logs (agent/src/smartrouter.ts DIFFICULTY_NAMES), for people.
String smartRouterClassName(int? band) => switch (band) {
  0 => tr('light'),
  1 => tr('medium'),
  2 => tr('heavy'),
  _ => '',
};

/// The smart router's own mark (assets/brand/smart_router.png): on the picker's entry, its settings, its decisions,
/// and, small, by a model the router picked. [semanticLabel] says it to a screen reader where it carries meaning.
class SmartRouterMark extends StatelessWidget {
  const SmartRouterMark({super.key, this.size = 16, this.semanticLabel});
  final double size;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) => Image.asset(
    'assets/brand/smart_router.png',
    width: size,
    height: size,
    filterQuality: FilterQuality.medium,
    semanticLabel: semanticLabel,
    excludeFromSemantics: semanticLabel == null,
  );
}

/// The mark in a settings row's leading slot, the size of the other rows' icon tiles.
class SmartRouterTile extends StatelessWidget {
  const SmartRouterTile({super.key, this.size = 36});
  final double size;

  @override
  Widget build(BuildContext context) => SizedBox.square(dimension: size, child: Center(child: SmartRouterMark(size: size * 0.8)));
}

/// A reason code of a routing decision, in words (agent/src/smartrouter.ts Decision.why).
String smartRouterReason(String code) => switch (code) {
  'plain-chat' => tr('plain chat'),
  'coding-chat' => tr('coding chat'),
  'heavy-words' => tr('heavy work asked'),
  'task-words' => tr('a task, not just a question'),
  'very-long' => tr('very long message'),
  'long' => tr('long message'),
  'code' => tr('code or an error log'),
  'long-conversation' => tr('long conversation'),
  'image' => tr('picture attached'),
  'floor' => tr('stronger after an earlier failure'),
  'vision' => tr('needs to read pictures'),
  'below' => tr('no stronger model fits'),
  'cheapest' => tr('cheapest that fits'),
  'error' => tr('the last reply failed'),
  'cut-off' => tr('the last reply was cut off'),
  'resent' => tr('the same request was sent again'),
  'rejected' => tr('you said the last answer was wrong'),
  'calm' => tr('the last turns went well'),
  'tools' => tr('none can use tools'),
  'context' => tr('none holds this conversation'),
  'price' => tr('none has a live price'),
  _ => code,
};

/// One line for Settings: on or off, and how many models are kept out.
String smartRouterSummary(AppSettings? s) {
  if (s?.smartRouter == false) return tr('Off');
  final n = s?.smartRouterBlocked.length ?? 0;
  return n == 0
      ? tr('Picks the cheapest model that can do each message')
      : tr('On · {n} models never picked').replaceAll('{n}', '$n');
}

/// Settings → Smart router: the main switch, and the models it must never pick.
class SmartRouterSettingsScreen extends StatefulWidget {
  const SmartRouterSettingsScreen({super.key, required this.agent});
  final AgentController agent;

  @override
  State<SmartRouterSettingsScreen> createState() => _SmartRouterSettingsScreenState();
}

class _SmartRouterSettingsScreenState extends State<SmartRouterSettingsScreen> {
  AgentController get agent => widget.agent;
  Integrations get it => agent.integrations;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    it.refreshSettings().catchError((_) => it.settings ?? AppSettings(const {}));
  }

  Future<void> _save(Map<String, dynamic> patch) async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      await it.updateSettings(patch);
      await agent.refreshState();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(friendlyError(e))));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return ListenableBuilder(
      listenable: Listenable.merge([it, agent]),
      builder: (context, _) {
        final s = it.settings;
        final on = s?.smartRouter ?? true;
        final blocked = s?.smartRouterBlocked ?? const <String>[];
        final models = agent.models.where((m) => m.provider == 'griphub').toList();
        return Scaffold(
          appBar: AppBar(title: Text(tr('Smart router'))),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 40),
            children: [
              SettingsGroup(
                children: [
                  SettingsRow(
                    leading: const SmartRouterTile(),
                    title: tr('Smart router'),
                    subtitle: tr('Lets a chat use "Automatic (Smart)" in the model picker'),
                    trailing: LabeledSwitch(
                      label: tr('Smart router'),
                      value: on,
                      onChanged: _saving ? null : (v) => _save({'smartRouter': v}),
                    ),
                  ),
                ],
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 10, 4, 0),
                child: Text(
                  tr(
                    'For each message it picks the cheapest model that can do it, from what GripHub Router says about each model and its live price. It climbs to a stronger model when a reply fails or you say it was wrong. Choosing a model yourself stops it for that chat. Choosing costs nothing: the usual price of the chosen model applies.',
                  ),
                  style: text.bodySmall,
                ),
              ),
              SectionLabel(tr('Never pick')),
              if (models.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(8),
                  child: Text(tr('No models yet. Connect a provider to see its models here.'), style: text.bodySmall),
                )
              else
                SettingsGroup(
                  children: [
                    for (final m in models)
                      // The tile paints its splash on a Material: the group's own background would hide it.
                      Material(
                        type: MaterialType.transparency,
                        child: CheckboxListTile(
                        value: blocked.contains(m.id),
                        title: Text(m.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                        secondary: BrandTile(id: m.provider, model: m.id, size: 28),
                        onChanged: _saving
                            ? null
                            : (v) => _save({
                                'smartRouterBlocked': v == true
                                    ? [...blocked, m.id]
                                    : blocked.where((id) => id != m.id).toList(),
                              }),
                        ),
                      ),
                  ],
                ),
            ],
          ),
        );
      },
    );
  }
}

/// A chat's routing log: every model the smart router picked, why, and what it was expected to cost.
class RoutingLogScreen extends StatefulWidget {
  const RoutingLogScreen({super.key, required this.agent, this.sessionId});
  final AgentController agent;
  final String? sessionId;

  @override
  State<RoutingLogScreen> createState() => _RoutingLogScreenState();
}

class _RoutingLogScreenState extends State<RoutingLogScreen> {
  List<RoutingDecision>? _log;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final log = await widget.agent.routingLogOf(widget.sessionId);
      if (mounted) setState(() => _log = log);
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final log = _log;
    return Scaffold(
      appBar: AppBar(title: Text(tr('Smart router decisions'))),
      body: _error != null
          ? ErrorNotice(error: _error, onRetry: _load, center: true)
          : log == null
          ? const Center(child: BusySpinner.page())
          : log.isEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Text(
                  tr('This chat has not used the smart router.'),
                  style: Theme.of(context).textTheme.bodyMedium,
                  textAlign: TextAlign.center,
                ),
              ),
            )
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 40),
              children: [
                SettingsGroup(children: [for (final d in log.reversed) RoutingDecisionRow(decision: d)]),
              ],
            ),
    );
  }
}

/// One decision: what happened as the title (the icon sits by it), why and the estimate in the one quiet colour.
class RoutingDecisionRow extends StatelessWidget {
  const RoutingDecisionRow({super.key, required this.decision});
  final RoutingDecision decision;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final text = Theme.of(context).textTheme;
    final d = decision;
    final (IconData? icon, String title) = switch (d.kind) {
      'route' => (
        null,
        tr('Message {n}: {model}').replaceAll('{n}', '${d.turn + 1}').replaceAll('{model}', d.modelName ?? d.model ?? ''),
      ),
      'escalate' => (
        LucideIcons.trendingUp,
        tr('Class raised to {class}').replaceAll('{class}', smartRouterClassName(d.band)),
      ),
      'relax' => (
        LucideIcons.trendingDown,
        tr('Class lowered to {class}').replaceAll('{class}', smartRouterClassName(d.band)),
      ),
      'none' => (LucideIcons.circleAlert, tr('No model fit message {n}').replaceAll('{n}', '${d.turn + 1}')),
      'manual' => (LucideIcons.hand, tr('Chosen by hand: {model}').replaceAll('{model}', d.modelName ?? d.model ?? '')),
      'fallback' => (LucideIcons.lifeBuoy, tr('Fallback model: {model}').replaceAll('{model}', d.modelName ?? d.model ?? '')),
      'on' => (LucideIcons.toggleRight, tr('Automatic choice turned on')),
      _ => (LucideIcons.toggleLeft, tr('Automatic choice turned off')),
    };
    final details = [
      if (d.kind == 'route' && d.band != null) tr('class {class}').replaceAll('{class}', smartRouterClassName(d.band)),
      if (d.estimate != null) tr('about {n}').replaceAll('{n}', '${localNumber(formatCredits(d.estimate!))} ${tr('credits')}'),
      // Codes worded in the app's language; a host too old to send them leaves its own text.
      if (d.why.isEmpty) d.reason else d.why.map(smartRouterReason).join(', '),
    ].where((x) => x.isNotEmpty).join(' · ');
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // The icon belongs to the title line, not to the middle of the block.
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: icon == null ? const SmartRouterMark(size: 16) : Icon(icon, size: 16, color: d.kind == 'none' ? p.danger : p.text),
              ),
              const SizedBox(width: 8),
              Expanded(child: Text(title, style: text.titleSmall)),
              Text(
                MaterialLocalizations.of(context).formatTimeOfDay(TimeOfDay.fromDateTime(d.at)),
                style: text.bodySmall?.copyWith(color: p.muted),
              ),
            ],
          ),
          if (details.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(left: 24, top: 3),
              child: Text(details, style: text.bodySmall?.copyWith(color: p.muted)),
            ),
        ],
      ),
    );
  }
}
