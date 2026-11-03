import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../agent/agent_controller.dart';
import '../agent/integrations.dart';
import '../agent/pricing.dart';
import 'errors.dart';
import 'i18n.dart';
import 'image_gen_screen.dart';
import 'image_tool_card.dart';
import 'kit.dart';
import 'subagent_settings_screen.dart';
import 'theme.dart';

/// Defaults, as the host's IMAGE_DEFAULTS (agent/src/integrations.ts).
const imageDefaultAutoCredits = 10.0;
const imageDefaultMaxPerCall = 4;
const imageDefaultDailyCredits = 50.0;

/// The most pictures one call may make (the host's IMAGE_MAX_PER_CALL_CAP).
const imageMaxPerCallCap = 8;

String _credits(double v) => '${localNumber(formatCredits(v))} ${tr('credits')}';

/// One line for the Settings row: the limits in force.
String imageLimitsSummary(AppSettings? s) {
  if (s != null && !s.imageAgentTool) return tr('The agent does not make pictures');
  final auto = s?.imageAutoCredits ?? imageDefaultAutoCredits;
  final day = s?.imageDailyCredits ?? imageDefaultDailyCredits;
  final per = s?.imageMaxPerCall ?? imageDefaultMaxPerCall;
  return [
    auto == 0 ? tr('Always ask') : tr('Up to {n} without asking').replaceAll('{n}', _credits(auto)),
    tr('{n} per request').replaceAll('{n}', '$per'),
    day == 0 ? tr('No daily picture limit') : tr('{n} a day').replaceAll('{n}', _credits(day)),
  ].join(' • ');
}

/// Today's pictures and the image models with their prices, from the host (`image_usage`).
class _Usage {
  _Usage(Map<String, dynamic> j)
    : count = (j['count'] as num?)?.toInt() ?? 0,
      credits = (j['credits'] as num?)?.toDouble() ?? 0,
      cheapest = j['cheapest'] as String?,
      modelsError = j['modelsError'] as String?,
      models = [
        for (final m in (j['models'] as List? ?? const []).whereType<Map>())
          (id: m['id'] as String, credits: (m['credits'] as num?)?.toDouble()),
      ];
  final int count;
  final double credits;
  final String? cheapest;
  final String? modelsError;
  final List<({String id, double? credits})> models;
}

/// Settings → Pictures: what the agent may spend on pictures (the generate_image tool) and with which model, inside
/// the account's daily budget. The limits are read by the host on every call; nothing here is per chat.
class ImageSettingsScreen extends StatefulWidget {
  const ImageSettingsScreen({super.key, required this.agent});
  final AgentController agent;

  @override
  State<ImageSettingsScreen> createState() => _ImageSettingsScreenState();
}

class _ImageSettingsScreenState extends State<ImageSettingsScreen> {
  AgentController get agent => widget.agent;
  Integrations get it => agent.integrations;

  _Usage? _usage;
  String? _usageError;

  @override
  void initState() {
    super.initState();
    it.refreshSettings().catchError((_) => it.settings ?? AppSettings(const {}));
    _loadUsage();
  }

  Future<void> _loadUsage({bool refresh = false}) async {
    try {
      final j = await agent.client.call<Map>('image_usage', {'refresh': refresh});
      if (mounted) setState(() => (_usage = _Usage(j.cast<String, dynamic>()), _usageError = null));
    } catch (e) {
      if (mounted) setState(() => _usageError = friendlyError(e));
    }
  }

