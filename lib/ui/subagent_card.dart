import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../agent/agent_controller.dart';
import '../agent/subagents.dart';
import 'i18n.dart';
import 'theme.dart';

/// The inline progress element for a subagent inside its parent chat.
///
/// Deliberately NOT a tool card: a filled surface with an accent border and
/// an agent avatar, so it reads as "an agent working" rather than "a tool
/// call". Tapping it opens the detail modal ([SubagentSheet]).
class SubagentCard extends StatelessWidget {
  const SubagentCard({super.key, required this.state, required this.agent});
  final SubagentState state;
  final AgentController agent;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final s = state;
    final color = switch (s.status) {
      SubagentStatus.failed => p.danger,
      SubagentStatus.done => p.success,
      SubagentStatus.stopped => p.muted,
      _ => p.accent,
    };
    final activity = s.currentActivity ?? (s.isActive ? tr('Working') : null);
    return Material(
      color: p.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: color.withValues(alpha: 0.45), width: 1.2),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => showSubagentSheet(context, s, agent),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(color: color.withValues(alpha: 0.14), shape: BoxShape.circle),
                child: Icon(LucideIcons.bot, size: 22, color: color),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          tr('Subagent').toUpperCase(),
                          style: Theme.of(
                            context,
                          ).textTheme.labelSmall?.copyWith(color: color, fontWeight: FontWeight.w700, letterSpacing: 0.8),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          tr(s.profileKey),
                          style: Theme.of(context).textTheme.labelSmall?.copyWith(color: p.faint),
                        ),
                        const Spacer(),
                        Text(
                          tr(s.statusKey),
                          style: Theme.of(context).textTheme.labelSmall?.copyWith(color: color, fontWeight: FontWeight.w600),
                        ),
                      ],
                    ),
                    if (activity != null) ...[
                      const SizedBox(height: 4),
                      Text(activity, style: Theme.of(context).textTheme.bodyMedium, maxLines: 2, overflow: TextOverflow.ellipsis),
                    ],
                    const SizedBox(height: 6),
                    Text(
                      _meta(s),
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(color: p.faint),
                    ),
                    if (s.isActive) ...[
                      const SizedBox(height: 8),
                      LinearProgressIndicator(color: color, backgroundColor: p.raised, minHeight: 3),
                    ],
                    if (s.queue.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        tr('Queue: {n}').replaceAll('{n}', '${s.queue.length}'),
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(color: p.muted),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 4),
              Icon(LucideIcons.chevronRight, size: 20, color: p.faint),
            ],
          ),
        ),
      ),
    );
  }

  String _meta(SubagentState s) {
    final parts = <String>['${s.tools.length} tools'];
    final e = s.elapsed;
    if (e != null) parts.add(_fmtDuration(e));
    if (s.credits != null) parts.add('~${s.credits!.toStringAsFixed(2)} credit');
    return parts.join(' • ');
  }
}

String _fmtDuration(Duration d) {
  if (d.inSeconds < 60) return '${d.inSeconds} dtk';
  return '${d.inMinutes} mnt ${d.inSeconds % 60} dtk';
}

Future<void> showSubagentSheet(BuildContext context, SubagentState state, AgentController agent) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (context) => FractionallySizedBox(
      heightFactor: 0.88,
      child: SubagentSheet(state: state, agent: agent),
    ),
  );
}

/// Banner shown in a chat while subagents run in OTHER chats. Tapping it
/// jumps to the parent chat (never a new chat); inside the app the parent's
/// title is fine to show — notifications, which reach the lock screen, never
/// carry titles or content.
class CrossChatBanner extends StatelessWidget {
  const CrossChatBanner({super.key, required this.agent});
  final AgentController agent;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final elsewhere = agent.subagentsElsewhere;
    if (elsewhere.isEmpty) return const SizedBox.shrink();
    final text = elsewhere.length == 1
        ? tr("Subagent running in chat '{name}'").replaceAll(
            '{name}',
            elsewhere.first.parentTitle.isEmpty ? tr('another chat') : elsewhere.first.parentTitle,
          )
        : tr('{n} subagents running in other chats').replaceAll('{n}', '${elsewhere.length}');
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
      child: Material(
        color: p.accent.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => _jump(context, elsewhere.first),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              children: [
                Icon(LucideIcons.bot, size: 20, color: p.accent),
                const SizedBox(width: 10),
                Expanded(child: Text(text, style: Theme.of(context).textTheme.bodyMedium)),
                TextButton(onPressed: () => _jump(context, elsewhere.first), child: Text(tr('View'))),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _jump(BuildContext context, SubagentState target) async {
    try {
      final known = (await agent.listSessions()).any((s) => s.path == target.parentSessionFile);
      if (!known) throw Exception(tr('Parent chat not found'));
      await agent.openSession(target.parentSessionFile);
    } catch (e) {
      if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString())));
    }
  }
}

