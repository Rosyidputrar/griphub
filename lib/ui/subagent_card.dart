import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../agent/agent_controller.dart';
import '../agent/models.dart';
import '../agent/pricing.dart';
import '../agent/subagents.dart';
import 'i18n.dart';
import 'kit.dart';
import 'message_views.dart' show MarkdownText;
import 'theme.dart';

/// How many subagents the host runs at once (agent/src/subagent.ts MAX_RUNNING).
const subagentMaxRunning = 3;

// ---------------------------------------------------------------------------
// Shared wording and colours for one subagent

/// The status colour, used by the card border, the avatar and the status pill.
Color subagentColor(Palette p, SubagentStatus s) => switch (s) {
  SubagentStatus.running => p.accent,
  SubagentStatus.waitingApproval => p.warning,
  SubagentStatus.stopping => p.warning,
  SubagentStatus.queued => p.muted,
  SubagentStatus.done => p.success,
  SubagentStatus.failed => p.danger,
  SubagentStatus.stopped => p.muted,
};

IconData _statusIcon(SubagentStatus s) => switch (s) {
  SubagentStatus.running => LucideIcons.bot,
  SubagentStatus.waitingApproval => LucideIcons.shieldQuestion,
  SubagentStatus.stopping => LucideIcons.circlePause,
  SubagentStatus.queued => LucideIcons.hourglass,
  SubagentStatus.done => LucideIcons.circleCheck,
  SubagentStatus.failed => LucideIcons.circleX,
  SubagentStatus.stopped => LucideIcons.circleStop,
};

String _profileLabel(SubagentState s) => tr(s.profileKey);

/// What the subagent is doing, in the app's language. Built from the tool
/// name and its arguments; the host's own (English) line is only a fallback.
String? subagentActivity(SubagentState s) {
  switch (s.status) {
    case SubagentStatus.queued:
      return tr('Waiting for a free slot (up to {n} run at once)').replaceAll('{n}', '$subagentMaxRunning');
    case SubagentStatus.stopping:
      return tr('Stopping after the current step…');
    case SubagentStatus.waitingApproval:
      return tr('Waiting for your approval');
    case SubagentStatus.running:
      final tool = s.currentTool;
      if (tool == null) return tr(s.tools.isEmpty ? 'Starting…' : 'Working…');
      final a = s.currentArgs ?? '';
      String t(String key) => tr(key).replaceAll('{x}', a).replaceAll('{tool}', tool);
      return switch (tool) {
        'read' => t('Reading {x}'),
        'grep' => t('Searching for "{x}"'),
        'find' => t('Finding files {x}'),
        'ls' => t('Looking at {x}'),
        'web_search' => t('Searching the web for "{x}"'),
        'web_fetch' => t('Opening {x}'),
        'edit' || 'write' => t('Changing {x}'),
        'bash' => t('Running {x}'),
        _ => t('Using {tool}'),
      };
    case SubagentStatus.done || SubagentStatus.failed || SubagentStatus.stopped:
      return null;
  }
}

/// Why a stopped subagent stopped, in the app's language.
String subagentStopText(SubagentState s) => switch (s.stopCode) {
  SubagentStopCode.user => tr('Stopped by you.'),
  SubagentStopCode.force => tr('Force-stopped by you.'),
  SubagentStopCode.time => tr('The time limit was reached.'),
  SubagentStopCode.credit => tr('The cost limit was reached.'),
  SubagentStopCode.beforeStart => tr('Cancelled before it started.'),
  SubagentStopCode.limit => '${tr('Stopped by a limit')}: ${s.stopReason ?? ''}'.trim(),
  null => s.stopReason ?? tr('Stopped.'),
};

String _toolCount(int n) => n == 1 ? tr('1 tool') : tr('{n} tools').replaceAll('{n}', '$n');

String _creditsText(double c) => '~${localNumber(formatCredits(c))} ${tr('credits')}';

/// "4 tools • 1m 15s • ~0.06 credits"; [full] adds tokens.
String subagentMeta(SubagentState s, {bool full = false}) {
  final e = s.elapsed;
  final c = s.credits;
  return [
    _toolCount(s.tools.length),
    ?(e == null ? null : formatDurationShort(e)),
    if (full && s.totalTokens > 0) tr('{n} tokens').replaceAll('{n}', localNumber(formatTokens(s.totalTokens))),
    ?(c == null ? null : _creditsText(c)),
  ].join(' • ');
}

/// pi's thinking levels, as the composer labels them.
String thinkingLabel(String level) => tr(switch (level) {
  'off' => 'No thinking',
  'minimal' => 'Minimal',
  'low' => 'Low',
  'medium' => 'Medium',
  'high' => 'High',
  'xhigh' => 'Max',
  _ => level,
});

/// "Claude Opus 5.5 · High": the model at work and how hard it thinks.
String? subagentModelLine(SubagentState s) {
  final name = s.modelName ?? s.model;
  if (name == null) return null;
  final level = s.thinkingLevel;
  return level == null ? name : '$name · ${thinkingLabel(level)}';
}

/// The first readable line of a markdown report, for the card preview.
String _reportPreview(String report) {
  // Prefer the first body line; a heading ("## Summary") only says what follows.
  final lines = report.split('\n');
  final body = lines.where((l) => !RegExp(r'^\s*#').hasMatch(l)).join('\n');
  final fromBody = body.trim().isEmpty ? '' : _firstLine(body);
  return fromBody.isNotEmpty ? fromBody : _firstLine(report);
}

