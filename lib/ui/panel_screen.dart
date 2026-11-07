import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../agent/agent_controller.dart';
import '../agent/companion.dart';
import '../agent/models.dart';
import '../agent/panel.dart';
import 'chat_extras.dart' show Attachment;
import 'chat_screen.dart';
import 'companion_screen.dart';
import 'errors.dart';
import 'i18n.dart';
import 'kit.dart';
import 'theme.dart';

/// The floating panel (Fitur 4) in the app: the same engine and chat as the main window, drawn as a sheet over another
/// app (android PanelActivity sizes the window to it). Only plain chats: a coding chat, or anything waiting for
/// approval, is handed to the app with one tap.

/// Over the app's navigator: while the panel window shows the engine, the panel replaces what is on screen, and the
/// app's pages stay as they were underneath for when the main window comes back.
class PanelGate extends StatelessWidget {
  const PanelGate({super.key, required this.agent, required this.child});
  final AgentController agent;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: PanelState.instance,
      builder: (context, _) {
        final panel = PanelState.instance.isPanel && agent.status == BootStatus.ready;
        return Stack(
          children: [
            Offstage(offstage: panel, child: TickerMode(enabled: !panel, child: child)),
            if (panel)
              // Its own navigator, for the dialogs and sheets the chat opens.
              Navigator(onGenerateRoute: (_) => MaterialPageRoute<void>(builder: (_) => PanelScreen(agent: agent))),
          ],
        );
      },
    );
  }
}

/// What one tap on a selection asks for. Translate and Reply answer with the text alone, so it can replace the
/// selection in the other app.
enum PanelAction { explain, summarize, translate, reply }

String panelActionLabel(PanelAction a) => switch (a) {
  PanelAction.explain => tr('Explain'),
  PanelAction.summarize => tr('Summarize'),
  PanelAction.translate => tr('Translate'),
  PanelAction.reply => tr('Reply'),
};

/// The prompt for an action on [text], in the app's language.
String panelActionPrompt(PanelAction a, String text) {
  final quoted = text.trim().split('\n').map((l) => '> $l').join('\n');
  final ask = switch (a) {
    PanelAction.explain => tr('Explain this simply:'),
    PanelAction.summarize => tr('Summarize this briefly:'),
    PanelAction.translate => tr(
      'Translate this (into English if it is in Indonesian, otherwise into Indonesian). Answer with the translation only:',
    ),
    PanelAction.reply => tr('Write a short, polite reply to this message. Answer with the reply only:'),
  };
  return '$ask\n\n$quoted';
}

class PanelScreen extends StatefulWidget {
  const PanelScreen({super.key, required this.agent});
  final AgentController agent;

  @override
  State<PanelScreen> createState() => _PanelScreenState();
}

class _PanelScreenState extends State<PanelScreen> {
  AgentController get agent => widget.agent;
  StreamSubscription<Map<String, dynamic>>? _records;

  /// The chat screen is built again for a new share (its composer starts from the shared text and files).
  Key _chatKey = UniqueKey();
  String? _prompt;
  List<Attachment> _files = const [];

  @override
  void initState() {
    super.initState();
    _records = agent.client.records.listen((r) {
      if (r['type'] == 'launch') unawaited(_takeLaunch());
    });
    // Opened cold: the launch was waiting before this screen existed.
    WidgetsBinding.instance.addPostFrameCallback((_) => _takeLaunch());
  }

  @override
  void dispose() {
    _records?.cancel();
    super.dispose();
  }

  /// What the panel was opened for: a selection, a share, or just the panel (the bubble).
  Future<void> _takeLaunch() async {
    final launch = await agent.client.takeLaunch();
    if (launch == null || !mounted) return;
    switch (launch['action']) {
      case 'panel_selection':
        await agent.newSession(chat: true);
        _restart();
      // The widget's microphone: the panel, listening.
      case 'panel_voice':
        if (!agent.isChat) await agent.newSession(chat: true);
        _restart(listen: true);
      case 'share':
        await agent.newSession(chat: true);
        _restart(
          prompt: launch['text'] as String?,
          files: [
            for (final f in (launch['files'] as List? ?? const []).cast<Map>())
              Attachment(f['path'] as String, f['name'] as String, mime: f['mime'] as String?),
          ],
        );
      default:
        // The bubble: the chat the panel had, if it is a plain chat; else a new one.
        if (!agent.isChat) {
          await agent.newSession(chat: true);
          _restart();
        }
    }
  }

  void _restart({String? prompt, List<Attachment> files = const [], bool listen = false}) {
    if (!mounted) return;
    setState(() {
      _chatKey = UniqueKey();
      _prompt = prompt;
      _files = files;
      _listen = listen;
    });
  }

  bool _listen = false;

  Future<void> _act(PanelAction a) async {
    final text = PanelState.instance.selection;
    if (text == null || text.trim().isEmpty) return;
    await agent.sendWith(panelActionPrompt(a, text));
  }