/// Detail modal: what the agent is doing and how far, tools with results,
/// the parent's prompt, the queue, approval, and stop controls.
class SubagentSheet extends StatefulWidget {
  const SubagentSheet({super.key, required this.state, required this.agent});
  final SubagentState state;
  final AgentController agent;

  @override
  State<SubagentSheet> createState() => _SubagentSheetState();
}

class _SubagentSheetState extends State<SubagentSheet> {
  final _queueController = TextEditingController();
  Timer? _ticker;

  SubagentState get s => widget.state;
  AgentController get agent => widget.agent;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && s.isActive) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _queueController.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() f) async {
    try {
      await f();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString())));
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return AnimatedBuilder(
      animation: agent,
      builder: (context, _) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '${tr('Subagent')} • ${tr(s.statusKey)}',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
                    ),
                  ),
                  IconButton(icon: const Icon(LucideIcons.x), onPressed: () => Navigator.of(context).pop()),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                children: [
                  if (s.currentActivity != null || s.isActive) ...[
                    Text(s.currentActivity ?? tr('Working'), style: Theme.of(context).textTheme.bodyLarge),
                    const SizedBox(height: 4),
                    Text(
                      '${s.tools.length} tools'
                      '${s.elapsed == null ? '' : ' • ${_fmtDuration(s.elapsed!)}'}'
                      '${s.credits == null ? '' : ' • ~${s.credits!.toStringAsFixed(2)} credit (perkiraan)'}',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(color: p.faint),
                    ),
                    if (s.isActive) ...[
                      const SizedBox(height: 8),
                      LinearProgressIndicator(color: p.accent, backgroundColor: p.raised, minHeight: 3),
                    ],
                    const SizedBox(height: 16),
                  ],
                  if (s.approval case final ap?) ...[
                    _SectionTitle(tr('Needs approval')),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: p.warning.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: p.warning.withValues(alpha: 0.5)),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(tr('This subagent needs approval before it continues.'), style: Theme.of(context).textTheme.bodyMedium),
                          const SizedBox(height: 6),
                          SelectableText(
                            '${ap.toolName}: ${ap.summary}\n${ap.reason}',
                            style: Theme.of(context).textTheme.bodySmall?.copyWith(color: p.muted),
                          ),
                          const SizedBox(height: 10),
                          Row(
                            children: [
                              Expanded(
                                child: OutlinedButton(
                                  onPressed: () => _run(() => agent.replySubagentApproval(s.id, ap.approvalId, false)),
                                  child: Text(tr('Decline')),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: FilledButton(
                                  onPressed: () => _run(() => agent.replySubagentApproval(s.id, ap.approvalId, true)),
                                  child: Text(tr('Approve')),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                  ],
                  _SectionTitle(tr('Parent prompt')),
                  SelectableText(s.brief, style: Theme.of(context).textTheme.bodyMedium),
                  const SizedBox(height: 16),
                  _SectionTitle('${tr('Tools used')} (${s.tools.length})'),
                  if (s.tools.isEmpty)
                    Text('-', style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: p.faint))
                  else
                    for (final t in s.tools) _ToolRow(tool: t),
                  const SizedBox(height: 16),
                  if (s.isTerminal) ...[
                    _SectionTitle(s.status == SubagentStatus.done ? tr('Report') : tr('Partial report')),
                    if (s.error != null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: Text(s.error!, style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: p.danger)),
                      ),
                    if (s.stopReason != null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: Text(s.stopReason!, style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: p.muted)),
                      ),
                    SelectableText(
                      (s.report == null || s.report!.isEmpty) ? '-' : s.report!,
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                    const SizedBox(height: 16),
                  ],
                  if (s.isActive) ...[
                    _SectionTitle('${tr('Queue')} (${s.queue.length})'),
                    Text(
                      tr('Queued messages are sent in order once the current step finishes.'),
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(color: p.faint),
                    ),
                    const SizedBox(height: 8),
                    for (var i = 0; i < s.queue.length; i++) _queueRow(index: i, count: s.queue.length),
                    const SizedBox(height: 8),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _queueController,
                            minLines: 1,
                            maxLines: 4,
                            decoration: InputDecoration(
                              hintText: tr('Message for the subagent'),
                              border: const OutlineInputBorder(),
                              contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                            ),
                            onSubmitted: (_) => _sendQueued(),
                          ),
                        ),
                        const SizedBox(width: 8),
                        IconButton.filled(
                          icon: const Icon(LucideIcons.sendHorizontal, size: 20),
                          onPressed: _sendQueued,
                          tooltip: tr('Queue'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 20),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton(
                            onPressed: () => _run(() => agent.stopSubagent(s.id)),
                            child: Text(tr('Stop gracefully')),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: OutlinedButton(
                            style: OutlinedButton.styleFrom(foregroundColor: p.danger, side: BorderSide(color: p.danger)),
                            onPressed: _confirmForceStop,
                            child: Text(tr('Force stop')),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      tr('Stop gracefully waits for the current tool, then stops with a partial report.'),
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(color: p.faint),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      tr('Force stop kills the running tool at once; results may be incomplete.'),
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(color: p.faint),
                    ),
                  ],
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _queueRow({required int index, required int count}) {
    final p = context.palette;
    final q = s.queue[index];
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: [
          Expanded(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(color: p.surface, borderRadius: BorderRadius.circular(10)),
              child: Text(q.text, maxLines: 3, overflow: TextOverflow.ellipsis),
            ),
          ),
          IconButton(
            icon: const Icon(LucideIcons.chevronUp, size: 20),
            onPressed: index == 0 ? null : () => _run(() => agent.moveQueuedSubagentMessage(s.id, q.id, 'up')),
            tooltip: tr('Move up'),
          ),
          IconButton(
            icon: const Icon(LucideIcons.chevronDown, size: 20),
            onPressed: index == count - 1 ? null : () => _run(() => agent.moveQueuedSubagentMessage(s.id, q.id, 'down')),
            tooltip: tr('Move down'),
          ),
          IconButton(
            icon: const Icon(LucideIcons.trash2, size: 20),
            onPressed: () => _run(() => agent.removeQueuedSubagentMessage(s.id, q.id)),
            tooltip: tr('Delete'),
          ),
        ],
      ),
    );
  }

  Future<void> _sendQueued() async {
    final text = _queueController.text.trim();
    if (text.isEmpty) return;
    await _run(() async {
      await agent.queueSubagentMessage(s.id, text);
      _queueController.clear();
    });
  }

  Future<void> _confirmForceStop() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr('Force stop')),
        content: Text(tr('Force stop kills the running tool at once; results may be incomplete.')),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: Text(tr('Cancel'))),
          FilledButton(onPressed: () => Navigator.of(context).pop(true), child: Text(tr('Force stop'))),
        ],
      ),
    );
    if (ok == true) await _run(() => agent.stopSubagent(s.id, force: true));
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(text, style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
    );
  }
}

class _ToolRow extends StatefulWidget {
  const _ToolRow({required this.tool});
  final SubagentToolRun tool;

  @override
  State<_ToolRow> createState() => _ToolRowState();
}

class _ToolRowState extends State<_ToolRow> {
  bool open = false;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final t = widget.tool;
    final icon = t.status == SubagentToolStatus.failed
        ? LucideIcons.circleX
        : t.status == SubagentToolStatus.done
        ? LucideIcons.circleCheck
        : LucideIcons.loaderCircle;
    final color = t.status == SubagentToolStatus.failed
        ? p.danger
        : t.status == SubagentToolStatus.done
        ? p.success
        : p.accent;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Material(
        color: p.surface,
        borderRadius: BorderRadius.circular(10),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => setState(() => open = !open),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(icon, size: 18, color: color),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        t.args.isEmpty ? t.name : '${t.name} ${t.args}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                    ),
                    Icon(open ? LucideIcons.chevronUp : LucideIcons.chevronDown, size: 18, color: p.faint),
                  ],
                ),
                if (open && t.output.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  SelectableText(
                    t.output.length > 2000 ? '${t.output.substring(0, 2000)}…' : t.output,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(fontFamily: 'monospace', color: p.muted),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
