import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../agent/models.dart';
import '../agent/subagents.dart';
import 'code_view.dart';
import 'diff_view.dart';
import 'i18n.dart';
import 'kit.dart';
import 'message_views.dart';
import 'theme.dart';

/// A subagent's work as the chat shows its own: what it thought, what it wrote between steps, each tool call with its
/// command, content, changes and output (copy and syntax highlighting as in the chat), and what the person sent it, in
/// the order it happened. The step being written now shows live at the end.
class SubagentTimeline extends StatelessWidget {
  const SubagentTimeline({super.key, required this.state});
  final SubagentState state;

  @override
  Widget build(BuildContext context) {
    final s = state;
    final placed = <String>{};
    final children = <Widget>[];
    for (final (i, e) in s.timeline.indexed) {
      final Widget? w = switch (e.kind) {
        SubagentEntryKind.thinking => ThinkingView(key: ValueKey('t$i'), text: e.text, live: false),
        SubagentEntryKind.text => MarkdownText(e.text, key: ValueKey('x$i')),
        SubagentEntryKind.user => SubagentSentMessage(key: ValueKey('u$i'), text: e.text),
        SubagentEntryKind.tool => switch (s.tool(e.toolId ?? '')) {
          final t? => SubagentToolCard(key: ValueKey('tool:${t.id}'), tool: t),
          null => null,
        },
      };
      if (w == null) continue;
      if (e.kind == SubagentEntryKind.tool) placed.add(e.toolId!);
      children.add(w);
    }
    // Calls with no place in the timeline (a host from before it kept one): at the end, in the order they ran.
    for (final t in s.tools) {
      if (!placed.contains(t.id)) children.add(SubagentToolCard(key: ValueKey('tool:${t.id}'), tool: t));
    }
    // What is being written now.
    if (s.liveThinking.trim().isNotEmpty) {
      children.add(ThinkingView(key: const ValueKey('live-thinking'), text: s.liveThinking, live: true));
    }
    if (s.liveText.trim().isNotEmpty) {
      children.add(TypewriterMarkdown(key: const ValueKey('live-text'), text: s.liveText, live: true));
    }
    for (final MapEntry(key: id, value: raw) in s.liveArgs.entries) {
      if (s.tool(id) != null) continue;
      children.add(_WritingCard(key: ValueKey('writing:$id'), name: s.liveNames[id] ?? 'tool', raw: raw));
    }
    if (children.isEmpty) {
      final text = Theme.of(context).textTheme;
      return Text(
        tr(s.isActive ? 'No steps yet.' : 'No steps were recorded.'),
        style: text.bodyMedium?.copyWith(color: context.palette.faint),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final (i, c) in children.indexed) ...[if (i > 0) const SizedBox(height: 10), c],
      ],
    );
  }
}

/// A message the person sent the subagent while it worked, on the right, as in the chat.
class SubagentSentMessage extends StatelessWidget {
  const SubagentSentMessage({super.key, required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Align(
      alignment: Alignment.centerRight,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: bubbleWidth(context)),
        child: Semantics(
          label: tr('You sent'),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(color: p.raised, borderRadius: BorderRadius.circular(Radii.lg)),
            child: Text(text, style: Theme.of(context).textTheme.bodyMedium),
          ),
        ),
      ),
    );
  }
}

/// The file extension of [path], lower case, or null.
String? _ext(String? path) {
  if (path == null || !path.contains('.')) return null;
  return path.split('.').last.toLowerCase();
}

/// An edit's replacements as a unified patch for [DiffView]. Line numbers count from each replacement (the file's own
/// are not known here).
String? editPatch(Map<String, dynamic>? input) {
  if (input == null) return null;
  final path = input['path'] as String? ?? 'file';
  final edits = <(String, String)>[];
  final list = input['edits'];
  if (list is List) {
    for (final e in list.whereType<Map>()) {
      if (e['oldText'] is String && e['newText'] is String) edits.add((e['oldText'] as String, e['newText'] as String));
    }
  }
  if (input['oldText'] is String && input['newText'] is String) {
    edits.add((input['oldText'] as String, input['newText'] as String));
  }
  if (edits.isEmpty) return null;
  final b = StringBuffer('--- a/$path\n+++ b/$path\n');
  for (final (old, now) in edits) {
    final o = old.split('\n');
    final n = now.split('\n');
    b.writeln('@@ -1,${o.length} +1,${n.length} @@');
    for (final l in o) {
      b.writeln('-$l');
    }
    for (final l in n) {
      b.writeln('+$l');
    }
  }
  return b.toString();
}

