import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../agent/agent_controller.dart';
import '../agent/companion.dart';
import 'errors.dart';
import 'i18n.dart';
import 'kit.dart';
import 'read_only_chat.dart' show LiveDot;
import 'theme.dart';

/// A reply without the screen companion's pointer line (agent/src/companion.ts): the user reads the step, and the
/// highlight on screen does the pointing.
String hideCompanionPointer(String text) =>
    text.contains('SOROT') ? text.split('\n').where((l) => !RegExp(r'^\s*SOROT\s*:', caseSensitive: false).hasMatch(l)).join('\n').trimRight() : text;

Future<void> startCompanion(BuildContext context, AgentController agent, {bool openPanel = false}) async {
  try {
    // The panel shows plain chats: from Settings, with a coding chat open, the companion starts in a new plain chat
    // (the one the panel will show), not in the coding chat it would then leave.
    if (openPanel && !agent.isChat && !agent.busy) await agent.newSession(chat: true);
    final ok = await ScreenCompanion.instance.start(agent);
    if (!ok) return;
    if (openPanel) await agent.client.panelOpen();
  } catch (e) {
    if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(friendlyError(e))));
  }
}

/// In the panel while the companion is on: the one live signal, Done for the step just made, and Stop, always there.
class CompanionBar extends StatelessWidget {
  const CompanionBar({super.key, required this.agent});
  final AgentController agent;

  Future<void> _call(BuildContext context, Future<void> Function() op) async {
    try {
      await op();
    } catch (e) {
      if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(friendlyError(e))));
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = ScreenCompanion.instance;
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) {
        if (!c.active) return const SizedBox.shrink();
        final p = context.palette;
        final text = Theme.of(context).textTheme;
        return Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
          child: Container(
            padding: const EdgeInsets.fromLTRB(12, 6, 6, 6),
            decoration: BoxDecoration(color: p.raised, borderRadius: BorderRadius.circular(Radii.md)),
            child: Row(
              children: [
                const LiveDot(),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    c.looking ? tr('Looking at your screen…') : tr('Screen companion is on'),
                    style: text.labelLarge,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                TextButton(
                  onPressed: c.looking || agent.busy ? null : () => _call(context, () => c.step(agent, tr('Done. What next?'))),
                  child: Text(tr('I did it')),
                ),
                TextButton(
                  onPressed: () => _call(context, () => c.stop(agent)),
                  style: TextButton.styleFrom(foregroundColor: p.danger),
                  child: Text(tr('Stop')),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Settings → Screen companion: what it does and does not do, the optional accessibility reading explained before the
/// user is sent to Android's settings for it, and the button that starts it (in the panel, over the other app).
class CompanionScreen extends StatefulWidget {
  const CompanionScreen({super.key, required this.agent});
  final AgentController agent;

  @override
  State<CompanionScreen> createState() => _CompanionScreenState();
}

class _CompanionScreenState extends State<CompanionScreen> with WidgetsBindingObserver {
  static const _method = MethodChannel('griphub/agent');
  bool? _a11y;

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

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _check();
  }

  Future<void> _check() async {
    bool on;
    try {
      on = await _method.invokeMethod<bool>('a11yStatus') ?? false;
    } on MissingPluginException {
      on = false;
    }
    if (mounted) setState(() => _a11y = on);
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final text = Theme.of(context).textTheme;
    Widget point(IconData icon, String line) => Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(padding: const EdgeInsets.only(top: 2), child: Icon(icon, size: 18, color: p.accent)),
          const SizedBox(width: 12),
          Expanded(child: Text(line, style: text.bodyMedium)),
        ],
      ),
    );
    return Scaffold(
      appBar: AppBar(title: Text(tr('Screen companion'))),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 40),
        children: [
          Text(tr('Stuck in another app? GripHub looks and guides you'), style: text.headlineSmall),
          const SizedBox(height: 12),
          point(LucideIcons.scanEye, tr('It sees your screen only when a step needs it: one picture, not a recording. Pictures go to GripHub Router for that step and are not kept.')),
          point(LucideIcons.squareDashedMousePointer, tr('It explains one step and highlights where to tap. You do the tapping: it never taps, swipes or types for you.')),
          point(LucideIcons.shieldCheck, tr('Android asks you every time it starts and shows its own indicator while it runs. Stop ends it at once.')),
          point(LucideIcons.lock, tr('Banking apps and password fields cannot be seen; it will say so instead of guessing.')),
          const SizedBox(height: 8),
          PrimaryButton(
            label: tr('Start in the panel'),
            icon: LucideIcons.play,
            onPressed: () => startCompanion(context, widget.agent, openPanel: true),
          ),
          const SizedBox(height: 24),
          SectionLabel(tr('More precise pointing (optional)')),
          SurfaceCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  tr('With "GripHub Pendamping Layar" on in Android\'s accessibility settings, the companion can read the text and position of the elements on screen when you ask for a step, so the highlight lands exactly.'),
                  style: text.bodyMedium,
                ),
                const SizedBox(height: 8),
                Text(tr('It can read: text and buttons on screen, and where they are.'), style: text.bodySmall),
                Text(tr('It cannot: tap, swipe, type, or read password fields. It reads only when you ask for a step.'), style: text.bodySmall),
                Text(tr('To turn it off: Android settings → Accessibility → GripHub Pendamping Layar.'), style: text.bodySmall),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Icon(_a11y == true ? LucideIcons.circleCheck : LucideIcons.circleDashed, size: 16, color: _a11y == true ? p.success : p.muted),
                    const SizedBox(width: 8),
                    Expanded(child: Text(tr(_a11y == true ? 'On' : 'Off: it works from the picture alone'), style: text.bodySmall)),
                  ],
                ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(
                    onPressed: () => _method.invokeMethod('a11yOpenSettings'),
                    child: Text(tr('Open accessibility settings')),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
