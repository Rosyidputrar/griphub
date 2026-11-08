import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../agent/agent_controller.dart';
import '../agent/integrations.dart';
import '../agent/pricing.dart';
import 'errors.dart';
import 'i18n.dart';
import 'kit.dart';

/// One line for Settings: the mode.
String visionTranslatorSummary(AppSettings? s) => switch (s?.visionTranslator ?? 'auto') {
  'ask' => tr('Ask before reading a picture'),
  'off' => tr('Off: pictures go only to models that can see'),
  _ => tr('Reads pictures for models that cannot see'),
};

/// A vision model the translator can use, from the router's metadata (vision_translator_info).
class _VisionModel {
  _VisionModel(Map<String, dynamic> j)
    : id = j['id'] is String ? j['id'] as String : '',
      name = j['name'] is String ? j['name'] as String : (j['id'] is String ? j['id'] as String : ''),
      credits = j['credits'] is num ? (j['credits'] as num).toDouble() : null,
      available = j['available'] != false;
  final String id;
  final String name;
  final double? credits;
  final bool available;
}

/// Settings → Vision translator: when it runs, which model reads, and which models are good enough to (the floor).
class VisionTranslatorScreen extends StatefulWidget {
  const VisionTranslatorScreen({super.key, required this.agent});
  final AgentController agent;

  @override
  State<VisionTranslatorScreen> createState() => _VisionTranslatorScreenState();
}

class _VisionTranslatorScreenState extends State<VisionTranslatorScreen> {
  AgentController get agent => widget.agent;
  Integrations get it => agent.integrations;

  List<_VisionModel>? _models;
  List<String> _defaults = const [];
  String? _current;
  Object? _error;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    it.refreshSettings().catchError((_) => it.settings ?? AppSettings(const {}));
    _load();
  }

  Future<void> _load() async {
    try {
      final r = (await agent.client.call<Map>('vision_translator_info')).cast<String, dynamic>();
      if (!mounted) return;
      setState(() {
        // A row the host sent broken (no id) is left out; the rest of the screen stays.
        _models = [
          for (final m in (r['models'] is List ? r['models'] as List : const [])) if (m is Map) _VisionModel(m.cast<String, dynamic>()),
        ].where((m) => m.id.isNotEmpty).toList()
          ..sort((a, b) => (a.credits ?? 1e9).compareTo(b.credits ?? 1e9));
        _defaults = (r['defaultAllowed'] is List ? r['defaultAllowed'] as List : const []).whereType<String>().toList();
        _current = switch (r['current']) {
          {'name': final String name} => name,
          _ => null,
        };
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _save(Map<String, dynamic> patch) async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      await it.updateSettings(patch);
      await _load();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(friendlyError(e))));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  String _price(_VisionModel m) =>
      m.credits == null ? '' : tr('{n} credits / 1M').replaceAll('{n}', localNumber(formatCredits(m.credits!)));

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return ListenableBuilder(
      listenable: it,
      builder: (context, _) {
        final s = it.settings;
        final mode = s?.visionTranslator ?? 'auto';
        final chosen = s?.visionTranslatorModel;
        final allowed = s?.visionTranslatorAllowed ?? _defaults;
        final models = _models;
        return Scaffold(
          appBar: AppBar(title: Text(tr('Vision translator'))),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 40),
            children: [
              PillSegments<String>(
                value: mode,
                options: {'auto': tr('Automatic'), 'ask': tr('Ask first'), 'off': tr('Off')},
                onChanged: (v) => _saving ? null : _save({'visionTranslator': v}),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 10, 4, 0),
                child: Text(
                  tr(
                    'When the chat\'s model cannot see pictures, a vision model reads the picture into text (what it shows, every readable text, the layout) and the chat\'s model answers from that. Each reading is a paid request, shown under the answer and counted in Usage. The picture stays in the chat.',
                  ),
                  style: text.bodySmall,
                ),
              ),
              if (_current != null && mode != 'off')
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
                  child: Text(tr('Reads now: {model}').replaceAll('{model}', _current!), style: text.bodySmall),
                ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 16),
                  child: ErrorNotice(error: _error, onRetry: _load),
                )
              else if (models == null)
                const Padding(
                  padding: EdgeInsets.all(32),
                  child: Center(child: BusySpinner.page()),
                )
              else if (models.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    tr('GripHub Router lists no vision model with a price right now.'),
                    style: text.bodySmall,
                  ),
                )
              else ...[
                SectionLabel(tr('Translator')),
                SettingsGroup(
                  children: [
                    // The tiles paint their splash on a Material: the group's own background would hide it.
                    Material(
                      type: MaterialType.transparency,
                      child: RadioGroup<String?>(
                        groupValue: chosen,
                        onChanged: (v) => _saving ? null : _save({'visionTranslatorModel': v}),
                        child: Column(
                          children: [
                            RadioListTile<String?>(
                              value: null,
                              title: Text(tr('Automatic')),
                              subtitle: Text(tr('The cheapest approved model')),
                            ),
                            for (final m in models)
                              RadioListTile<String?>(
                                value: m.id,
                                enabled: m.available,
                                title: Text(m.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                                subtitle: Text(_price(m)),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
                SectionLabel(tr('Approved to read pictures')),
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
                  child: Text(
                    tr(
                      'Automatic picks only from these. By default: vision models outside the cheapest third of prices.',
                    ),
                    style: text.bodySmall,
                  ),
                ),
                SettingsGroup(
                  children: [
                    for (final m in models)
                      Material(
                        type: MaterialType.transparency,
                        child: CheckboxListTile(
                          value: allowed.contains(m.id),
                          title: Text(m.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                          subtitle: Text(_price(m)),
                          onChanged: _saving
                              ? null
                              : (v) => _save({
                                  'visionTranslatorAllowed': v == true
                                      ? [...allowed, m.id]
                                      : allowed.where((id) => id != m.id).toList(),
                                }),
                        ),
                      ),
                  ],
                ),
                if (s?.visionTranslatorAllowed != null)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      onPressed: _saving ? null : () => _save({'visionTranslatorAllowed': null}),
                      icon: const Icon(LucideIcons.rotateCcw, size: 16),
                      label: Text(tr('Back to the default list')),
                    ),
                  ),
              ],
            ],
          ),
        );
      },
    );
  }
}
