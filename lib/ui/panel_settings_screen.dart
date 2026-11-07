import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../agent/agent_controller.dart';
import 'errors.dart';
import 'i18n.dart';
import 'kit.dart';
import 'theme.dart';

/// The floating panel's own screen (Fitur 4): one page on why it needs to show above other apps, the way to the
/// system setting, and the state, read again when the user comes back from it. Opened only when the user goes for the
/// panel, never at the app's start.
class PanelSettingsScreen extends StatefulWidget {
  const PanelSettingsScreen({super.key, required this.agent});
  final AgentController agent;

  @override
  State<PanelSettingsScreen> createState() => _PanelSettingsScreenState();
}

class _PanelSettingsScreenState extends State<PanelSettingsScreen> with WidgetsBindingObserver {
  bool? _allowed;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _check();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// Back from the system setting: what the user chose there.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _check();
  }

  Future<void> _check() async {
    final allowed = await widget.agent.client.overlayPermission();
    if (mounted) setState(() => _allowed = allowed);
  }

  Future<void> _call(Future<void> Function() op) async {
    try {
      await op();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(friendlyError(e))));
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final text = Theme.of(context).textTheme;
    final allowed = _allowed;
    return Scaffold(
      appBar: AppBar(title: Text(tr('Floating panel'))),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 40),
        children: [
          Text(tr('Ask GripHub from any app'), style: text.headlineSmall),
          const SizedBox(height: 12),
          for (final (icon, line) in [
            (LucideIcons.textSelect, tr('Select text in any app, then "Tanya GripHub": explain, summarize, translate or reply, without leaving it.')),
            (LucideIcons.share2, tr('Share a link, text or a picture to GripHub: it opens in a small panel over the app you are in.')),
            (LucideIcons.circleDot, tr('Fold the panel into a small bubble at the edge of the screen; drag it to the bottom to put it away.')),
          ])
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(padding: const EdgeInsets.only(top: 2), child: Icon(icon, size: 18, color: p.accent)),
                  const SizedBox(width: 12),
                  Expanded(child: Text(line, style: text.bodyMedium)),
                ],
              ),
            ),
          const SizedBox(height: 8),
          SurfaceCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(tr('Why Android asks'), style: text.titleSmall),
                const SizedBox(height: 6),
                Text(
                  tr(
                    'To stay above other apps, the panel needs "Display over other apps". It is used only for the panel and its bubble, only while you keep them on screen. Android hides them on secure screens (banking, passwords, system permission dialogs); they come back afterwards. You can turn it off any time in the same system setting.',
                  ),
                  style: text.bodySmall,
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          if (allowed == null)
            const Center(child: BusySpinner())
          else if (allowed) ...[
            Row(
              children: [
                Icon(LucideIcons.circleCheck, size: 18, color: p.success),
                const SizedBox(width: 8),
                Expanded(child: Text(tr('Allowed: the panel can open over other apps.'), style: text.bodyMedium)),
              ],
            ),
            const SizedBox(height: 12),
            PrimaryButton(label: tr('Try the panel now'), icon: LucideIcons.panelBottom, onPressed: () => _call(() async {
              await widget.agent.client.panelOpen();
            })),
            TextButton(onPressed: () => _call(widget.agent.client.requestOverlayPermission), child: Text(tr('Change it in system settings'))),
          ] else ...[
            Text(tr('Not allowed yet: without it, these ways in open the app instead.'), style: text.bodyMedium?.copyWith(color: p.muted)),
            const SizedBox(height: 12),
            PrimaryButton(label: tr('Open system settings'), icon: LucideIcons.settings, onPressed: () => _call(widget.agent.client.requestOverlayPermission)),
          ],
        ],
      ),
    );
  }
}
