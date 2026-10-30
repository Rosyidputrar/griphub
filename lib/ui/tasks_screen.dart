import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:simple_icons/simple_icons.dart';

import '../agent/agent_controller.dart';
import '../agent/features.dart';
import 'chat_screen.dart';
import 'illustration.dart';
import 'kit.dart';
import 'i18n.dart';
import 'theme.dart';

String _basename(String path) {
  final parts = path.split(RegExp(r'[\\/]')).where((s) => s.isNotEmpty).toList();
  return parts.isEmpty ? path : parts.last;
}

String _describeSchedule(ScheduleInfo s) {
  final t = s.trigger;
  if (t != null && t['type'] == 'github_issues') {
    return 'GitHub issues labelled ${t['label'] ?? '?'} in ${t['repo'] ?? '?'}';
  }
  if (s.dailyAt != null) return 'daily at ${s.dailyAt}';
  final m = s.everyMinutes;
  if (m == null) return 'manual';
  if (m % 1440 == 0) return m == 1440 ? 'every day' : 'every ${m ~/ 1440} days';
  if (m % 60 == 0) return m == 60 ? 'every hour' : 'every ${m ~/ 60} h';
  return 'every $m min';
}

/// Background agent work: a queue of runs, parallelism, and schedules/triggers
/// that keep pi working while the user is elsewhere.
class TasksScreen extends StatefulWidget {
  const TasksScreen({super.key, required this.agent});
  final AgentController agent;

  @override
  State<TasksScreen> createState() => _TasksScreenState();
}

class _TasksScreenState extends State<TasksScreen> with BusyActions {
  final _prompt = TextEditingController();
  bool _queueing = false;

  /// Runs swiped away and not back from the host yet: a dismissed card must leave the list at once.
  final _hidden = <String>{};

  AgentController get agent => widget.agent;
  Features get f => agent.features;

  @override
  void initState() {
    super.initState();
    f.refreshRuns().catchError((Object e) => _error(e));
  }

  @override
  void dispose() {
    _prompt.dispose();
    super.dispose();
  }

