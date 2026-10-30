import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../agent/agent_client.dart';
import '../agent/agent_controller.dart';
import '../agent/models.dart';
import 'kit.dart';
import 'i18n.dart';
import 'theme.dart';

/// The one endpoint this build talks to; the host enforces the same values.
const griphubBaseUrl = 'https://griphubrouter.web.id/v1';

/// GripHub Router setup: paste an API key and the model list loads itself.
/// There is nothing else to configure — this build has no other provider.
class GripHubScreen extends StatefulWidget {
  const GripHubScreen({super.key, required this.agent});
  final AgentController agent;

  @override
  State<GripHubScreen> createState() => _GripHubScreenState();
}

class _GripHubScreenState extends State<GripHubScreen> {
  final _apiKey = TextEditingController();
  bool _showKey = false;
  bool _busy = false;
  bool _loading = true;
  String? _problem;
  CustomProvider? _existing;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final all = await widget.agent.customProviders();
      _existing = all.where((p) => p.id == 'griphub').firstOrNull;
    } catch (_) {
      _existing = null;
    }
    if (mounted) setState(() => _loading = false);
  }

  @override
  void dispose() {
    _apiKey.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final key = _apiKey.text.trim();
    if (key.isEmpty && _existing?.hasKey != true) {
      setState(() => _problem = 'Enter your API key first.');
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _problem = null;
    });
    try {
      final found = await widget.agent.fetchProviderModels(
        api: 'openai-completions',
        baseUrl: griphubBaseUrl,
        apiKey: key,
        providerId: key.isEmpty ? 'griphub' : null,
      );
      await widget.agent.saveCustomProvider({
        'id': 'griphub',
        'name': 'GripHub Router',
        'api': 'openai-completions',
        'baseUrl': griphubBaseUrl,
        'apiKey': key,
        'models': [for (final m in found) m.json],
      });
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${tr('GripHub connected')} · ${found.length} ${tr('models available')}')),
      );
      Navigator.of(context).pop(true);
    } on AgentError catch (e) {
      if (mounted) setState(() => _problem = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  bool _refreshing = false;

  /// New GripHub models appear (and retired ones go) without retyping the key.
  Future<void> _refreshModels() async {
    setState(() {
      _refreshing = true;
      _problem = null;
    });
    final messenger = ScaffoldMessenger.of(context);
    try {
      final r = await widget.agent.integrations.refreshGripHubModels();
      await widget.agent.refreshProviders();
      await _load();
      final added = (r['added'] as List?)?.length ?? 0;
      final removed = (r['removed'] as List?)?.length ?? 0;
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            added == 0 && removed == 0
                ? tr('Models are up to date ({n}).').replaceAll('{n}', '${r['count']}')
                : tr('{a} new, {b} removed · {n} models').replaceAll('{a}', '$added').replaceAll('{b}', '$removed').replaceAll('{n}', '${r['count']}'),
          ),
        ),
      );
    } on AgentError catch (e) {
      if (mounted) setState(() => _problem = e.message);
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  Future<void> _remove() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr('Remove API key?')),
        content: Text(tr('The agent cannot use any model until you add a key again.')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(tr('Cancel'))),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: context.palette.danger),
            child: Text(tr('Remove')),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await widget.agent.deleteCustomProvider('griphub');
      if (mounted) Navigator.of(context).pop(true);
    } on AgentError catch (e) {
      if (mounted) setState(() => _problem = e.message);
    }
  }

  String _details(CustomModel m) => [
    if (m.name != null) m.id,
    if (m.contextWindow != null) '${formatTokens(m.contextWindow!)} ${tr('context')}',
    if (m.maxTokens != null) '${formatTokens(m.maxTokens!)} ${tr('output')}',
  ].join('  ·  ');

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final text = Theme.of(context).textTheme;
    final existing = _existing;
    return Scaffold(
      appBar: AppBar(
        title: Text(tr('GripHub Router')),
        actions: [
          if (existing?.hasKey == true)
            IconButton(
              tooltip: tr('Remove API key'),
              onPressed: _busy ? null : _remove,
              icon: Icon(LucideIcons.trash2, size: 18, color: p.danger),
            ),
        ],
      ),
      body: _loading
          ? const Center(child: BusySpinner.page())
          : ListView(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
              children: [
                const Center(child: LogoMark(size: 76)),
                const SizedBox(height: 14),
                Text(tr('GripHub Router'), textAlign: TextAlign.center, style: text.titleLarge),
                const SizedBox(height: 6),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(LucideIcons.lock, size: 13, color: p.muted),
                    const SizedBox(width: 6),
                    Text(
                      griphubBaseUrl,
                      style: TextStyle(fontFamily: mono, fontSize: 12.5, color: p.muted),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Text(
                  tr(
                    'This build only connects to GripHub Router. Paste your API key and the models load automatically.',
                  ),
                  textAlign: TextAlign.center,
                  style: text.bodyMedium?.copyWith(color: p.muted),
                ),
                const SizedBox(height: 22),
                if (existing?.hasKey == true) ...[
                  Row(
                    children: [
                      Pill(tr('Connected'), color: p.success, dot: true),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          '${existing!.models.length} ${tr('models available')}',
                          style: text.bodySmall?.copyWith(color: p.muted),
                        ),
                      ),
                      TextButton.icon(
                        onPressed: _busy || _refreshing ? null : _refreshModels,
                        icon: _refreshing
                            ? const BusySpinner(size: 14)
                            : const Icon(LucideIcons.refreshCw, size: 16),
                        label: Text(tr('Update models')),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                ],
                TextField(
                  controller: _apiKey,
                  autocorrect: false,
                  enableSuggestions: false,
                  obscureText: !_showKey,
                  style: const TextStyle(fontFamily: mono, fontSize: 13),
                  decoration: InputDecoration(
                    labelText: tr('API key'),
                    hintText: existing?.hasKey == true ? tr('Saved. Leave empty to keep it') : 'griphub-…',
                    suffixIcon: IconButton(
                      tooltip: _showKey ? tr('Hide key') : tr('Show key'),
                      onPressed: () => setState(() => _showKey = !_showKey),
                      icon: Icon(_showKey ? LucideIcons.eyeOff : LucideIcons.eye, size: 18),
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  tr('The key is stored encrypted on this device.'),
                  style: text.bodySmall?.copyWith(color: p.muted),
                ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(
                    onPressed: () => widget.agent.client.openUrl('https://griphubrouter.web.id'),
                    child: Text(tr('Get a key at griphubrouter.web.id')),
                  ),
                ),
                const SizedBox(height: 10),
                PrimaryButton(label: tr('Save & load models'), icon: LucideIcons.check, busy: _busy, onPressed: _save),
                if (_problem != null) ...[
                  const SizedBox(height: 12),
                  Text(tr(_problem!), style: text.bodySmall?.copyWith(color: p.danger)),
                ],
                if (existing != null && existing.models.isNotEmpty) ...[
                  const SizedBox(height: 26),
                  Text('${tr('Models')} (${existing.models.length})', style: text.titleSmall),
                  const SizedBox(height: 6),
                  for (final m in existing.models)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 5),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            m.name ?? m.id,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontFamily: mono, fontSize: 12.5),
                          ),
                          if (_details(m).isNotEmpty)
                            Text(_details(m), style: text.bodySmall?.copyWith(color: p.muted)),
                        ],
                      ),
                    ),
                ],
              ],
            ),
    );
  }
}