/// One tool call of a subagent, as the chat's tool card: what it runs or writes visible at once with Copy and syntax
/// highlighting, the rest (input, changes, output, pictures) when opened. Says to a screen reader how it went and
/// whether it is open.
class SubagentToolCard extends StatefulWidget {
  const SubagentToolCard({super.key, required this.tool});
  final SubagentToolRun tool;

  @override
  State<SubagentToolCard> createState() => _SubagentToolCardState();
}

class _SubagentToolCardState extends State<SubagentToolCard> {
  bool open = false;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final t = widget.tool;
    final input = t.input;
    final path = input?['path'] as String?;
    final ext = _ext(path);
    final command = t.name == 'bash' ? (input?['command'] as String?) : null;
    final content = t.name == 'write' ? (input?['content'] as String?) : null;
    final patch = t.name == 'edit' ? editPatch(input) : null;
    final took = t.finishedAt?.difference(t.startedAt);
    final Widget indicator = switch (t.status) {
      SubagentToolStatus.done => Icon(LucideIcons.check, size: 15, color: p.success),
      SubagentToolStatus.failed => Icon(LucideIcons.x, size: 15, color: p.danger),
      SubagentToolStatus.running => BusySpinner(size: 12),
    };
    final statusWord = tr(switch (t.status) {
      SubagentToolStatus.done => 'Done',
      SubagentToolStatus.failed => 'Failed',
      SubagentToolStatus.running => 'Running',
    });
    final summary = t.args.isNotEmpty ? t.args : (path ?? '');
    final output = t.output.trimRight();

    // What it runs or writes: shown without opening the card, as in the chat.
    final Widget? shown = command != null && command.isNotEmpty
        ? CodeBox(text: command, label: 'bash', language: 'bash', maxHeight: 200, lineNumbers: false)
        : content != null
        ? CodeBox(text: content, label: path?.split('/').last, language: ext, maxHeight: 240)
        : null;