  void _error(Object e) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
  }

  Future<void> _guard(Future<void> Function() task) async {
    try {
      await task();
    } catch (e) {
      _error(e);
    }
  }

  Future<void> _queue() async {
    final text = _prompt.text.trim();
    if (text.isEmpty) return;
    setState(() => _queueing = true);
    try {
      final firstLine = text.split('\n').first;
      await f.enqueue(text, title: firstLine.length > 60 ? '${firstLine.substring(0, 60)}…' : firstLine);
      _prompt.clear();
      if (mounted) FocusScope.of(context).unfocus();
    } catch (e) {
      _error(e);
    } finally {
      if (mounted) setState(() => _queueing = false);
    }
  }

  /// Swiped away: removed from the list (its chat stays), with Undo.
  Future<void> _removeRun(RunInfo run) async {
    setState(() => _hidden.add(run.id));
    final messenger = ScaffoldMessenger.of(context);
    try {
      final removed = await f.deleteRun(run.id);
      if (removed == null) return;
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(
        SnackBar(
          content: Text(tr('Run removed')),
          action: SnackBarAction(
            label: tr('Undo'),
            onPressed: () => _guard(() async {
              await f.restoreRun(removed.run, removed.index);
              if (mounted) setState(() => _hidden.remove(run.id));
            }),
          ),
        ),
      );
    } catch (e) {
      if (mounted) setState(() => _hidden.remove(run.id));
      _error(e);
    }
  }

  Future<void> _openRun(RunInfo run) async {
    try {
      if (!await agent.openSession(run.sessionFile!) || !mounted) return;
      await Navigator.of(context).push(MaterialPageRoute(builder: (_) => ChatScreen(agent: agent)));
    } catch (e) {
      _error(e);
    }
  }

  Future<void> _editSchedule([ScheduleInfo? existing]) async {
    // The sheet saves itself and only closes on success: the old flow
    // popped with the edits first and saved afterwards, so a failed save
    // lost the user's work behind a snackbar.
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _ScheduleSheet(
        existing: existing,
        defaultCwd: agent.cwd,
        onSave: (m) => f.saveSchedule(m),
      ),
    );
  }

  Future<void> _deleteSchedule(ScheduleInfo s) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr('Delete schedule?')),
        content: Text('"${s.name}" ${tr('will stop running.')}'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(tr('Cancel'))),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: context.palette.danger),
            child: Text(tr('Delete')),
          ),
        ],
      ),
    );
    if (ok == true) await _onSchedule(s, () => f.deleteSchedule(s.id));
  }

  /// One change to a schedule at a time (run, switch, delete), with a spinner on its row meanwhile.
  Future<bool> _onSchedule(ScheduleInfo s, Future<void> Function() task) async {
    if (busy(s.id)) return false;
    try {
      return await runBusy(s.id, () async {
            await task();
            return true;
          }) ??
          false;
    } catch (e) {
      _error(e);
      return false;
    }
  }

  Future<void> _runNow(ScheduleInfo s) async {
    // "Queued" only when it was: a refusal (budget, a full disk, no GitHub sign-in) says so instead.
    if (!await _onSchedule(s, () => f.runScheduleNow(s.id)) || !mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text('${tr('Queued')}: "${s.name}"')));
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final text = Theme.of(context).textTheme;
    return ListenableBuilder(
      listenable: f,
      builder: (context, _) {
        final runs = f.runs.where((r) => !_hidden.contains(r.id)).toList();
        final finished = runs.where((r) => !r.active).length;
        return Scaffold(
          appBar: AppBar(title: Text(tr('Tasks'))),
          body: RefreshIndicator(
            onRefresh: () => _guard(f.refreshRuns),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 40),
              children: [
                SectionLabel(tr('Run in background'), padding: EdgeInsets.fromLTRB(4, 8, 4, 10)),
                SurfaceCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      TextField(
                        controller: _prompt,
                        minLines: 2,
                        maxLines: 6,
                        textInputAction: TextInputAction.newline,
                        decoration: InputDecoration(hintText: tr('What should the agent do while you are away?')),
                      ),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          Icon(LucideIcons.folder, size: 14, color: p.muted),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              agent.cwd.isEmpty ? 'workspace' : _basename(agent.cwd),
                              overflow: TextOverflow.ellipsis,
                              style: text.bodySmall?.copyWith(fontFamily: mono),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      PrimaryButton(label: tr('Queue'), icon: LucideIcons.listTodo, busy: _queueing, onPressed: _queue),
                      const SizedBox(height: 18),
                      Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(tr('Parallel agents'), style: text.titleSmall),
                                Text(tr('How many run at once'), style: text.bodySmall),
                              ],
                            ),
                          ),
                          PillSegments<int>(
                            value: f.concurrency.clamp(1, 3),
                            options: const {1: '1', 2: '2', 3: '3'},
                            onChanged: (v) => _guard(() => f.setConcurrency(v)),
                            expand: false,
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                SectionLabel(
                  tr('Runs'),
                  trailing: finished > 0
                      ? TextButton.icon(
                          onPressed: () => _guard(f.clearRuns),
                          icon: const Icon(LucideIcons.x, size: 14),
                          label: Text(tr('Clear finished')),
                        )
                      : null,
                ),
                if (runs.isEmpty)
                  SurfaceCard(
                    child: Column(
                      children: [
                        const Illustration('automate', height: 140),
                        const SizedBox(height: 8),
                        Text(tr('No runs yet. Queue a prompt above.'), style: text.bodySmall),
                      ],
                    ),
                  )
                else
                  for (final r in runs)
                    // Finished runs swipe away either way; queued and running ones are cancelled from the card.
                    Padding(
                      key: ValueKey(r.id),
                      padding: const EdgeInsets.only(bottom: 10),
                      child: r.active
                          ? _RunCard(
                              run: r,
                              onCancel: () => _guard(() => f.cancelRun(r.id)),
                              onOpen: r.sessionFile != null ? () => _openRun(r) : null,
                            )
                          : Dismissible(
                              key: ValueKey('dismiss-${r.id}'),
                              background: const _RemoveBackground(alignment: Alignment.centerLeft),
                              secondaryBackground: const _RemoveBackground(alignment: Alignment.centerRight),
                              onDismissed: (_) => _removeRun(r),
                              child: _RunCard(
                                run: r,
                                onCancel: () => _guard(() => f.cancelRun(r.id)),
                                onOpen: r.sessionFile != null ? () => _openRun(r) : null,
                              ),
                            ),
                    ),
                SectionLabel(
                  tr('Schedules'),
                  trailing: TextButton.icon(
                    onPressed: () => _editSchedule(),
                    icon: const Icon(LucideIcons.plus, size: 14),
                    label: Text(tr('New schedule')),
                  ),
                ),
                if (f.schedules.isEmpty)
                  SurfaceCard(
                    onTap: () => _editSchedule(),
                    child: Row(
                      children: [
                        IconTile(icon: LucideIcons.calendarClock, color: p.accentAlt),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Text(
                            tr('Run a prompt every few hours, daily, or when a labelled GitHub issue appears.'),
                            style: text.bodySmall,
                          ),
                        ),
                      ],
                    ),
                  )
                else
                  SettingsGroup(
                    children: [
                      for (final s in f.schedules)
                        _ScheduleRow(
                          schedule: s,
                          busy: busy(s.id),
                          onTap: () => _editSchedule(s),
                          onToggle: (v) => _onSchedule(s, () => f.saveSchedule({...s.json, 'enabled': v})),
                          onRunNow: () => _runNow(s),
                          onDelete: () => _deleteSchedule(s),
                        ),
                    ],
                  ),
                const SizedBox(height: 14),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(LucideIcons.info, size: 14, color: p.faint),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        tr('Schedules run while GripHub AI Agent is alive; a persistent notification keeps it running.'),
                        style: text.bodySmall?.copyWith(color: p.muted),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Behind a run card being swiped away.
class _RemoveBackground extends StatelessWidget {
  const _RemoveBackground({required this.alignment});
  final Alignment alignment;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Container(
      alignment: alignment,
      padding: const EdgeInsets.symmetric(horizontal: 22),
      decoration: BoxDecoration(
        color: p.danger.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(Radii.xl),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(LucideIcons.trash2, size: 18, color: p.danger),
          const SizedBox(width: 8),
          Text(tr('Remove'), style: TextStyle(color: p.danger, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}

class _RunCard extends StatelessWidget {
  const _RunCard({required this.run, required this.onCancel, this.onOpen});
  final RunInfo run;
  final VoidCallback onCancel;
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final text = Theme.of(context).textTheme;
    final Widget status = switch (run.status) {
      'running' => BusySpinner(size: 18, color: p.accent),
      'queued' => Icon(LucideIcons.clock, size: 18, color: p.muted),
      'done' => Icon(LucideIcons.circleCheck, size: 18, color: p.success),
      'error' => Icon(LucideIcons.circleX, size: 18, color: p.danger),
      'cancelled' => Icon(LucideIcons.ban, size: 18, color: p.faint),
      _ => Icon(LucideIcons.circleDashed, size: 18, color: p.muted),
    };
    // Only runs that didn't come from the queue say where they came from.
    final source = switch (run.source) {
      'schedule' => tr('Scheduled'),
      'trigger' => tr('From GitHub issue'),
      _ => null,
    };
    final (label, color) = switch (run.status) {
      'running' => (tr('In progress'), p.accent),
      'queued' => (tr('Waiting'), p.muted),
      'done' => (tr('Done'), p.success),
      'error' => (tr('Failed'), p.danger),
      'cancelled' => (tr('Cancelled'), p.faint),
      _ => (run.status, p.muted),
    };
    final when = run.finishedAt ?? run.createdAt;
    final summary = run.summary;
    final open = run.active ? null : onOpen;
    return SurfaceCard(
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 14),
      onTap: open,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              status,
              const SizedBox(width: 12),
              Expanded(
                child: Text(run.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: text.titleSmall),
              ),
              const SizedBox(width: 8),
              Pill(label, color: color),
              if (run.active)
                IconButton(
                  tooltip: tr('Cancel'),
                  onPressed: onCancel,
                  icon: Icon(LucideIcons.x, size: 18, color: p.muted),
                )
              else if (open != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(6, 0, 8, 0),
                  child: Icon(LucideIcons.chevronRight, size: 18, color: p.faint),
                )
              else
                const SizedBox(width: 8),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(left: 30, right: 8),
            child: Text(
              [?source, formatAgo(when), if (run.cwd.isNotEmpty) _basename(run.cwd)].join(' · '),
              style: text.bodySmall?.copyWith(color: p.muted),
            ),
          ),
          if (summary != null && summary.isNotEmpty) ...[
            const SizedBox(height: 6),
            Padding(
              padding: const EdgeInsets.only(left: 30, right: 8),
              child: Text(summary, maxLines: 2, overflow: TextOverflow.ellipsis, style: text.bodyMedium),
            ),
          ],
        ],
      ),
    );
  }
}

