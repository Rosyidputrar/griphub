import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../agent/agent_controller.dart';
import '../agent/models.dart';
import 'errors.dart';
import 'settings_screen.dart';
import 'i18n.dart';
import '../agent/pricing.dart';
import 'kit.dart';
import 'theme.dart';

Future<void> showModelSheet(BuildContext context, AgentController agent) {
  agent.refreshProviders();
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => _ModelSheet(agent: agent),
  );
}

class _ModelSheet extends StatefulWidget {
  const _ModelSheet({required this.agent});
  final AgentController agent;

  @override
  State<_ModelSheet> createState() => _ModelSheetState();
}

class _ModelSheetState extends State<_ModelSheet> {
  String query = '';

  /// The model being switched to. The sheet stays open, with a spinner on its row, until the host has it: then it
  /// closes; if it fails, the sheet stays and says why.
  String? _saving;

  /// Why the last switch did not happen, shown at the top of the sheet (a snackbar would sit behind it).
  String? _error;

  Future<void> _pick(ModelInfo model) async {
    if (_saving != null) return;
    if (widget.agent.model?.key == model.key) return Navigator.of(context).pop();
    setState(() {
      _saving = model.key;
      _error = null;
    });
    try {
      await widget.agent.setModel(model);
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) setState(() => _error = friendlyError(e));
    } finally {
      if (mounted) setState(() => _saving = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final text = Theme.of(context).textTheme;
    return ListenableBuilder(
      listenable: Listenable.merge([widget.agent, Appearance.instance]),
      builder: (context, _) {
        final agent = widget.agent;
        final appearance = Appearance.instance;
        final q = query.toLowerCase();
        final filtered = agent.models
            .where((m) => q.isEmpty || m.name.toLowerCase().contains(q) || m.key.toLowerCase().contains(q))
            .toList();
        final byProvider = <String, List<ModelInfo>>{};
        for (final m in filtered) {
          byProvider.putIfAbsent(m.provider, () => []).add(m);
        }
        final names = {for (final pr in agent.providers) pr.id: pr.name};
        // Pinned above the provider groups, only when not searching: the
        // favorites the user starred, in starring order.
        final favorites = favoriteModelsInOrder(agent.models, appearance.favoriteModels);

        return DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.7,
          maxChildSize: 0.95,
          builder: (context, scroll) => Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                child: Row(
                  children: [
                    Expanded(child: Text(tr('Model'), style: text.titleLarge)),
                    TextButton(
                      onPressed: () {
                        final nav = Navigator.of(context)..pop();
                        nav.push(MaterialPageRoute(builder: (_) => SettingsScreen(agent: agent)));
                      },
                      child: Text(tr('Providers')),
                    ),
                  ],
                ),
              ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
                  child: SizedBox(
                    width: double.infinity,
                    child: Text(
                      '${tr('Could not switch the model')}: $_error',
                      style: text.bodySmall?.copyWith(color: p.danger),
                    ),
                  ),
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                child: TextField(
                  onChanged: (v) => setState(() => query = v),
                  decoration: InputDecoration(
                    hintText: tr('Search models'),
                    prefixIcon: Icon(LucideIcons.search, size: 18),
                  ),
                ),
              ),
              Expanded(
                child: agent.models.isEmpty
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(32),
                          child: Text(
                            tr('No models yet. Connect a provider to see its models here.'),
                            style: text.bodyMedium?.copyWith(color: p.muted),
                            textAlign: TextAlign.center,
                          ),
                        ),
                      )
                    : ListView(
                        controller: scroll,
                        padding: const EdgeInsets.only(bottom: 24),
                        children: [
                          if (q.isEmpty && favorites.isNotEmpty) ...[
                            Padding(
                              padding: const EdgeInsets.fromLTRB(20, 16, 20, 6),
                              child: Text(tr('Favorites').toUpperCase(), style: text.labelSmall),
                            ),
                            for (final m in favorites) _ModelTile(model: m, agent: agent, saving: _saving, onPick: _pick),
                          ],
                          for (final entry in byProvider.entries) ...[
                            Padding(
                              padding: const EdgeInsets.fromLTRB(20, 16, 20, 6),
                              child: Text((names[entry.key] ?? entry.key).toUpperCase(), style: text.labelSmall),
                            ),
                            for (final m in entry.value)
                              _ModelTile(model: m, agent: agent, saving: _saving, onPick: _pick),
                          ],
                        ],
                      ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _ModelTile extends StatelessWidget {
  const _ModelTile({required this.model, required this.agent, required this.saving, required this.onPick});
  final ModelInfo model;
  final AgentController agent;

  /// The key of the model being switched to, if any: that row spins, the others wait.
  final String? saving;
  final Future<void> Function(ModelInfo) onPick;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final selected = agent.model?.key == model.key;
    final isFav = Appearance.instance.isFavorite(model.key);
    final details = [
      if (model.contextWindow != null && model.contextWindow! > 0)
        '${formatTokens(model.contextWindow!)} ${tr('context')}',
      if (model.maxTokens != null && model.maxTokens! > 0) '${formatTokens(model.maxTokens!)} ${tr('output')}',
      if (model.reasoning) tr('reasoning'),
      if (model.acceptsImages) tr('vision'),
    ].join('  ·  ');
    final price = model.pricing;
    final available = price?.available ?? true;
    final text = Theme.of(context).textTheme;
    return ListTile(
      enabled: available,
      onTap: saving != null ? null : () => onPick(model),
      title: Text(model.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (details.isNotEmpty) Text(details),
          if (!available)
            Text(tr('Not available right now'), style: text.bodySmall?.copyWith(color: p.danger))
          else if (price != null && price.credits != null)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Wrap(
                spacing: 6,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text(
                    [
                      tr('{n} credits / 1M').replaceAll('{n}', localNumber(formatCredits(price.credits!))),
                      if (price.floor != null) tr('min {n} per request').replaceAll('{n}', localNumber(formatCredits(price.floor!))),
                    ].join('  ·  '),
                    style: text.bodySmall,
                  ),
                  if (price.onPromo)
                    Pill(
                      price.promoEndsAt == null
                          ? tr('Promo · normally {n}').replaceAll('{n}', localNumber(formatCredits(price.list!)))
                          : tr('Promo until {date} · normally {n}')
                                .replaceAll('{date}', '${price.promoEndsAt!.toLocal().day}/${price.promoEndsAt!.toLocal().month}')
                                .replaceAll('{n}', localNumber(formatCredits(price.list!))),
                      color: p.success,
                    ),
                ],
              ),
            ),
        ],
      ),
      // The star is its own button, so tapping it never selects the model.
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            onPressed: () => Appearance.instance.toggleFavorite(model.key),
            tooltip: isFav ? tr('Remove from favorites') : tr('Add to favorites'),
            icon: Icon(LucideIcons.star, size: 18, color: isFav ? p.warning : p.muted),
          ),
          // The check keeps its slot on every row, so the stars line up down the list.
          SizedBox(
            width: 22,
            child: saving == model.key
                ? const Center(child: BusySpinner())
                : selected
                ? Icon(LucideIcons.check, size: 18, color: p.text)
                : null,
          ),
        ],
      ),
    );
  }
}
