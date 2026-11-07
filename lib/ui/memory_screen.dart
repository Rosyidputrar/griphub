import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../agent/agent_controller.dart';
import '../agent/integrations.dart';
import '../agent/models.dart';
import 'errors.dart';
import 'i18n.dart';
import 'kit.dart';
import 'theme.dart';

/// Agent memory (agent/src/memory.ts) in the app: the proposal card in the chat, the screen that lists, edits and
/// deletes what the agent remembers, and what a chat started with.

String memoryLayerLabel(String layer) => layer == 'project' ? tr('Project memory (agent)') : tr('Global memory');

/// One line for Settings.
String memorySummary(AppSettings? s) => s?.json['memory'] == false ? tr('Off') : tr('What the agent remembers about you');

/// The card of a `remember` call: the fact the agent proposes, and the user's Save / Edit / Refuse. Nothing is kept
/// before Save; a refused text (a secret) says why instead.
class MemoryProposalCard extends StatefulWidget {
  const MemoryProposalCard({super.key, required this.agent, required this.run, this.readOnly = false});
  final AgentController agent;
  final ToolRun? run;

  /// In a chat shown read-only: an open proposal is answered there once it opens, not from here.
  final bool readOnly;

  @override
  State<MemoryProposalCard> createState() => _MemoryProposalCardState();
}

class _MemoryProposalCardState extends State<MemoryProposalCard> {
  bool _busy = false;

  Future<void> _decide(MemoryProposal p, {required bool save, String? text}) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await widget.agent.decideMemory(p.id, save: save, text: text);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(friendlyError(e))));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _edit(MemoryProposal p) async {
    final text = await editMemoryText(context, title: tr('Edit before saving'), initial: p.text);
    if (text != null && text.trim().isNotEmpty) await _decide(p, save: true, text: text);
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final text = Theme.of(context).textTheme;
    final details = widget.run?.details;
    final refused = details?['refused'] as String?;
    final raw = details?['proposal'];
    final initial = raw is Map ? MemoryProposal(raw.cast<String, dynamic>()) : null;
    final proposal = initial == null ? null : widget.agent.memoryProposals[initial.id] ?? initial;
    return Container(
      decoration: BoxDecoration(
        color: p.surface,
        borderRadius: BorderRadius.circular(Radii.lg),
        border: Border.all(color: p.border),
      ),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(padding: const EdgeInsets.only(top: 1), child: Icon(LucideIcons.brain, size: 18, color: p.accent)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  refused != null
                      ? tr('Not proposed to remember')
                      : proposal == null
                      ? tr('Proposing something to remember…')
                      : tr('Remember this?'),
                  style: text.titleSmall,
                ),
              ),
              if (proposal != null) Text(memoryLayerLabel(proposal.layer), style: text.bodySmall?.copyWith(color: p.muted)),
            ],
          ),
          if (refused != null)
            Padding(
              padding: const EdgeInsets.only(top: 6, left: 26),
              child: Text(tr(refused.replaceFirst(RegExp(r'^Not proposed: '), '')), style: text.bodySmall?.copyWith(color: p.muted)),
            ),
          if (proposal != null) ...[
            Padding(
              padding: const EdgeInsets.only(top: 8, left: 26),
              child: Text(proposal.text, style: text.bodyLarge),
            ),
            if (proposal.replacesText != null)
              Padding(
                padding: const EdgeInsets.only(top: 4, left: 26),
                child: Text(
                  tr('Replaces: {fact}').replaceAll('{fact}', proposal.replacesText!),
                  style: text.bodySmall?.copyWith(color: p.muted),
                ),
              ),
            const SizedBox(height: 6),
            Padding(
              padding: const EdgeInsets.only(left: 18),
              child: switch (proposal.status) {
                'saved' => _Decided(icon: LucideIcons.check, label: tr('Saved to memory')),
                'rejected' => _Decided(icon: LucideIcons.x, label: tr('Not saved')),
                _ when widget.readOnly => _Decided(icon: LucideIcons.lock, label: tr('Read-only until the agent is free.')),
                _ => Wrap(
                  spacing: 4,
                  children: [
                    TextButton(onPressed: _busy ? null : () => _decide(proposal, save: true), child: Text(tr('Save'))),
                    TextButton(onPressed: _busy ? null : () => _edit(proposal), child: Text(tr('Edit'))),
                    TextButton(onPressed: _busy ? null : () => _decide(proposal, save: false), child: Text(tr('Refuse'))),
                  ],
                ),
              },
            ),
          ],
        ],
      ),
    );
  }
}