class _ScheduleRow extends StatelessWidget {
  const _ScheduleRow({
    required this.schedule,
    required this.onTap,
    required this.onToggle,
    required this.onRunNow,
    required this.onDelete,
    this.busy = false,
  });
  final ScheduleInfo schedule;

  /// A change to it is on its way: a spinner, and its switch and menu wait.
  final bool busy;
  final VoidCallback onTap;
  final ValueChanged<bool> onToggle;
  final VoidCallback onRunNow;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final s = schedule;
    final isTrigger = s.trigger != null;
    final last = s.lastRun;
    return SettingsRow(
      leading: isTrigger
          ? IconTile(icon: SimpleIcons.github, color: p.text)
          : IconTile(icon: LucideIcons.calendarClock, color: s.enabled ? p.accentAlt : p.faint),
      title: s.name,
      subtitle: '${_describeSchedule(s)}${last != null ? ' · ${tr('last run')} ${formatAgo(last)}' : ''}',
      onTap: busy ? null : onTap,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (busy) ...[const BusySpinner(), const SizedBox(width: 4)],
          Switch(value: s.enabled, onChanged: busy ? null : onToggle),
          PopupMenuButton<String>(
            enabled: !busy,
            icon: Icon(LucideIcons.ellipsis, size: 18, color: p.muted),
            onSelected: (v) => switch (v) {
              'run' => onRunNow(),
              'edit' => onTap(),
              _ => onDelete(),
            },
            itemBuilder: (_) => [
              PopupMenuItem(value: 'run', child: Text(tr('Run now'))),
              PopupMenuItem(value: 'edit', child: Text(tr('Edit'))),
              PopupMenuItem(value: 'delete', child: Text(tr('Delete'), style: TextStyle(color: p.danger))),
            ],
          ),
        ],
      ),
    );
  }
}