    return Container(
      decoration: BoxDecoration(borderRadius: BorderRadius.circular(Radii.md), border: Border.all(color: p.border)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            expanded: open,
            child: InkWell(
              borderRadius: BorderRadius.circular(Radii.md),
              onTap: () => setState(() => open = !open),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 9, 6, 9),
                child: Row(
                  children: [
                    Semantics(
                      label: statusWord,
                      liveRegion: t.status != SubagentToolStatus.running,
                      child: ExcludeSemantics(child: SizedBox.square(dimension: 16, child: Center(child: indicator))),
                    ),
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
                        summary,
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
          ),
          if (shown != null) Padding(padding: const EdgeInsets.fromLTRB(8, 0, 8, 8), child: shown),
          if (t.images.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              child: ToolImages(images: t.images, title: path?.split('/').last ?? t.name),
            ),
          ClipRect(
            child: AnimatedSize(
              duration: Motion.of(context, Motion.normal),
              curve: Motion.curve,
              alignment: Alignment.topCenter,
              child: !open
                  ? const SizedBox(width: double.infinity)
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Divider(height: 1, color: p.border),
                        Padding(
                          padding: const EdgeInsets.all(10),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              if (patch != null)
                                ToolSection(
                                  label: tr('Changes'),
                                  child: DiffView(patch: patch, showHeaders: false, maxHeight: 320),
                                )
                              else if (shown == null && input != null && input.isNotEmpty)
                                ToolSection(
                                  label: tr('Input'),
                                  child: CodeBox(
                                    text: const JsonEncoder.withIndent('  ').convert(input),
                                    label: 'json',
                                    maxHeight: 220,
                                  ),
                                ),
                              if (patch != null || (shown == null && input != null && input.isNotEmpty))
                                const SizedBox(height: 10),
                              ToolSection(
                                label: tr(t.status == SubagentToolStatus.failed ? 'Error' : 'Output'),
                                child: output.isEmpty
                                    ? Text(
                                        tr(t.status == SubagentToolStatus.running ? 'No output yet.' : 'No output.'),
                                        style: Theme.of(context).textTheme.bodySmall,
                                      )
                                    : CodeBox(text: output, label: 'output', lineNumbers: false, maxHeight: 320),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A tool call whose arguments are still being written: for a file, its newest lines as they arrive.
class _WritingCard extends StatelessWidget {
  const _WritingCard({super.key, required this.name, required this.raw});
  final String name;
  final String raw;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final args = partialJsonStrings(raw);
    final path = args['path'] as String?;
    final text = (name == 'write' ? args['content'] : name == 'edit' ? args['newText'] : name == 'bash' ? args['command'] : null) as String?;
    return Container(
      decoration: BoxDecoration(borderRadius: BorderRadius.circular(Radii.md), border: Border.all(color: p.border)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 9, 12, 9),
            child: Row(
              children: [
                Semantics(label: tr('Writing'), child: const ExcludeSemantics(child: BusySpinner(size: 12))),
                const SizedBox(width: 10),
                Icon(toolIcon(name), size: 15, color: p.accent),
                const SizedBox(width: 6),
                Text(name, style: TextStyle(fontFamily: mono, fontSize: 12.5, fontWeight: FontWeight.w600, color: p.text)),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    path ?? tr('preparing…'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontFamily: mono, fontSize: 12.5, color: p.muted),
                  ),
                ),
              ],
            ),
          ),
          if (text != null && text.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
              child: LiveTail(
                text: text,
                name: path?.split('/').last ?? name,
                language: name == 'bash' ? 'bash' : _ext(path),
              ),
            ),
        ],
      ),
    );
  }
}

/// A subagent's work as Markdown, to copy or share: the task, its steps (what it wrote, its tool calls and how they
/// went, what the person sent it) and its report. As with a chat, its thinking and the tools' output are left out.
String subagentMarkdown(SubagentState s) {
  final b = StringBuffer();
  final first = s.brief.trim().split('\n').first;
  b.writeln('# ${tr('Subagent')}: ${first.length > 80 ? '${first.substring(0, 80)}…' : first}');
  b.writeln();
  b.writeln('- ${tr('Status')}: ${tr(s.statusKey)}');
  if (s.modelName != null || s.model != null) b.writeln('- ${tr('Model')}: ${s.modelName ?? s.model}');
  if (s.elapsed case final d?) b.writeln('- ${tr('Time')}: ${formatDurationShort(d)}');
  b.writeln();
  b.writeln('## ${tr('Task from the parent')}');
  b.writeln();
  b.writeln(s.brief.trim());
  b.writeln();
  b.writeln('## ${tr('Steps')}');
  b.writeln();
  final placed = <String>{};
  void tool(SubagentToolRun t) {
    final mark = switch (t.status) {
      SubagentToolStatus.done => '✓',
      SubagentToolStatus.failed => '✗',
      SubagentToolStatus.running => '…',
    };
    final what = (t.name == 'bash' ? (t.input?['command'] as String?) : null) ?? t.args;
    b.writeln('- $mark `${t.name}` ${what.isEmpty ? '' : what.contains('\n') ? '\n\n```\n$what\n```\n' : _code(what)}'.trimRight());
  }

  for (final e in s.timeline) {
    switch (e.kind) {
      case SubagentEntryKind.thinking:
        break;
      case SubagentEntryKind.text:
        b.writeln(e.text.trim());
        b.writeln();
      case SubagentEntryKind.user:
        b.writeln('> **${tr('You')}:** ${e.text.trim().replaceAll('\n', '\n> ')}');
        b.writeln();
      case SubagentEntryKind.tool:
        final t = s.tool(e.toolId ?? '');
        if (t == null) break;
        placed.add(t.id);
        tool(t);
    }
  }
  for (final t in s.tools) {
    if (!placed.contains(t.id)) tool(t);
  }
  final report = (s.report ?? '').trim();
  if (report.isNotEmpty) {
    b.writeln();
    b.writeln('## ${tr(s.status == SubagentStatus.done ? 'Report' : 'Partial report')}');
    b.writeln();
    b.writeln(report);
  }
  return '${b.toString().trimRight()}\n';
}

String _code(String s) => s.contains('`') ? '`` $s ``' : '`$s`';