  /// The last answer, for "Replace the original text".
  String? get _lastAnswer {
    for (final e in agent.entries.reversed) {
      if (e is UserEntry) return null;
      if (e is AssistantEntry && !e.streaming) {
        final text = [
          for (final b in e.orderedBlocks)
            if (b.kind == BlockKind.text && b.text.trim().isNotEmpty) b.text.trim(),
        ].join('\n\n');
        if (text.isNotEmpty) return text;
      }
    }
    return null;
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
    return Material(
      color: p.bg,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(Radii.xl))),
      clipBehavior: Clip.antiAlias,
      child: ListenableBuilder(
        listenable: Listenable.merge([agent, PanelState.instance]),
        builder: (context, _) {
          final selection = PanelState.instance.selection;
          final answer = PanelState.instance.writable && !agent.busy ? _lastAnswer : null;
          return Column(
            children: [
              // The header: what this is, and the panel's own controls. Close is always there.
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 6, 4, 0),
                child: Row(
                  children: [
                    const LogoMark(size: 22, glow: false),
                    const SizedBox(width: 8),
                    Expanded(child: Text('GripHub', style: text.titleMedium)),
                    ListenableBuilder(
                      listenable: ScreenCompanion.instance,
                      builder: (context, _) => ScreenCompanion.instance.active
                          ? const SizedBox.shrink()
                          : IconButton(
                              tooltip: tr('Screen companion'),
                              onPressed: () => startCompanion(context, agent),
                              icon: const Icon(LucideIcons.scanEye, size: 18),
                            ),
                    ),
                    IconButton(
                      tooltip: tr('Open in the app'),
                      onPressed: () => _call(agent.client.panelOpenFull),
                      icon: const Icon(LucideIcons.maximize2, size: 18),
                    ),
                    IconButton(
                      tooltip: tr('Fold into the bubble'),
                      onPressed: () => _call(agent.client.panelMinimize),
                      icon: const Icon(LucideIcons.chevronDown, size: 20),
                    ),
                    IconButton(
                      tooltip: tr('Close the panel'),
                      onPressed: () => _call(agent.client.panelClose),
                      icon: const Icon(LucideIcons.x, size: 20),
                    ),
                  ],
                ),
              ),
              CompanionBar(agent: agent),
              if (selection != null && selection.trim().isNotEmpty)
                _SelectionBar(
                  text: selection,
                  busy: agent.busy || agent.sendLocked,
                  onAction: _act,
                ),
              if (answer != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
                  child: SizedBox(
                    width: double.infinity,
                    child: FilledButton.tonalIcon(
                      onPressed: () => _call(() => agent.client.panelReplaceText(answer)),
                      icon: const Icon(LucideIcons.replace, size: 16),
                      label: Text(tr('Replace the original text')),
                    ),
                  ),
                ),
              Expanded(
                child: ChatScreen(
                  key: _chatKey,
                  agent: agent,
                  panel: true,
                  initialPrompt: _prompt,
                  initialAttachments: _files,
                  listenOnOpen: _listen,
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// The selection the panel was opened with, quoted, and the one-tap actions on it. The quote stays quiet; the actions
/// are the things to tap.
class _SelectionBar extends StatelessWidget {
  const _SelectionBar({required this.text, required this.busy, required this.onAction});
  final String text;
  final bool busy;
  final void Function(PanelAction) onAction;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final style = Theme.of(context).textTheme.bodySmall?.copyWith(color: p.muted);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
            decoration: BoxDecoration(
              border: Border(left: BorderSide(color: p.border, width: 3)),
            ),
            child: Text(text.trim(), maxLines: 3, overflow: TextOverflow.ellipsis, style: style),
          ),
          const SizedBox(height: 4),
          // All four within reach on any width: they wrap rather than scroll out of view.
          Wrap(
            spacing: 6,
            runSpacing: 0,
            children: [
              for (final a in PanelAction.values)
                ActionChip(label: Text(panelActionLabel(a)), onPressed: busy ? null : () => onAction(a)),
            ],
          ),
        ],
      ),
    );
  }
}

/// In the panel, instead of approval cards: one line that the rest happens in the app, and the tap that goes there.
/// Shown when something waits for approval, or the chat is a coding chat (tools are not run from the panel).
class PanelHandoff extends StatelessWidget {
  const PanelHandoff({super.key, required this.agent});
  final AgentController agent;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    // Approvals arrive on the features' records, not the chat's.
    listenable: Listenable.merge([agent, agent.features]),
    builder: (context, _) => _build(context),
  );

  Widget _build(BuildContext context) {
    final waiting = agent.features.approvals.length;
    if (waiting == 0 && agent.isChat) return const SizedBox.shrink();
    final p = context.palette;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
      child: Material(
        color: p.raised,
        borderRadius: BorderRadius.circular(Radii.md),
        child: InkWell(
          borderRadius: BorderRadius.circular(Radii.md),
          onTap: () => agent.client.panelOpenFull(),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(padding: const EdgeInsets.only(top: 1), child: Icon(LucideIcons.externalLink, size: 16, color: p.text)),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    waiting > 0
                        ? tr('{n} waiting for your approval. Continue in the app').replaceAll('{n}', '$waiting')
                        : tr('This chat uses project tools. Continue in the app'),
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