String _firstLine(String report) {
  for (final raw in report.split('\n')) {
    final line = raw
        .replaceAll(RegExp(r'^\s*(#+|[-*+>]|\d+\.)\s*'), '')
        .replaceAll(RegExp(r'[*_`~]'), '')
        .trim();
    if (line.isEmpty || RegExp(r'^\|?[\s:|-]+\|?$').hasMatch(line)) continue;
    return line.startsWith('|') ? line.replaceAll('|', ' ').replaceAll(RegExp(r'\s+'), ' ').trim() : line;
  }
  return '';
}

/// Repaints once a second while [state] runs, so durations tick.
mixin _Ticking<T extends StatefulWidget> on State<T> {
  Timer? _ticker;
  SubagentState get ticking;

  void startTicking() {
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      if (ticking.isActive) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }
}

/// Status pill with a dot; colour and text cross-fade on change.
class SubagentStatusPill extends StatelessWidget {
  const SubagentStatusPill(this.state, {super.key});
  final SubagentState state;

  @override
  Widget build(BuildContext context) {
    final c = subagentColor(context.palette, state.status);
    return AnimatedSwitcher(
      duration: Motion.of(context, Motion.fast),
      child: Pill(tr(state.statusKey), key: ValueKey(state.status), color: c, dot: true),
    );
  }
}

// ---------------------------------------------------------------------------
// Placement in the transcript

/// Where the open chat's subagent cards go: [cardFor] draws one at the
/// parent's `subagent` tool call; [trailing] are the ones whose call is not
/// in the transcript (started another way, or by an older host), shown
/// after it.
({Widget? Function(String toolCallId) cardFor, List<SubagentState> trailing}) placeSubagents(AgentController agent) {
  final all = agent.subagentsForCurrent;
  final byCall = {for (final s in all) ?s.toolCallId: s};
  final calls = {
    for (final e in agent.entries.whereType<AssistantEntry>())
      for (final b in e.blocks.values)
        if (b.kind == BlockKind.toolCall && b.toolName == 'subagent' && b.toolCallId != null) b.toolCallId!,
  };
  return (
    cardFor: (id) => switch (byCall[id]) {
      final st? => SubagentCard(key: ValueKey(st.id), state: st, agent: agent),
      null => null,
    },
    trailing: [for (final s in all) if (s.toolCallId == null || !calls.contains(s.toolCallId)) s],
  );
}

// ---------------------------------------------------------------------------
// Inline card

/// Subagent ids that already played their entrance, so scrolling a card back
/// into view does not replay it.
final _entered = <String>{};

/// The inline progress element for a subagent inside its parent chat, drawn
/// where the parent called the `subagent` tool.
///
/// Deliberately NOT a tool card: a filled surface with a status-coloured
/// border and an agent avatar, so it reads as "an agent working" rather than
/// "a tool call". Tapping it opens the detail sheet ([SubagentSheet]); an
/// approval can be answered right on the card.
class SubagentCard extends StatefulWidget {
  const SubagentCard({super.key, required this.state, required this.agent});
  final SubagentState state;
  final AgentController agent;

  @override
  State<SubagentCard> createState() => _SubagentCardState();
}

class _SubagentCardState extends State<SubagentCard> with _Ticking, SingleTickerProviderStateMixin {
  late final AnimationController _enter;

  @override
  SubagentState get ticking => widget.state;

  @override
  void initState() {
    super.initState();
    startTicking();
    final first = _entered.add(widget.state.id);
    _enter = AnimationController(vsync: this, duration: Motion.normal, value: first ? 0 : 1);
    if (first) _enter.forward();
  }