class _Decided extends StatelessWidget {
  const _Decided({required this.icon, required this.label});
  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 4),
      child: Row(
        children: [
          Icon(icon, size: 14, color: p.muted),
          const SizedBox(width: 6),
          Text(label, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: p.muted)),
        ],
      ),
    );
  }
}

/// Asks for a memory's text; null when cancelled.
Future<String?> editMemoryText(BuildContext context, {required String title, String initial = ''}) =>
    showDialog<String>(context: context, builder: (_) => _MemoryTextDialog(title: title, initial: initial));

class _MemoryTextDialog extends StatefulWidget {
  const _MemoryTextDialog({required this.title, required this.initial});
  final String title;
  final String initial;

  @override
  State<_MemoryTextDialog> createState() => _MemoryTextDialogState();
}

class _MemoryTextDialogState extends State<_MemoryTextDialog> {
  late final field = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    field.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    content: TextField(controller: field, autofocus: true, maxLines: 4, minLines: 1, maxLength: 400),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: Text(tr('Cancel'))),
      FilledButton(onPressed: () => Navigator.pop(context, field.text), child: Text(tr('Save'))),
    ],
  );
}

/// Settings → Memory (global), or a project's memory from its tools: every fact with where it came from and when it
/// was last confirmed; edit, delete, delete all. Deleting is real: gone from the file and from the next chat's start.
class MemoryScreen extends StatefulWidget {
  const MemoryScreen({super.key, required this.agent, this.project});
  final AgentController agent;

  /// The project folder; null for the global memory.
  final String? project;

  @override
  State<MemoryScreen> createState() => _MemoryScreenState();
}

class _MemoryScreenState extends State<MemoryScreen> {
  AgentController get agent => widget.agent;
  String get layer => widget.project == null ? 'global' : 'project';
  ({List<MemoryEntry> entries, String host, bool on})? _data;
  Object? _error;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final d = await agent.memoryList(layer, project: widget.project);
      if (mounted) {
        setState(() {
          _data = d;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _run(Future<void> Function() op) async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      await op();
      await _load();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(friendlyError(e))));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _edit(MemoryEntry e) async {
    final text = await editMemoryText(context, title: tr('Edit memory'), initial: e.text);
    if (text != null && text.trim().isNotEmpty && text.trim() != e.text) {
      await _run(() => agent.memoryUpdate(layer, e.id, text, project: widget.project));
    }
  }

  Future<void> _add() async {
    final text = await editMemoryText(context, title: tr('Add to memory'));
    if (text != null && text.trim().isNotEmpty) await _run(() => agent.memoryAdd(layer, text, project: widget.project));
  }

  Future<void> _clear() async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr('Delete all memories?')),
        content: Text(tr('They are deleted for good and no new chat starts with them.')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(tr('Cancel'))),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(tr('Delete all'))),
        ],
      ),
    );
    if (yes == true) await _run(() => agent.memoryClear(layer, project: widget.project));
  }

  Future<void> _setOn(bool on) => _run(() async {
    await agent.integrations.updateSettings({'memory': on});
  });

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final text = Theme.of(context).textTheme;
    final d = _data;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.project == null ? tr("Agent's memory") : tr('Project memory (agent)')),
        actions: [
          if (d != null && d.entries.isNotEmpty)
            IconButton(tooltip: tr('Delete all'), onPressed: _saving ? null : _clear, icon: const Icon(LucideIcons.trash2, size: 20)),
        ],
      ),
      floatingActionButton: d == null
          ? null
          : FloatingActionButton.small(onPressed: _saving ? null : _add, tooltip: tr('Add to memory'), child: const Icon(LucideIcons.plus)),
      body: _error != null
          ? ErrorNotice(error: _error, onRetry: _load, center: true)
          : d == null
          ? const Center(child: BusySpinner.page())
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 96),
              children: [
                if (widget.project == null) ...[
                  SettingsGroup(
                    children: [
                      SettingsRow(
                        icon: LucideIcons.brain,
                        color: p.accent,
                        title: tr("Agent's memory"),
                        subtitle: tr('Brought into every new chat'),
                        trailing: LabeledSwitch(label: tr("Agent's memory"), value: d.on, onChanged: _saving ? null : _setOn),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                ] else
                  Padding(
                    padding: const EdgeInsets.fromLTRB(4, 0, 4, 10),
                    child: Text(widget.project!, style: text.bodySmall?.copyWith(color: p.muted, fontFamily: mono)),
                  ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
                  child: Text(
                    [
                      tr('Short facts the agent keeps across chats, saved only when you say so. Never passwords or keys.'),
                      d.host == 'server'
                          ? tr('Kept on the server agent. It does not move to the phone when you switch.')
                          : tr('Kept on this phone. It does not move to a server agent when you switch.'),
                    ].join(' '),
                    style: text.bodySmall,
                  ),
                ),
                if (d.entries.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(tr('Nothing remembered yet.'), style: text.bodyMedium?.copyWith(color: p.muted), textAlign: TextAlign.center),
                  )
                else
                  SettingsGroup(children: [for (final e in d.entries) _EntryRow(entry: e, onEdit: () => _edit(e), onDelete: () => _run(() => agent.memoryRemove(layer, e.id, project: widget.project)))]),
              ],
            ),
    );
  }
}