  Future<bool> _save(Map<String, dynamic> patch) async {
    try {
      await it.updateSettings(patch);
      return true;
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(friendlyError(e))));
      return false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final text = Theme.of(context).textTheme;
    return ListenableBuilder(
      listenable: it,
      builder: (context, _) {
        final s = it.settings;
        final compact = Appearance.instance.compact;
        final gap = compact ? 8.0 : 12.0;
        EdgeInsets label() => EdgeInsets.fromLTRB(4, compact ? 14 : 22, 4, compact ? 8 : 10);
        Widget note(String t) => Padding(
          padding: EdgeInsets.fromLTRB(4, gap - 4, 4, 0),
          child: Text(t, style: text.bodySmall),
        );
        final day = s?.imageDailyCredits ?? imageDefaultDailyCredits;
        final usage = _usage;
        final model = s?.imageModel ?? 'auto';
        final models = usage?.models ?? const [];
        final cheapest = usage?.cheapest;
        final cheapestRate = models.where((m) => m.id == cheapest).firstOrNull?.credits;
        final overLimit = s?.imageOverLimit ?? 'ask';
        final toolOn = s?.imageAgentTool ?? true;

        return Scaffold(
          appBar: AppBar(title: Text(tr('Pictures'))),
          body: RefreshIndicator(
            onRefresh: () => Future.wait([it.refreshSettings(), _loadUsage(refresh: true)]),
            child: ListView(
              padding: EdgeInsets.fromLTRB(16, 4, 16, compact ? 24 : 40),
              children: [
                if (s != null && !s.hasImageSettings)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: ErrorNotice(
                      error: tr('The agent on this device is too old for picture limits. Update it first.'),
                    ),
                  ),
                // The limits in force, and today's picture spend against the day's cap.
                SurfaceCard(
                  padding: EdgeInsets.all(compact ? 14 : 18),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          IconTile(icon: LucideIcons.image, color: imageViolet, size: compact ? 36 : 40),
                          SizedBox(width: compact ? 12 : 14),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(tr('Active limits'), style: text.titleMedium),
                                const SizedBox(height: 2),
                                Text(imageLimitsSummary(s), style: text.bodyMedium),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      Row(
                        children: [
                          Text(tr('Today'), style: text.labelMedium),
                          const Spacer(),
                          Flexible(
                            child: Text(
                              usage == null
                                  ? (_usageError ?? '…')
                                  : (day > 0
                                            ? tr('{a} of {b} · {n} pictures').replaceAll('{b}', _credits(day))
                                            : tr('{a} · {n} pictures'))
                                        .replaceAll('{a}', _credits(usage.credits))
                                        .replaceAll('{n}', '${usage.count}'),
                              textAlign: TextAlign.end,
                              maxLines: 2,
                              style: text.labelMedium?.copyWith(color: p.muted),
                            ),
                          ),
                        ],
                      ),
                      if (day > 0) ...[
                        const SizedBox(height: 8),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(4),
                          child: LinearProgressIndicator(
                            value: ((usage?.credits ?? 0) / day).clamp(0, 1).toDouble(),
                            minHeight: 6,
                            color: (usage?.credits ?? 0) >= day ? p.danger : imageViolet,
                            backgroundColor: p.raised,
                          ),
                        ),
                      ],
                      const SizedBox(height: 8),
                      Text(
                        (s?.dailyBudget ?? 0) > 0
                            ? tr('Also within the account\'s daily budget of {n} (Usage).')
                                  .replaceAll('{n}', _credits(s!.dailyBudget))
                            : tr('Pictures also count toward the account\'s daily budget, when one is set (Usage).'),
                        style: text.bodySmall,
                      ),
                    ],
                  ),
                ),

                SectionLabel(tr('Agent'), padding: label()),
                SettingsGroup(
                  children: [
                    SettingsRow(
                      icon: LucideIcons.bot,
                      color: p.accent,
                      title: tr('Agent can make pictures'),
                      subtitle: tr('Ask in any chat: "make a logo for…"'),
                      onTap: () => _save({'imageAgentTool': !toolOn}),
                      trailing: LabeledSwitch(
                        label: tr('Agent can make pictures'),
                        value: toolOn,
                        onChanged: (v) => _save({'imageAgentTool': v}),
                      ),
                    ),
                    SettingsRow(
                      icon: LucideIcons.moon,
                      color: p.warning,
                      title: tr('In background runs'),
                      subtitle: tr('Scheduled tasks and runs nobody watches; over a limit they are refused'),
                      onTap: () => _save({'imageUnattended': !(s?.imageUnattended ?? false)}),
                      trailing: LabeledSwitch(
                        label: tr('In background runs'),
                        value: s?.imageUnattended ?? false,
                        onChanged: (v) => _save({'imageUnattended': v}),
                      ),
                    ),
                  ],
                ),

                SectionLabel(tr('Default model'), padding: label()),
                SettingsGroup(
                  children: [
                    _ModelRow(
                      title: tr('Cheapest'),
                      subtitle: cheapest == null
                          ? tr('Picked by the live prices on every request')
                          : '${tr('Now')}: $cheapest${cheapestRate == null ? '' : ' · ${_credits(cheapestRate)}'}',
                      selected: model == 'auto',
                      onTap: () => _save({'imageModel': 'auto'}),
                    ),
                    for (final m in models)
                      _ModelRow(
                        title: m.id,
                        subtitle: m.credits == null
                            ? tr('Price not known')
                            : tr('{n} per picture').replaceAll('{n}', _credits(m.credits!)),
                        selected: model == m.id,
                        onTap: () => _save({'imageModel': m.id}),
                      ),
                    // A default the router no longer lists is still shown, so it can be seen and changed.
                    if (model != 'auto' && usage != null && !models.any((m) => m.id == model))
                      _ModelRow(
                        title: model,
                        subtitle: tr('No longer offered: the cheapest is used instead'),
                        selected: true,
                        onTap: () => _save({'imageModel': 'auto'}),
                      ),
                  ],
                ),
                if (usage?.modelsError != null)
                  note(tr('Could not read the image models: {e}').replaceAll('{e}', usage!.modelsError!)),
                note(tr('The agent uses this unless you name a model in the chat.')),

                SectionLabel(tr('Without asking, up to'), padding: label()),
                LimitChooser(
                  key: const ValueKey('auto'),
                  value: s?.imageAutoCredits ?? imageDefaultAutoCredits,
                  presets: const [5, 10, 25],
                  format: _credits,
                  hint: tr('Credits, e.g. 15'),
                  decimals: true,
                  max: 100000,
                  zeroLabel: tr('Always ask'),
                  zeroIcon: LucideIcons.shieldQuestion,
                  zeroFirst: true,
                  onSave: (v) => _save({'imageAutoCredits': v}),
                ),
                note(
                  tr(
                    'Per request to the agent, all its pictures together. Above it you are asked first, with the cost.',
                  ),
                ),

                SectionLabel(tr('Pictures per request'), padding: label()),
                Builder(
                  builder: (context) {
                    // A value set elsewhere (another phone, an older app) is shown as one of the choices.
                    final per = s?.imageMaxPerCall ?? imageDefaultMaxPerCall;
                    final choices = {
                      ...const [1, 2, 4, imageMaxPerCallCap],
                      per,
                    }.toList()..sort();
                    return PillSegments<int>(
                      value: per,
                      options: {for (final n in choices) n: '$n'},
                      onChanged: (v) {
                        HapticFeedback.selectionClick();
                        _save({'imageMaxPerCall': v});
                      },
                    );
                  },
                ),
                note(tr('More than this is never made in one go; the agent is told how many were left out.')),

                SectionLabel(tr('Daily picture limit'), padding: label()),
                LimitChooser(
                  key: const ValueKey('day'),
                  value: day,
                  presets: const [25, 50, 100],
                  format: _credits,
                  hint: tr('Credits, e.g. 40'),
                  decimals: true,
                  max: 100000,
                  onSave: (v) => _save({'imageDailyCredits': v}),
                ),
                note(tr('Once reached, pictures are refused until tomorrow (WIB); chatting goes on.')),

                SectionLabel(tr('Over a limit'), padding: label()),
                PillSegments<String>(
                  value: overLimit,
                  options: {'ask': tr('Ask first'), 'cheapest': tr('Use cheapest'), 'refuse': tr('Refuse')},
                  onChanged: (v) {
                    HapticFeedback.selectionClick();
                    _save({'imageOverLimit': v});
                  },
                ),
                note(switch (overLimit) {
                  'cheapest' => tr('Switches to the cheapest model when that fits; asks only when even that does not.'),
                  'refuse' => tr('Nothing over the limit is made; the agent tells you which limit stopped it.'),
                  _ => tr('A card shows the model, the count and the cost; nothing is made until you allow it.'),
                }),
                note(tr('The daily limits are never asked about: they always refuse.')),

                SectionLabel(tr('Make one yourself'), padding: label()),
                SettingsGroup(
                  children: [
                    SettingsRow(
                      icon: LucideIcons.wandSparkles,
                      color: imageViolet,
                      title: tr('Generate image'),
                      subtitle: tr('Pick the model and size yourself; your earlier pictures are here too'),
                      onTap: () async {
                        await Navigator.of(context)
                            .push(MaterialPageRoute(builder: (_) => ImageGenScreen(agent: agent)));
                        _loadUsage();
                      },
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _ModelRow extends StatelessWidget {
  const _ModelRow({required this.title, required this.subtitle, required this.selected, required this.onTap});
  final String title;
  final String subtitle;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Semantics(
      selected: selected,
      inMutuallyExclusiveGroup: true,
      child: SettingsRow(
        title: title,
        subtitle: subtitle,
        onTap: selected ? null : onTap,
        trailing: selected ? Icon(LucideIcons.check, size: 18, color: p.text) : const SizedBox(width: 18),
      ),
    );
  }
}