  @override
  void dispose() {
    _enter.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final text = Theme.of(context).textTheme;
    final s = widget.state;
    final compact = Appearance.instance.compact;
    final color = subagentColor(p, s.status);
    final activity = subagentActivity(s);
    final ap = s.approval;
    final duration = Motion.of(context, Motion.normal);
    if (Motion.reduced(context)) _enter.value = 1;

    // Below the header: what it does now, or how it ended.
    final Widget? detail = switch (s.status) {
      SubagentStatus.done when (s.report ?? '').trim().isNotEmpty => Text(
        _reportPreview(s.report!),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: text.bodyMedium,
      ),
      SubagentStatus.failed => Text(
        s.error ?? tr('Failed'),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: text.bodyMedium?.copyWith(color: p.danger),
      ),
      SubagentStatus.stopped => Text(
        subagentStopText(s),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: text.bodyMedium?.copyWith(color: p.muted),
      ),
      _ when activity != null => Text(
        activity,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: text.bodyMedium?.copyWith(color: s.status == SubagentStatus.queued ? p.muted : null),
      ),
      _ => null,
    };
    final progress = s.status == SubagentStatus.running || s.status == SubagentStatus.stopping;

    final card = AnimatedContainer(
      duration: duration,
      curve: Motion.curve,
      decoration: BoxDecoration(
        color: p.surface,
        borderRadius: BorderRadius.circular(Radii.lg),
        border: Border.all(color: color.withValues(alpha: 0.45), width: 1.2),
      ),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: BorderRadius.circular(Radii.lg),
          onTap: () => showSubagentSheet(context, s, widget.agent),
          child: Padding(
            padding: compact ? const EdgeInsets.fromLTRB(10, 10, 8, 10) : const EdgeInsets.fromLTRB(12, 12, 10, 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    AnimatedContainer(
                      duration: duration,
                      width: compact ? 32 : 40,
                      height: compact ? 32 : 40,
                      decoration: BoxDecoration(color: color.withValues(alpha: 0.14), shape: BoxShape.circle),
                      child: AnimatedSwitcher(
                        duration: Motion.of(context, Motion.fast),
                        child: Icon(
                          _statusIcon(s.status),
                          key: ValueKey(s.status),
                          size: compact ? 18 : 22,
                          color: color,
                        ),
                      ),
                    ),
                    SizedBox(width: compact ? 10 : 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // Wraps instead of overflowing on narrow phones and with large text.
                          Wrap(
                            spacing: 8,
                            runSpacing: 4,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              Text(
                                tr('Subagent').toUpperCase(),
                                style: text.labelSmall?.copyWith(color: color, fontWeight: FontWeight.w700, letterSpacing: 0.8),
                              ),
                              Text(_profileLabel(s), style: text.labelSmall),
                              SubagentStatusPill(s),
                            ],
                          ),
                          if (subagentModelLine(s) case final line?)
                            Padding(
                              padding: const EdgeInsets.only(top: 2),
                              child: Row(
                                children: [
                                  Icon(LucideIcons.cpu, size: 12, color: p.faint),
                                  const SizedBox(width: 4),
                                  Flexible(
                                    child: Text(
                                      line,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: text.labelSmall?.copyWith(fontWeight: FontWeight.w500),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          AnimatedSize(
                            duration: duration,
                            curve: Motion.curve,
                            alignment: Alignment.topLeft,
                            child: detail == null
                                ? const SizedBox(width: double.infinity)
                                : Padding(
                                    padding: EdgeInsets.only(top: compact ? 4 : 6),
                                    child: SizedBox(width: double.infinity, child: detail),
                                  ),
                          ),
                          SizedBox(height: compact ? 4 : 6),
                          Text(subagentMeta(s), style: text.labelSmall?.copyWith(fontWeight: FontWeight.w500)),
                          if (s.queue.isNotEmpty && s.isActive) ...[
                            const SizedBox(height: 2),
                            Text(
                              tr('{n} queued messages').replaceAll('{n}', '${s.queue.length}'),
                              style: text.labelSmall?.copyWith(color: p.muted, fontWeight: FontWeight.w500),
                            ),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(width: 4),
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Icon(LucideIcons.chevronRight, size: 20, color: p.faint),
                    ),
                  ],
                ),
                AnimatedSize(
                  duration: duration,
                  curve: Motion.curve,
                  alignment: Alignment.topCenter,
                  child: progress
                      ? Padding(
                          padding: EdgeInsets.only(top: compact ? 8 : 10),
                          child: LinearProgressIndicator(
                            color: color,
                            backgroundColor: p.raised,
                            minHeight: 3,
                            borderRadius: BorderRadius.circular(Radii.xs),
                          ),
                        )
                      : const SizedBox(width: double.infinity),
                ),
                AnimatedSize(
                  duration: duration,
                  curve: Motion.curve,
                  alignment: Alignment.topCenter,
                  child: ap != null && s.status == SubagentStatus.waitingApproval
                      ? Padding(
                          padding: EdgeInsets.only(top: compact ? 8 : 10),
                          child: SubagentApprovalPanel(
                            key: ValueKey(ap.approvalId),
                            state: s,
                            approval: ap,
                            agent: widget.agent,
                            compact: true,
                          ),
                        )
                      : const SizedBox(width: double.infinity),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    return FadeTransition(
      opacity: CurvedAnimation(parent: _enter, curve: Motion.curve),
      child: SlideTransition(
        position: Tween(begin: const Offset(0, 0.08), end: Offset.zero).animate(CurvedAnimation(parent: _enter, curve: Motion.curve)),
        child: Semantics(
          button: true,
          label: '${tr('Subagent')}, ${tr(s.statusKey)}',
          child: card,
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Approval

/// A subagent's pending risky step: what it wants to do, and Deny / Always /
/// Allow, like the chat's own approval card. The buttons disable on the first
/// tap so a double-tap can't answer twice.
class SubagentApprovalPanel extends StatefulWidget {
  const SubagentApprovalPanel({
    super.key,
    required this.state,
    required this.approval,
    required this.agent,
    this.compact = false,
  });
  final SubagentState state;
  final SubagentApproval approval;
  final AgentController agent;

  /// On the card: the summary is clipped to a few lines.
  final bool compact;

  @override
  State<SubagentApprovalPanel> createState() => _SubagentApprovalPanelState();
}

class _SubagentApprovalPanelState extends State<SubagentApprovalPanel> {
  bool _responded = false;

  Future<void> _answer({required bool allow, bool always = false}) async {
    if (_responded) return;
    setState(() => _responded = true);
    HapticFeedback.selectionClick();
    final ap = widget.approval;
    try {
      await widget.agent.replySubagentApproval(
        widget.state.id,
        ap.approvalId,
        allow,
        always: always,
        key: always && ap.key.isNotEmpty ? ap.key : null,
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _responded = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr(e.toString()))));
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final text = Theme.of(context).textTheme;
    final ap = widget.approval;
    // "Always" needs a key to remember; requests outside a tool call have none.
    final canAlways = ap.key.isNotEmpty;
    const h = Size(0, 42);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: p.warning.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(Radii.md),
        border: Border.all(color: p.warning.withValues(alpha: 0.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              IconTile(icon: toolIcon(ap.toolName), color: p.warning, size: 30),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('${tr('Allow')} ${ap.toolName}?', style: text.titleSmall),
                    if (ap.reason.isNotEmpty) Text(tr(ap.reason), style: text.bodySmall),
                  ],
                ),
              ),
            ],
          ),
          if (ap.summary.isNotEmpty) ...[
            const SizedBox(height: 8),
            Container(
              constraints: BoxConstraints(maxHeight: widget.compact ? 64 : 140),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(color: p.raised, borderRadius: BorderRadius.circular(Radii.sm)),
              child: SingleChildScrollView(
                child: SelectableText(
                  ap.summary,
                  style: TextStyle(fontFamily: mono, fontSize: 12, height: 1.45, color: p.text),
                ),
              ),
            ),
          ],
          const SizedBox(height: 10),
          LayoutBuilder(
            builder: (context, constraints) {
              final deny = OutlinedButton(
                onPressed: _responded ? null : () => _answer(allow: false),
                style: OutlinedButton.styleFrom(minimumSize: h, foregroundColor: p.danger, backgroundColor: p.bg),
                child: Text(tr('Deny')),
              );
              final always = OutlinedButton(
                onPressed: _responded ? null : () => _answer(allow: true, always: true),
                style: OutlinedButton.styleFrom(minimumSize: h, backgroundColor: p.bg),
                child: Text(tr('Always')),
              );
              final allow = FilledButton(
                onPressed: _responded ? null : () => _answer(allow: true),
                style: FilledButton.styleFrom(minimumSize: h, padding: const EdgeInsets.symmetric(horizontal: 12)),
                child: Text(tr('Allow')),
              );
              final buttons = [deny, if (canAlways) always, allow];
              // Equal thirds must fit the widest label; otherwise stack (narrow phone, large text).
              final labels = [tr('Deny'), if (canAlways) tr('Always'), tr('Allow')];
              final style = Theme.of(context).textTheme.labelLarge;
              final scaler = MediaQuery.textScalerOf(context);
              var widest = 0.0;
              for (final l in labels) {
                final tp = TextPainter(
                  text: TextSpan(text: l, style: style),
                  textScaler: scaler,
                  maxLines: 1,
                  textDirection: Directionality.of(context),
                )..layout();
                if (tp.width > widest) widest = tp.width;
                tp.dispose();
              }
              final fits = (widest + 40) * buttons.length + 8 * (buttons.length - 1) <= constraints.maxWidth;
              if (!fits) {
                // Most likely answer on top, the destructive one last.
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    allow,
                    if (canAlways) ...[const SizedBox(height: 8), always],
                    const SizedBox(height: 8),
                    deny,
                  ],
                );
              }
              return Row(
                children: [
                  for (var i = 0; i < buttons.length; i++) ...[
                    if (i > 0) const SizedBox(width: 8),
                    Expanded(child: buttons[i]),
                  ],
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Detail sheet

Future<void> showSubagentSheet(BuildContext context, SubagentState state, AgentController agent) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (context) => FractionallySizedBox(
      heightFactor: 0.9,
      child: SubagentSheet(state: state, agent: agent),
    ),
  );
}

/// Detail sheet: what the agent is doing and how far, approval, how it ended
/// and its report, the parent's prompt, tools with results, the queue, and
/// stop controls.
class SubagentSheet extends StatefulWidget {
  const SubagentSheet({super.key, required this.state, required this.agent});
  final SubagentState state;
  final AgentController agent;

  @override
  State<SubagentSheet> createState() => _SubagentSheetState();
}

class _SubagentSheetState extends State<SubagentSheet> with _Ticking {
  final _queueController = TextEditingController();
  bool _sending = false;

  /// The live state: a re-sent record may have replaced the object the sheet was opened with.
  SubagentState get s => agent.subagentStore[widget.state.id] ?? widget.state;
  AgentController get agent => widget.agent;

  @override
  SubagentState get ticking => s;

  @override
  void initState() {
    super.initState();
    startTicking();
    _queueController.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _queueController.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() f) async {
    try {
      await f();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr(e.toString()))));
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(listenable: agent, builder: (context, _) => _build(context));
  }

  Widget _build(BuildContext context) {
    final p = context.palette;
    final text = Theme.of(context).textTheme;
    final s = this.s;
    final color = subagentColor(p, s.status);
    final duration = Motion.of(context, Motion.normal);
    final activity = subagentActivity(s);
    final canQueue =
        s.status == SubagentStatus.running ||
        s.status == SubagentStatus.waitingApproval ||
        s.status == SubagentStatus.queued;
    final report = (s.report ?? '').trim();
    // The cost limit only works when the model's price is known.
    final costUnknown = s.startedAt != null && s.credits == null && s.requests > 0;

    Widget section(String title, {Widget? trailing}) =>
        SectionLabel(title, trailing: trailing, padding: const EdgeInsets.fromLTRB(0, 20, 0, 8));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 8, 8),
          child: Row(
            children: [
              AnimatedContainer(
                duration: duration,
                width: 40,
                height: 40,
                decoration: BoxDecoration(color: color.withValues(alpha: 0.14), shape: BoxShape.circle),
                child: Icon(_statusIcon(s.status), size: 22, color: color),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(tr('Subagent'), style: text.titleMedium),
                    const SizedBox(height: 2),
                    Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [SubagentStatusPill(s), Text(_profileLabel(s), style: text.labelSmall)],
                    ),
                  ],
                ),
              ),
              IconButton(
                icon: const Icon(LucideIcons.x),
                tooltip: tr('Close'),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 28),
            children: [
              // Now / summary.
              AnimatedSwitcher(
                duration: Motion.of(context, Motion.fast),
                layoutBuilder: (current, previous) =>
                    Stack(alignment: Alignment.topLeft, children: [...previous, ?current]),
                child: activity == null
                    ? const SizedBox.shrink()
                    : Padding(
                        key: ValueKey(activity),
                        padding: const EdgeInsets.only(bottom: 4),
                        child: Text(activity, style: text.bodyLarge),
                      ),
              ),
              Text(subagentMeta(s, full: true), style: text.bodySmall),
              const SizedBox(height: 12),
              SubagentCostPanel(state: s),
              if (costUnknown)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: _Note(
                    icon: LucideIcons.info,
                    color: p.muted,
                    text: tr("This model's price is unknown, so the cost limit can't stop this subagent; the time limit still applies."),
                  ),
                ),
              AnimatedSize(
                duration: duration,
                curve: Motion.curve,
                alignment: Alignment.topCenter,
                child: s.status == SubagentStatus.running || s.status == SubagentStatus.stopping
                    ? Padding(
                        padding: const EdgeInsets.only(top: 10),
                        child: LinearProgressIndicator(
                          color: color,
                          backgroundColor: p.raised,
                          minHeight: 3,
                          borderRadius: BorderRadius.circular(Radii.xs),
                        ),
                      )
                    : const SizedBox(width: double.infinity),
              ),
              // Approval.
              AnimatedSize(
                duration: duration,
                curve: Motion.curve,
                alignment: Alignment.topCenter,
                child: switch (s.approval) {
                  final ap? when s.status == SubagentStatus.waitingApproval => Padding(
                    padding: const EdgeInsets.only(top: 16),
                    child: SubagentApprovalPanel(key: ValueKey(ap.approvalId), state: s, approval: ap, agent: agent),
                  ),
                  _ => const SizedBox(width: double.infinity),
                },
              ),
              // How it ended, and the report.
              if (s.isTerminal) ...[
                const SizedBox(height: 14),
                switch (s.status) {
                  SubagentStatus.failed => _Note(icon: LucideIcons.circleX, color: p.danger, text: s.error ?? tr('Failed')),
                  SubagentStatus.stopped => _Note(icon: LucideIcons.circleStop, color: p.muted, text: subagentStopText(s)),
                  _ => _Note(icon: LucideIcons.circleCheck, color: p.success, text: tr('Finished; the report went back to the parent chat.')),
                },
                section(
                  s.status == SubagentStatus.done ? tr('Report') : tr('Partial report'),
                  trailing: report.isEmpty
                      ? null
                      : TextButton.icon(
                          onPressed: () {
                            Clipboard.setData(ClipboardData(text: report));
                            ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('Copied'))));
                          },
                          icon: const Icon(LucideIcons.copy),
                          label: Text(tr('Copy')),
                        ),
                ),
                if (report.isEmpty)
                  Text(tr('No report.'), style: text.bodyMedium?.copyWith(color: p.faint))
                else
                  MarkdownText(report),
              ],
              section(tr('Task from the parent')),
              SelectableText(s.brief, style: text.bodyMedium),
              section('${tr('Tools used')} (${s.tools.length})'),
              if (s.tools.isEmpty)
                Text(
                  tr(s.isActive ? 'No tools used yet.' : 'No tools were used.'),
                  style: text.bodyMedium?.copyWith(color: p.faint),
                )
              else
                for (final t in s.tools) _ToolRow(key: ValueKey(t.id), tool: t),
              // Queue.
              if (canQueue) ...[
                section('${tr('Queue')} (${s.queue.length})'),
                Text(
                  tr('Queued messages are sent in order once the current step finishes.'),
                  style: text.bodySmall,
                ),
                const SizedBox(height: 8),
                AnimatedSize(
                  duration: duration,
                  curve: Motion.curve,
                  alignment: Alignment.topCenter,
                  child: Column(
                    children: [for (var i = 0; i < s.queue.length; i++) _queueRow(index: i, count: s.queue.length)],
                  ),
                ),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _queueController,
                        minLines: 1,
                        maxLines: 4,
                        textInputAction: TextInputAction.send,
                        decoration: InputDecoration(hintText: tr('Message for the subagent')),
                        onSubmitted: (_) => _sendQueued(),
                      ),
                    ),
                    const SizedBox(width: 8),
                    _SendButton(
                      enabled: _queueController.text.trim().isNotEmpty && !_sending,
                      busy: _sending,
                      onPressed: _sendQueued,
                    ),
                  ],
                ),
              ],
              if (s.status == SubagentStatus.stopping) ...[
                const SizedBox(height: 16),
                _Note(
                  icon: LucideIcons.circlePause,
                  color: p.warning,
                  text: tr('Stopping: the subagent finishes its current step, then reports what it has so far.'),
                ),
              ],
              // Stop controls.
              if (s.isActive) ...[
                const SizedBox(height: 20),
                if (s.status == SubagentStatus.queued)
                  OutlinedButton.icon(
                    onPressed: () => _run(() => agent.stopSubagent(s.id)),
                    icon: const Icon(LucideIcons.x, size: 18),
                    label: Text(tr('Cancel subagent')),
                  )
                else
                  _ButtonPair(
                    first: s.status == SubagentStatus.stopping
                        ? null
                        : OutlinedButton(
                            onPressed: () => _run(() => agent.stopSubagent(s.id)),
                            child: Text(tr('Stop gracefully')),
                          ),
                    firstLabel: tr('Stop gracefully'),
                    second: OutlinedButton(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: p.danger,
                        side: BorderSide(color: p.danger.withValues(alpha: 0.6)),
                      ),
                      onPressed: _confirmForceStop,
                      child: Text(tr('Force stop')),
                    ),
                    secondLabel: tr('Force stop'),
                  ),
                const SizedBox(height: 8),
                if (s.status == SubagentStatus.queued)
                  Text(tr('It has not started, so nothing is lost.'), style: text.bodySmall)
                else ...[
                  if (s.status != SubagentStatus.stopping)
                    Text(
                      tr('Stop gracefully waits for the current tool, then stops with a partial report.'),
                      style: text.bodySmall,
                    ),
                  const SizedBox(height: 4),
                  Text(tr('Force stop kills the running tool at once; results may be incomplete.'), style: text.bodySmall),
                ],
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _queueRow({required int index, required int count}) {
    final p = context.palette;
    final q = s.queue[index];
    return Padding(
      key: ValueKey(q.id),
      padding: const EdgeInsets.only(bottom: 8),
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 4, 2, 4),
        decoration: BoxDecoration(color: p.surface, borderRadius: BorderRadius.circular(Radii.md)),
        child: Row(
          children: [
            Text('${index + 1}', style: TextStyle(fontFamily: mono, fontSize: 12, color: p.faint)),
            const SizedBox(width: 10),
            Expanded(child: Text(q.text, maxLines: 3, overflow: TextOverflow.ellipsis)),
            IconButton(
              visualDensity: VisualDensity.compact,
              icon: const Icon(LucideIcons.chevronUp, size: 18),
              onPressed: index == 0 ? null : () => _run(() => agent.moveQueuedSubagentMessage(s.id, q.id, 'up')),
              tooltip: tr('Move up'),
            ),
            IconButton(
              visualDensity: VisualDensity.compact,
              icon: const Icon(LucideIcons.chevronDown, size: 18),
              onPressed: index == count - 1 ? null : () => _run(() => agent.moveQueuedSubagentMessage(s.id, q.id, 'down')),
              tooltip: tr('Move down'),
            ),
            IconButton(
              visualDensity: VisualDensity.compact,
              icon: Icon(LucideIcons.trash2, size: 18, color: p.danger),
              onPressed: () => _run(() => agent.removeQueuedSubagentMessage(s.id, q.id)),
              tooltip: tr('Delete'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _sendQueued() async {
    final text = _queueController.text.trim();
    if (text.isEmpty || _sending) return;
    setState(() => _sending = true);
    await _run(() async {
      await agent.queueSubagentMessage(s.id, text);
      _queueController.clear();
    });
    if (mounted) setState(() => _sending = false);
  }

  Future<void> _confirmForceStop() async {
    final ok = await confirmSubagentForceStop(context);
    if (ok) await _run(() => agent.stopSubagent(s.id, force: true));
  }
}

/// The destructive confirm for a force stop, styled like the app's other
/// destructive dialogs (danger-filled confirm).
Future<bool> confirmSubagentForceStop(BuildContext context) async {
  final p = context.palette;
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(tr('Force stop this subagent?')),
      content: Text(tr('Force stop kills the running tool at once; results may be incomplete.')),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(false), child: Text(tr('Cancel'))),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: p.danger, foregroundColor: Colors.white),
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(tr('Force stop')),
        ),
      ],
    ),
  );
  return ok == true;
}

