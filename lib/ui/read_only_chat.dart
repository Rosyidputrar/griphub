import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../agent/agent_controller.dart';
import '../agent/models.dart';
import 'i18n.dart';
import 'kit.dart';
import 'message_views.dart';
import 'theme.dart';
import 'verify_view.dart';

/// Browsing while the agent works (Fitur 8): another chat on screen, read-only, while the open chat works. Looking is
/// never locked; only sending is. The pill above is the one thing that moves; the chat itself stays still.

/// "The agent is working in `chat`", with the one live dot, and the number of approvals waiting there. Tapping it goes
/// back to that chat.
class WorkingPill extends StatelessWidget {
  const WorkingPill({super.key, required this.agent});
  final AgentController agent;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final text = Theme.of(context).textTheme;
    final waiting = agent.features.approvals.length;
    final label = tr('The agent is working in {chat}').replaceAll('{chat}', agent.chatTitle);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: Semantics(
        button: true,
        label: waiting > 0 ? '$label, ${tr('{n} waiting for your approval').replaceAll('{n}', '$waiting')}' : label,
        excludeSemantics: true,
        child: Material(
          color: p.raised,
          // Rounded rather than a stadium: on a narrow screen the chat's name wraps instead of being cut.
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.xl), side: BorderSide(color: p.border)),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: agent.leaveView,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 9, 10, 9),
              child: Row(
                children: [
                  const LiveDot(),
                  const SizedBox(width: 8),
                  // The chat's name is the title, so it is what stays when the line is short; what it is doing is said
                  // above it, quietly.
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(tr('The agent is working in'), maxLines: 1, overflow: TextOverflow.ellipsis, style: text.bodySmall?.copyWith(color: p.muted)),
                        Text(agent.chatTitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: text.labelLarge),
                      ],
                    ),
                  ),
                  if (waiting > 0) ...[
                    const SizedBox(width: 8),
                    _Badge(count: waiting),
                  ],
                  const SizedBox(width: 4),
                  Icon(LucideIcons.chevronRight, size: 18, color: p.faint),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Approvals waiting in the chat at work: the one signal allowed to stand out.
class _Badge extends StatelessWidget {
  const _Badge({required this.count});
  final int count;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Container(
      constraints: const BoxConstraints(minWidth: 22),
      height: 22,
      padding: const EdgeInsets.symmetric(horizontal: 6),
      alignment: Alignment.center,
      decoration: BoxDecoration(color: p.warning, borderRadius: BorderRadius.circular(11)),
      child: Text(
        '$count',
        style: TextStyle(color: p.onAccent, fontSize: 12, fontWeight: FontWeight.w700, height: 1),
      ),
    );
  }
}

/// The single live indicator: a dot that breathes while work goes on (still when the system asks for less motion).
class LiveDot extends StatefulWidget {
  const LiveDot({super.key, this.size = 8});
  final double size;

  @override
  State<LiveDot> createState() => _LiveDotState();
}

class _LiveDotState extends State<LiveDot> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1400));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (Motion.reduced(context)) {
      _c
        ..stop()
        ..value = 1;
    } else if (!_c.isAnimating) {
      _c.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return SizedBox.square(
      dimension: widget.size * 2.2,
      child: AnimatedBuilder(
        animation: _c,
        builder: (context, _) {
          final t = Curves.easeInOut.transform(_c.value);
          return Stack(
            alignment: Alignment.center,
            children: [
              // The halo grows and fades: the movement, not the brightness, says it is alive.
              Container(
                width: widget.size * (1 + 1.2 * t),
                height: widget.size * (1 + 1.2 * t),
                decoration: BoxDecoration(shape: BoxShape.circle, color: p.accent.withValues(alpha: 0.28 * (1 - t))),
              ),
              Container(
                width: widget.size,
                height: widget.size,
                decoration: BoxDecoration(shape: BoxShape.circle, color: p.accent),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// The composer of a chat on screen while another works: the draft stays as typed, and one line says why it waits.
/// There is no Send, and nothing else here sends.
class LockedComposer extends StatelessWidget {
  const LockedComposer({super.key, required this.agent, required this.draft});
  final AgentController agent;
  final String draft;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final text = Theme.of(context).textTheme;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 6, 12, 12),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(18, 14, 18, 14),
          decoration: BoxDecoration(
            color: p.surface,
            borderRadius: BorderRadius.circular(Radii.xl),
            border: Border.all(color: p.border),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (draft.trim().isNotEmpty) ...[
                Text(draft, maxLines: 3, overflow: TextOverflow.ellipsis, style: text.bodyLarge?.copyWith(color: p.muted)),
                const SizedBox(height: 8),
              ],
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // On the first line of the explanation, however many lines it takes.
                  Padding(padding: const EdgeInsets.only(top: 2), child: Icon(LucideIcons.lock, size: 14, color: p.muted)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      tr('Read-only — the agent is working in {chat}.').replaceAll('{chat}', agent.chatTitle),
                      style: text.bodySmall?.copyWith(color: p.muted),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The transcript of a chat on screen read-only: the same message views as the open chat, still (nothing streams here).
class ReadOnlyTranscript extends StatelessWidget {
  const ReadOnlyTranscript({super.key, required this.agent, required this.view, this.controller});
  final AgentController agent;
  final ChatView view;
  final ScrollController? controller;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final p = context.palette;
    if (!view.loaded) return const Center(child: BusySpinner.page());
    if (view.error != null) {
      return Center(child: Padding(padding: const EdgeInsets.all(24), child: ErrorNotice(error: view.error)));
    }
    final entries = view.entries;
    if (entries.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(
            tr(view.isNew ? 'This chat starts once the agent is free.' : 'No messages yet.'),
            style: text.bodyMedium?.copyWith(color: p.muted),
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    final footers = turnFooters(entries, busy: false);
    return ListView.builder(
      controller: controller,
      reverse: false,
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
      itemCount: entries.length,
      itemBuilder: (context, i) {
        final e = entries[i];
        final child = switch (e) {
          UserEntry() => UserMessageView(e, fs: agent.fs),
          AssistantEntry() => AssistantMessageView(
            e,
            tools: view.tools,
            agent: agent,
            modelLabel: agent.modelLabel,
            footer: footers[i],
            visionReads: footers[i] == null ? const [] : _turnUser(entries, i)?.visionReads ?? const [],
            verified: footers[i] == null ? null : lastVerifyOfTurn(entries, i),
          ),
          NoticeEntry() => NoticeView(e),
          JobEntry() => JobNoticeView(e),
          VerifyEntry() => VerifyEvidenceView(e, agent: agent),
          CompactionEntry() => CompactionView(e),
        };
        return Padding(padding: EdgeInsets.only(top: i == 0 ? 0 : (e is UserEntry ? 28 : 14)), child: child);
      },
    );
  }

  static UserEntry? _turnUser(List<ChatEntry> entries, int i) {
    for (var k = i; k >= 0; k--) {
      if (entries[k] is UserEntry) return entries[k] as UserEntry;
    }
    return null;
  }
}