/// A history line as the host keeps it (`m-1a2b (2026-11-06): "old text"`), without the internal id.
String _replacedLine(String raw) {
  final m = RegExp(r'^m-[0-9a-f]+ \(([^)]*)\): "(.*)"$').firstMatch(raw);
  if (m == null) return tr('replaced {what}').replaceAll('{what}', raw);
  return tr('replaced "{fact}" ({date})').replaceAll('{fact}', m.group(2)!).replaceAll('{date}', m.group(1)!);
}

/// One fact: its text as the title, where it came from and when it was confirmed in the quiet line under it.
class _EntryRow extends StatelessWidget {
  const _EntryRow({required this.entry, required this.onEdit, required this.onDelete});
  final MemoryEntry entry;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final text = Theme.of(context).textTheme;
    final source = entry.source == 'you' ? tr('added by you') : tr('from {chat}').replaceAll('{chat}', entry.source);
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        onTap: onEdit,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 4, 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(entry.text, style: text.bodyLarge),
                    const SizedBox(height: 3),
                    Text(
                      '$source · ${entry.createdAt} · ${tr('confirmed {date}').replaceAll('{date}', entry.confirmedAt)}',
                      style: text.bodySmall?.copyWith(color: p.muted),
                    ),
                    for (final r in entry.replaced)
                      Text(_replacedLine(r), style: text.bodySmall?.copyWith(color: p.muted)),
                  ],
                ),
              ),
              IconButton(tooltip: tr('Delete'), onPressed: onDelete, icon: Icon(LucideIcons.trash2, size: 18, color: p.muted)),
            ],
          ),
        ),
      ),
    );
  }
}

/// What the open chat started with from memory ("what the agent remembered when this chat began").
class MemorySnapshotScreen extends StatelessWidget {
  const MemorySnapshotScreen({super.key, required this.agent});
  final AgentController agent;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final text = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: Text(tr('What the agent remembered'))),
      body: FutureBuilder<MemorySnapshotInfo?>(
        future: agent.memorySnapshot(),
        builder: (context, snap) {
          if (snap.hasError) return ErrorNotice(error: snap.error, center: true);
          if (snap.connectionState != ConnectionState.done) return const Center(child: BusySpinner.page());
          final s = snap.data;
          if (s == null || s.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Text(tr('This chat started with nothing from memory.'), style: text.bodyMedium?.copyWith(color: p.muted), textAlign: TextAlign.center),
              ),
            );
          }
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 40),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
                child: Text(tr('Exactly what this chat started with. Changes to memory apply to new chats.'), style: text.bodySmall),
              ),
              if (s.global.isNotEmpty) ...[
                SectionLabel(tr('Global memory')),
                SettingsGroup(children: [for (final f in s.global) _Fact(f)]),
              ],
              if (s.project.isNotEmpty) ...[
                SectionLabel(tr('Project memory (agent)')),
                SettingsGroup(children: [for (final f in s.project) _Fact(f)]),
              ],
              if (s.left > 0)
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 10, 4, 0),
                  child: Text(tr('{n} older facts did not fit the budget.').replaceAll('{n}', '${s.left}'), style: text.bodySmall),
                ),
            ],
          );
        },
      ),
    );
  }
}

class _Fact extends StatelessWidget {
  const _Fact(this.text);
  final String text;

  @override
  Widget build(BuildContext context) =>
      Padding(padding: const EdgeInsets.fromLTRB(14, 12, 14, 12), child: Text(text, style: Theme.of(context).textTheme.bodyLarge));
}
