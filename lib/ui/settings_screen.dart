import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../agent/agent_controller.dart';
import 'griphub_screen.dart';
import 'kit.dart';
import 'i18n.dart';
import 'theme.dart';

/// Models & providers for this build: GripHub Router is the only provider,
/// so this screen is a status card plus the environment details.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, required this.agent});
  final AgentController agent;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  @override
  void initState() {
    super.initState();
    widget.agent.refreshProviders();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final text = Theme.of(context).textTheme;
    return ListenableBuilder(
      listenable: widget.agent,
      builder: (context, _) {
        final agent = widget.agent;
        final grip = agent.providers.where((x) => x.id == 'griphub').firstOrNull;
        final connected = grip?.configured == true;
        return Scaffold(
          appBar: AppBar(
            title: Text(tr('Models & providers')),
          ),
          body: ListView(
            padding: const EdgeInsets.only(bottom: 32),
            children: [
              _Header(tr('Provider')),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: SurfaceCard(
                  onTap: () => Navigator.of(context)
                      .push(MaterialPageRoute<bool>(builder: (_) => GripHubScreen(agent: agent))),
                  child: Row(
                    children: [
                      const LogoMark(size: 44),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('GripHub Router', style: text.titleSmall),
                            const SizedBox(height: 2),
                            Text(
                              connected ? '${grip!.modelCount} ${tr('models available')}' : tr('Not connected'),
                              style: text.bodySmall?.copyWith(color: p.muted),
                            ),
                          ],
                        ),
                      ),
                      if (connected)
                        Pill(tr('Connected'), color: p.success, dot: true)
                      else
                        Icon(LucideIcons.chevronRight, size: 18, color: p.faint),
                    ],
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
                child: Text(
                  tr(
                    'This build only connects to GripHub Router. One API key unlocks every model it serves.',
                  ),
                  style: text.bodySmall?.copyWith(color: p.muted),
                ),
              ),
              _Header(tr('Environment')),
              _InfoRow(tr('Agent engine (pi)'), agent.info['version']?.toString() ?? '—'),
              _InfoRow('Node.js', agent.info['node']?.toString() ?? '—'),
              _InfoRow('Workspace', agent.info['workspace']?.toString() ?? '—', monospace: true),
              _InfoRow('Agent directory', agent.info['agentDir']?.toString() ?? '—', monospace: true),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
                child: OutlinedButton(onPressed: agent.busy ? null : agent.restart, child: Text(tr('Restart agent'))),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _Header extends StatelessWidget {
  const _Header(this.label);
  final String label;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 24, 20, 8),
    child: Text(label.toUpperCase(), style: Theme.of(context).textTheme.labelSmall),
  );
}

class _InfoRow extends StatelessWidget {
  const _InfoRow(this.label, this.value, {this.monospace = false});
  final String label;
  final String value;
  final bool monospace;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(tr(label), style: text.labelMedium),
          const SizedBox(height: 2),
          SelectableText(
            value,
            style: monospace
                ? TextStyle(fontFamily: mono, fontSize: 12.5, color: p.text, height: 1.5)
                : text.bodyMedium,
          ),
        ],
      ),
    );
  }
}
