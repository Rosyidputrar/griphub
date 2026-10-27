import 'package:flutter/material.dart';

import '../agent/agent_controller.dart';
import 'chat_extras.dart';
import 'i18n.dart';
import 'kit.dart';
import 'theme.dart';

/// Subagent settings: global cost/time limits (presets + free custom input),
/// approval mode, and notification toggles.
///
/// Limits are global for all subagents and are read by the host from Settings
/// at subagent start. There is deliberately no per-creation form: creating a
/// subagent is purely the parent's automatic action.
class SubagentSettingsScreen extends StatefulWidget {
  const SubagentSettingsScreen({super.key, required this.agent});
  final AgentController agent;

  @override
  State<SubagentSettingsScreen> createState() => _SubagentSettingsScreenState();
}

class _SubagentSettingsScreenState extends State<SubagentSettingsScreen> {
  final _costCustom = TextEditingController();
  final _timeCustom = TextEditingController();
  bool _costCustomOpen = false;
  bool _timeCustomOpen = false;

  AgentController get agent => widget.agent;

  @override
  void dispose() {
    _costCustom.dispose();
    _timeCustom.dispose();
    super.dispose();
  }

  Future<void> _save(Map<String, dynamic> patch) async {
    try {
      await agent.integrations.updateSettings(patch);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString())));
    }
  }

  Future<void> _applyCustom({required bool cost}) async {
    final raw = (cost ? _costCustom : _timeCustom).text.trim();
    final value = int.tryParse(raw);
    if (value == null || value < 1) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(tr('Enter a number of 1 or more.'))));
      return;
    }
    if (cost) {
      await _save({'subagentCreditLimit': value});
      setState(() => _costCustomOpen = false);
    } else {
      await _save({'subagentMinutesLimit': value});
      setState(() => _timeCustomOpen = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return ListenableBuilder(
      listenable: agent.integrations,
      builder: (context, _) {
        final s = agent.integrations.settings;
        final cost = s?.subagentCreditLimit ?? 50;
        final time = s?.subagentMinutesLimit ?? 30;
        final approval = s?.subagentApprovalMode ?? agent.approvalMode;
        return Scaffold(
          appBar: AppBar(title: Text(tr('Subagent'))),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 40),
            children: [
              SurfaceCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(tr('Active limits'), style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 4),
                    Text(
                      cost == 0
                          ? tr('Cost: no limit • Time: {n} min').replaceAll('{n}', '${time.toInt()}')
                          : tr('Cost: {n} credits • Time: {m} min')
                                .replaceAll('{n}', '${cost.toInt()}')
                                .replaceAll('{m}', '${time.toInt()}'),
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: p.muted),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      tr('Limits apply to every subagent. Costs are estimates.'),
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(color: p.faint),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              SectionLabel(tr('Cost limit (global)')),
              _LimitPills(
                presets: const [10, 25, 50],
                unit: tr('credits'),
                noLimit: true,
                value: cost,
                customOpen: _costCustomOpen,
                customController: _costCustom,
                onPreset: (v) => _save({'subagentCreditLimit': v}),
                onCustomTap: () => setState(() => _costCustomOpen = !_costCustomOpen),
                onCustomApply: () => _applyCustom(cost: true),
              ),
              const SizedBox(height: 20),
              SectionLabel(tr('Time limit (global)')),
              _LimitPills(
                presets: const [15, 30, 60],
                unit: tr('min'),
                noLimit: false,
                value: time,
                customOpen: _timeCustomOpen,
                customController: _timeCustom,
                onPreset: (v) => _save({'subagentMinutesLimit': v}),
                onCustomTap: () => setState(() => _timeCustomOpen = !_timeCustomOpen),
                onCustomApply: () => _applyCustom(cost: false),
              ),
              const SizedBox(height: 20),
              SectionLabel(tr('Approvals')),
              PillSegments<String>(
                value: approval,
                options: {'ask_all': tr('Ask all'), 'ask_risky': tr('Risky only'), 'auto': tr('Bypass all')},
                expand: false,
                onChanged: (v) async {
                  if (v == 'auto' && !await confirmBypass(context)) return;
                  await _save({'subagentApprovalMode': v});
                },
              ),
              const SizedBox(height: 20),
              SectionLabel(tr('Notifications')),
              SwitchListTile(
                value: s?.subagentNotifyDone ?? true,
                title: Text(tr('Subagent finished')),
                onChanged: (v) => _save({'subagentNotifyDone': v}),
              ),
              SwitchListTile(
                value: s?.subagentNotifyFailed ?? true,
                title: Text(tr('Subagent failed')),
                onChanged: (v) => _save({'subagentNotifyFailed': v}),
              ),
              SwitchListTile(
                value: s?.subagentNotifyApproval ?? true,
                title: Text(tr('Approval requested')),
                onChanged: (v) => _save({'subagentNotifyApproval': v}),
              ),
              const SizedBox(height: 8),
              Text(
                tr('Notifications only say a subagent finished, failed, or needs approval. Tapping one opens the parent chat.'),
                style: Theme.of(context).textTheme.bodySmall?.copyWith(color: p.faint),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Preset pills plus a custom-value pill that reveals a number field.
/// The current value selects its preset, the no-limit pill, or "Custom: X".
class _LimitPills extends StatelessWidget {
  const _LimitPills({
    required this.presets,
    required this.unit,
    required this.noLimit,
    required this.value,
    required this.customOpen,
    required this.customController,
    required this.onPreset,
    required this.onCustomTap,
    required this.onCustomApply,
  });

  final List<int> presets;
  final String unit;
  final bool noLimit;
  final double value;
  final bool customOpen;
  final TextEditingController customController;
  final ValueChanged<int> onPreset;
  final VoidCallback onCustomTap;
  final VoidCallback onCustomApply;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final current = value.toInt();
    final isPreset = presets.contains(current);
    final isNoLimit = noLimit && current == 0;
    final isCustom = !isPreset && !isNoLimit;
    Widget pill(String label, bool selected, VoidCallback onTap) {
      return Material(
        color: selected ? p.text : p.surface,
        borderRadius: BorderRadius.circular(Radii.pill),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: Text(
              label,
              style: Theme.of(
                context,
              ).textTheme.labelLarge?.copyWith(color: selected ? p.inverse : p.muted, fontWeight: FontWeight.w600),
            ),
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final preset in presets) pill('$preset $unit', isPreset && current == preset, () => onPreset(preset)),
            if (noLimit) pill(tr('No limit'), isNoLimit, () => onPreset(0)),
            pill(isCustom ? '${tr('Custom')}: $current $unit' : tr('Custom'), isCustom || customOpen, onCustomTap),
          ],
        ),
        if (customOpen) ...[
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: customController,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                    hintText: unit,
                    border: const OutlineInputBorder(),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  ),
                  onSubmitted: (_) => onCustomApply(),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(onPressed: onCustomApply, child: Text(tr('Use'))),
            ],
          ),
        ],
      ],
    );
  }
}