enum _Kind { interval, daily, github }

/// Create/edit form for a schedule; pops the json map to save.
class _ScheduleSheet extends StatefulWidget {
  const _ScheduleSheet({this.existing, required this.defaultCwd, required this.onSave});
  final ScheduleInfo? existing;
  final String defaultCwd;

  /// Saves the schedule; the sheet stays open with the error when it throws.
  final Future<void> Function(Map<String, dynamic> schedule) onSave;

  @override
  State<_ScheduleSheet> createState() => _ScheduleSheetState();
}

class _ScheduleSheetState extends State<_ScheduleSheet> {
  static const _presets = [15, 30, 60, 180, 720, 1440];

  late final _name = TextEditingController(text: widget.existing?.name ?? '');
  late final _prompt = TextEditingController(text: widget.existing?.prompt ?? '');
  late final _minutes = TextEditingController(text: '${widget.existing?.everyMinutes ?? 60}');
  late final _repo = TextEditingController(text: widget.existing?.trigger?['repo'] as String? ?? '');
  late final _label = TextEditingController(text: widget.existing?.trigger?['label'] as String? ?? '');
  late _Kind _kind;
  late TimeOfDay _time;
  String? _problem;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _kind = e?.trigger != null
        ? _Kind.github
        : e?.dailyAt != null
        ? _Kind.daily
        : _Kind.interval;
    _time = const TimeOfDay(hour: 9, minute: 0);
    final at = e?.dailyAt?.split(':');
    if (at != null && at.length == 2) {
      _time = TimeOfDay(hour: int.tryParse(at[0]) ?? 9, minute: int.tryParse(at[1]) ?? 0);
    }
  }

  @override
  void dispose() {
    for (final c in [_name, _prompt, _minutes, _repo, _label]) {
      c.dispose();
    }
    super.dispose();
  }

  String _hhmm(TimeOfDay t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  String _presetLabel(int m) => m < 60 ? '${m}m' : (m < 1440 ? '${m ~/ 60}h' : '${m ~/ 1440}d');

  Future<void> _save() async {
    if (_saving) return;
    final name = _name.text.trim();
    final prompt = _prompt.text.trim();
    if (name.isEmpty || prompt.isEmpty) {
      setState(() => _problem = 'Name and prompt are required.');
      return;
    }
    final e = widget.existing;
    final out = <String, dynamic>{
      'id': ?e?.id,
      'name': name,
      'prompt': prompt,
      'cwd': e?.cwd.isNotEmpty == true ? e!.cwd : widget.defaultCwd,
      'enabled': e?.enabled ?? true,
      'everyMinutes': null,
      'dailyAt': null,
      'trigger': null,
    };
    switch (_kind) {
      case _Kind.interval:
        final m = int.tryParse(_minutes.text.trim());
        if (m == null || m < 15) {
          setState(() => _problem = 'Interval must be at least 15 minutes.');
          return;
        }
        out['everyMinutes'] = m;
      case _Kind.daily:
        out['dailyAt'] = _hhmm(_time);
      case _Kind.github:
        final repo = _repo.text.trim();
        final label = _label.text.trim();
        if (!RegExp(r'^[\w.-]+/[\w.-]+$').hasMatch(repo) || label.isEmpty) {
          setState(() => _problem = 'Enter the repo as owner/repo and a label.');
          return;
        }
        out['trigger'] = {'type': 'github_issues', 'repo': repo, 'label': label};
    }
    setState(() {
      _saving = true;
      _problem = null;
    });
    try {
      await widget.onSave(out);
    } catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _problem = '$e';
        });
      }
      return;
    }
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final text = Theme.of(context).textTheme;
    final minutes = int.tryParse(_minutes.text.trim());
    final cwd = widget.existing?.cwd.isNotEmpty == true ? widget.existing!.cwd : widget.defaultCwd;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 28),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(widget.existing == null ? 'New schedule' : 'Edit schedule', style: text.titleLarge),
            const SizedBox(height: 16),
            TextField(
              controller: _name,
              textCapitalization: TextCapitalization.sentences,
              decoration: InputDecoration(labelText: tr('Name')),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _prompt,
              minLines: 3,
              maxLines: 8,
              decoration: InputDecoration(labelText: tr('Prompt'), alignLabelWithHint: true),
            ),
            const SizedBox(height: 16),
            PillSegments<_Kind>(
              value: _kind,
              options: {
                _Kind.interval: tr('Interval'),
                _Kind.daily: tr('Daily'),
                _Kind.github: tr('GitHub trigger'),
              },
              onChanged: (v) => setState(() {
                _kind = v;
                _problem = null;
              }),
            ),
            const SizedBox(height: 14),
            ...switch (_kind) {
              _Kind.interval => [
                TextField(
                  controller: _minutes,
                  keyboardType: TextInputType.number,
                  onChanged: (_) => setState(() {}),
                  decoration: InputDecoration(labelText: tr('Every (minutes)'), helperText: tr('At least 15')),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final m in _presets)
                      ChoiceChip(
                        label: Text(_presetLabel(m)),
                        selected: minutes == m,
                        onSelected: (_) => setState(() => _minutes.text = '$m'),
                      ),
                  ],
                ),
              ],
              _Kind.daily => [
                SurfaceCard(
                  padding: const EdgeInsets.all(14),
                  onTap: () async {
                    final t = await showTimePicker(context: context, initialTime: _time);
                    if (t != null) setState(() => _time = t);
                  },
                  child: Row(
                    children: [
                      Icon(LucideIcons.clock, size: 18, color: p.muted),
                      const SizedBox(width: 12),
                      Expanded(child: Text(tr('Every day at'), style: text.bodyMedium)),
                      Text(_hhmm(_time), style: text.titleMedium?.copyWith(fontFamily: mono)),
                    ],
                  ),
                ),
              ],
              _Kind.github => [
                TextField(
                  controller: _repo,
                  autocorrect: false,
                  style: const TextStyle(fontFamily: mono),
                  decoration: InputDecoration(labelText: tr('Repository'), hintText: 'owner/repo'),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _label,
                  autocorrect: false,
                  decoration: InputDecoration(labelText: tr('Label'), hintText: 'agent'),
                ),
                const SizedBox(height: 6),
                Text(
                  tr('The agent picks up new issues with this label. The issue is added to your prompt.'),
                  style: text.bodySmall,
                ),
              ],
            },
            const SizedBox(height: 14),
            Row(
              children: [
                Icon(LucideIcons.folder, size: 14, color: p.muted),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    cwd.isEmpty ? 'workspace' : cwd,
                    overflow: TextOverflow.ellipsis,
                    style: text.bodySmall?.copyWith(fontFamily: mono),
                  ),
                ),
              ],
            ),
            if (_problem != null) ...[
              const SizedBox(height: 10),
              Text(_problem!, style: text.bodySmall?.copyWith(color: p.danger)),
            ],
            const SizedBox(height: 18),
            PrimaryButton(label: tr('Save'), icon: LucideIcons.check, busy: _saving, onPressed: _save),
          ],
        ),
      ),
    );
  }
}
