import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../agent/agent_controller.dart';
import '../agent/integrations.dart';
import 'errors.dart';
import 'i18n.dart';
import 'kit.dart';
import 'theme.dart';

/// One line for Settings.
String verifySummary(AppSettings? s) => s?.verify == false
    ? tr('Off')
    : tr('Tests run before the agent may say it is done · up to {n} fixes').replaceAll('{n}', '${s?.verifyRounds ?? 3}');

/// Settings → Self-verification (agent/src/verify.ts): the switch, how many fix rounds, and whether tasks that changed
/// nothing are checked too.
class VerifySettingsScreen extends StatefulWidget {
  const VerifySettingsScreen({super.key, required this.agent});
  final AgentController agent;

  @override
  State<VerifySettingsScreen> createState() => _VerifySettingsScreenState();
}

class _VerifySettingsScreenState extends State<VerifySettingsScreen> {
  Integrations get it => widget.agent.integrations;
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
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(friendlyError(e))));
    } finally {
      if (mounted) setState(() => _saving = false);
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
        final on = s?.verify ?? true;
        final rounds = s?.verifyRounds ?? 3;
        return Scaffold(
          appBar: AppBar(title: Text(tr('Self-verification'))),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 40),
            children: [
              SettingsGroup(
                children: [
                  SettingsRow(
                    icon: LucideIcons.listChecks,
                    color: const Color(0xFF22C55E),
                    title: tr('Self-verification'),
                    subtitle: tr('Run the project\'s tests before the agent may say a coding task is done'),
                    trailing: LabeledSwitch(label: tr('Self-verification'), value: on, onChanged: _saving ? null : (v) => _save({'verify': v})),
                  ),
                ],
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 10, 4, 0),
                child: Text(
                  tr(
                    'After the agent changes files, the app runs the project\'s check itself (its tests, or the command set in the project\'s tools) and shows the result in the chat. A failure goes back to the agent to fix; the agent may not change or skip tests to pass. The check asks for approval like any command. Fixing costs model requests like any other turn.',
                  ),
                  style: text.bodySmall,
                ),
              ),
              SectionLabel(tr('Fix rounds')),
              SettingsGroup(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(14, 8, 8, 8),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            tr('Up to {n} rounds of fixing after a failure').replaceAll('{n}', '$rounds'),
                            style: text.titleSmall?.copyWith(color: on ? null : p.muted),
                          ),
                        ),
                        IconButton(
                          tooltip: tr('Fewer'),
                          onPressed: !on || _saving || rounds <= 0 ? null : () => _save({'verifyRounds': rounds - 1}),
                          icon: const Icon(LucideIcons.minus, size: 18),
                        ),
                        Text('$rounds', style: text.titleMedium),
                        IconButton(
                          tooltip: tr('More'),
                          onPressed: !on || _saving || rounds >= 20 ? null : () => _save({'verifyRounds': rounds + 1}),
                          icon: const Icon(LucideIcons.plus, size: 18),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              SettingsGroup(
                children: [
                  SettingsRow(
                    icon: LucideIcons.fileQuestion,
                    color: p.accentAlt,
                    title: tr('Also tasks that change no file'),
                    subtitle: tr('Run the check after every coding task'),
                    trailing: LabeledSwitch(
                      label: tr('Also tasks that change no file'),
                      value: s?.verifyAlways ?? false,
                      onChanged: !on || _saving ? null : (v) => _save({'verifyAlways': v}),
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