/// Two buttons side by side, or stacked when either label would be clipped.
class _ButtonPair extends StatelessWidget {
  const _ButtonPair({required this.first, required this.firstLabel, required this.second, required this.secondLabel});
  final Widget? first;
  final String firstLabel;
  final Widget second;
  final String secondLabel;

  @override
  Widget build(BuildContext context) {
    if (first == null) return SizedBox(width: double.infinity, child: second);
    return LayoutBuilder(
      builder: (context, constraints) {
        final style = Theme.of(context).textTheme.labelLarge;
        double w(String l) {
          final tp = TextPainter(
            text: TextSpan(text: l, style: style),
            textScaler: MediaQuery.textScalerOf(context),
            maxLines: 1,
            textDirection: Directionality.of(context),
          )..layout();
          final width = tp.width;
          tp.dispose();
          return width;
        }

        final half = (constraints.maxWidth - 8) / 2;
        // 36 = the outlined button's horizontal padding.
        if (w(firstLabel) + 36 > half || w(secondLabel) + 36 > half) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [first!, const SizedBox(height: 8), second],
          );
        }
        return Row(
          children: [
            Expanded(child: first!),
            const SizedBox(width: 8),
            Expanded(child: second),
          ],
        );
      },
    );
  }
}

/// The queue's send button: solid like the composer's, dimmed until there is text.
class _SendButton extends StatelessWidget {
  const _SendButton({required this.enabled, required this.busy, required this.onPressed});
  final bool enabled;
  final bool busy;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return AnimatedOpacity(
      duration: Motion.of(context, Motion.fast),
      opacity: enabled || busy ? 1 : 0.4,
      child: Material(
        color: p.text,
        shape: const CircleBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: enabled ? onPressed : null,
          child: Tooltip(
            message: tr('Add to queue'),
            child: SizedBox.square(
              dimension: 46,
              child: Center(
                child: busy
                    ? BusySpinner(color: p.inverse)
                    : Icon(LucideIcons.sendHorizontal, size: 20, color: p.inverse),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A tinted one-line notice with an icon.
class _Note extends StatelessWidget {
  const _Note({required this.icon, required this.color, required this.text});
  final IconData icon;
  final Color color;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(Radii.md),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(padding: const EdgeInsets.only(top: 2), child: Icon(icon, size: 16, color: color)),
          const SizedBox(width: 8),
          Expanded(
            child: SelectableText(
              text,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: color == context.palette.muted ? null : color),
            ),
          ),
        ],
      ),
    );
  }
}

/// One tool the subagent used, styled like the chat's tool rows: status,
/// tool icon, name and argument in mono; tap to open its output.
class _ToolRow extends StatefulWidget {
  const _ToolRow({super.key, required this.tool});
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
    final Widget indicator = switch (t.status) {
      SubagentToolStatus.done => Icon(LucideIcons.check, size: 15, color: p.success),
      SubagentToolStatus.failed => Icon(LucideIcons.x, size: 15, color: p.danger),
      SubagentToolStatus.running =>
        BusySpinner(size: 12),
    };
    final took = t.finishedAt?.difference(t.startedAt);
    final output = t.output.length > 2000 ? '${t.output.substring(0, 2000)}…' : t.output;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Container(
        decoration: BoxDecoration(borderRadius: BorderRadius.circular(Radii.md), border: Border.all(color: p.border)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            InkWell(
              borderRadius: BorderRadius.circular(Radii.md),
              onTap: () => setState(() => open = !open),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 9, 6, 9),
                child: Row(
                  children: [
                    SizedBox.square(dimension: 16, child: Center(child: indicator)),
                    const SizedBox(width: 10),
                    Icon(toolIcon(t.name), size: 15, color: p.accent),
                    const SizedBox(width: 6),
                    Text(
                      t.name,
                      style: TextStyle(fontFamily: mono, fontSize: 12.5, fontWeight: FontWeight.w600, color: p.text),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        t.args,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontFamily: mono, fontSize: 12.5, color: p.muted),
                      ),
                    ),
                    if (took != null) ...[
                      const SizedBox(width: 6),
                      Text(formatDurationShort(took), style: TextStyle(fontSize: 11.5, color: p.faint)),
                    ],
                    AnimatedRotation(
                      turns: open ? 0.5 : 0,
                      duration: Motion.of(context, Motion.fast),
                      curve: Motion.curve,
                      child: Icon(LucideIcons.chevronDown, size: 18, color: p.faint),
                    ),
                  ],
                ),
              ),
            ),
            AnimatedSize(
              duration: Motion.of(context, Motion.normal),
              curve: Motion.curve,
              alignment: Alignment.topCenter,
              child: !open
                  ? const SizedBox(width: double.infinity)
                  : Container(
                      width: double.infinity,
                      margin: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(color: p.surface, borderRadius: BorderRadius.circular(Radii.sm)),
                      child: SelectableText(
                        [
                          if (t.args.isNotEmpty) t.args,
                          if (t.args.isNotEmpty) '',
                          output.isEmpty
                              ? tr(t.status == SubagentToolStatus.running ? 'No output yet.' : 'No output.')
                              : output,
                        ].join('\n'),
                        style: TextStyle(fontFamily: mono, fontSize: 12, height: 1.45, color: p.muted),
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Cross-chat banner

/// Banner shown in a chat while subagents run in OTHER chats. Tapping it
/// jumps to the parent chat (never a new chat), or lets you pick one when
/// several chats have subagents. Inside the app the parent's title is fine to
/// show — notifications, which reach the lock screen, never carry titles.
class CrossChatBanner extends StatelessWidget {
  const CrossChatBanner({super.key, required this.agent});
  final AgentController agent;

  @override
  Widget build(BuildContext context) {
    final elsewhere = agent.subagentsElsewhere;
    return AnimatedSize(
      duration: Motion.of(context, Motion.normal),
      curve: Motion.curve,
      alignment: Alignment.bottomCenter,
      child: elsewhere.isEmpty ? const SizedBox(width: double.infinity) : _banner(context, elsewhere),
    );
  }

  Widget _banner(BuildContext context, List<SubagentState> elsewhere) {
    final p = context.palette;
    final chats = _byChat(elsewhere);
    final asking = elsewhere.where((s) => s.status == SubagentStatus.waitingApproval).toList();
    final color = asking.isNotEmpty ? p.warning : p.accent;
    String name(SubagentState s) => s.parentTitle.isEmpty ? tr('another chat') : s.parentTitle;
    final text = asking.isNotEmpty && chats.length == 1
        ? tr("A subagent in '{name}' needs your approval").replaceAll('{name}', name(asking.first))
        : asking.isNotEmpty
        ? tr('Subagents in other chats need your approval')
        : chats.length == 1
        ? (elsewhere.length == 1
              ? tr("Subagent running in chat '{name}'")
              : tr("{n} subagents running in chat '{name}'").replaceAll('{n}', '${elsewhere.length}'))
              .replaceAll('{name}', name(elsewhere.first))
        : tr('{n} subagents running in {m} other chats')
              .replaceAll('{n}', '${elsewhere.length}')
              .replaceAll('{m}', '${chats.length}');
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
      child: Material(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(Radii.md),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => chats.length == 1 ? _jump(context, chats.keys.first) : _pick(context, chats),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
            child: Row(
              children: [
                Icon(asking.isNotEmpty ? LucideIcons.shieldQuestion : LucideIcons.bot, size: 20, color: color),
                const SizedBox(width: 10),
                Expanded(child: Text(text, style: Theme.of(context).textTheme.bodyMedium)),
                const SizedBox(width: 6),
                Text(
                  tr(chats.length == 1 ? 'Open' : 'Choose'),
                  style: Theme.of(context).textTheme.labelLarge?.copyWith(color: p.text),
                ),
                Icon(LucideIcons.chevronRight, size: 18, color: p.faint),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Active subagents grouped by parent chat, oldest chat first.
  static Map<String, List<SubagentState>> _byChat(List<SubagentState> list) {
    final out = <String, List<SubagentState>>{};
    for (final s in list) {
      (out[s.parentSessionFile] ??= []).add(s);
    }
    return out;
  }

  Future<void> _pick(BuildContext context, Map<String, List<SubagentState>> chats) async {
    final path = await showModalBottomSheet<String>(
      context: context,
      builder: (context) {
        final p = context.palette;
        final text = Theme.of(context).textTheme;
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 0, 4, 12),
                  child: Text(tr('Chats with subagents'), style: text.titleLarge),
                ),
                SettingsGroup(
                  children: [
                    for (final e in chats.entries)
                      SettingsRow(
                        icon: e.value.any((s) => s.status == SubagentStatus.waitingApproval)
                            ? LucideIcons.shieldQuestion
                            : LucideIcons.messageSquare,
                        color: e.value.any((s) => s.status == SubagentStatus.waitingApproval) ? p.warning : p.accent,
                        title: e.value.first.parentTitle.isEmpty ? tr('Untitled chat') : e.value.first.parentTitle,
                        subtitle: [
                          e.value.length == 1
                              ? tr('1 subagent')
                              : tr('{n} subagents').replaceAll('{n}', '${e.value.length}'),
                          for (final st in {for (final s in e.value) s.status}) tr(SubagentState.statusKeyOf(st)),
                        ].join(' • '),
                        onTap: () => Navigator.of(context).pop(e.key),
                      ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
    if (path != null && context.mounted) await _jump(context, path);
  }

  Future<void> _jump(BuildContext context, String path) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final known = (await agent.listSessions()).any((s) => s.path == path);
      if (!known) {
        messenger.showSnackBar(SnackBar(content: Text(tr('That chat is no longer available.'))));
        return;
      }
      HapticFeedback.selectionClick();
      if (!await agent.openSession(path)) return;
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(tr(e.toString()))));
    }
  }
}

/// Model, thinking level and the running cost, line by line: requests,
/// tokens (cache included, as GripHub bills them), how many requests were
/// raised to the model's minimum, and the estimate in credits and rupiah.
class SubagentCostPanel extends StatelessWidget {
  const SubagentCostPanel({super.key, required this.state});
  final SubagentState state;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final text = Theme.of(context).textTheme;
    final s = state;
    Widget row(IconData icon, String label, String value, {Color? color}) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Icon(icon, size: 15, color: p.faint),
          const SizedBox(width: 8),
          Expanded(child: Text(label, style: text.bodySmall)),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              value,
              textAlign: TextAlign.end,
              style: text.bodyMedium?.copyWith(color: color, fontFeatures: const [FontFeature.tabularFigures()]),
            ),
          ),
        ],
      ),
    );
    final cached = s.cacheReadTokens + s.cacheWriteTokens;
    final c = s.credits;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      decoration: BoxDecoration(color: p.surface, borderRadius: BorderRadius.circular(Radii.md)),
      child: Column(
        children: [
          if (s.modelName ?? s.model case final name?) row(LucideIcons.cpu, tr('Model'), name),
          if (s.thinkingLevel case final level?) row(LucideIcons.brain, tr('Thinking'), thinkingLabel(level)),
          if (s.rate case final r?) row(LucideIcons.tag, tr('Rate'), tr('{n} credits / 1M tokens').replaceAll('{n}', localNumber(formatCredits(r)))),
          row(
            LucideIcons.activity,
            tr('Requests'),
            s.flooredRequests > 0
                ? tr('{n} ({m} at the minimum)').replaceAll('{n}', '${s.requests}').replaceAll('{m}', '${s.flooredRequests}')
                : '${s.requests}',
          ),
          row(
            LucideIcons.layers,
            tr('Tokens billed'),
            cached > 0
                ? tr('{n} ({m}% cache)').replaceAll('{n}', localNumber(formatTokens(s.totalTokens))).replaceAll('{m}', '${(cached / s.totalTokens * 100).round()}')
                : localNumber(formatTokens(s.totalTokens)),
          ),
          row(
            LucideIcons.coins,
            tr(s.isActive ? 'Cost so far' : 'Cost'),
            c == null ? '—' : '~${localNumber(formatCredits(c))} ${tr('credits')} · Rp ${(c * kRupiahPerCredit).round()}',
            color: c == null ? p.faint : null,
          ),
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              tr('Estimated per request at GripHub\'s live rate, including cache and each model\'s minimum; the exact charge is in Usage.'),
              style: text.bodySmall?.copyWith(color: p.faint),
            ),
          ),
        ],
      ),
    );
  }
}
