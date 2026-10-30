import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../agent/agent_controller.dart';
import '../agent/clock.dart';
import '../agent/models.dart';
import 'errors.dart';
import 'folder_picker.dart' show sessionFolder;
import 'i18n.dart';
import 'kit.dart';

/// The open chat as Markdown, to share or keep: what was asked, what the agent answered, one line per tool it used
/// (and whether it worked), and the notes in between (a background job ending, a summary of older turns). The agent's
/// thinking and the tools' output stay out: they make a transcript long without saying more.
String chatMarkdown({
  required String title,
  required List<ChatEntry> entries,
  Map<String, ToolRun> tools = const {},
  String? project,
  String? model,
  DateTime? at,
}) {
  final out = StringBuffer('# ${_oneLine(title)}\n\n');
  final when = at ?? clock();
  final meta = [
    '${when.year}-${_two(when.month)}-${_two(when.day)} ${_two(when.hour)}:${_two(when.minute)}',
    if (project != null && project.isNotEmpty) '${tr('Project')}: `$project`',
    if (model != null && model.isNotEmpty) '${tr('Model')}: $model',
  ];
  out.write('_${meta.join(' · ')}_\n');

  for (final e in entries) {
    switch (e) {
      case UserEntry():
        out.write('\n## ${tr('You')}\n\n');
        if (e.text.trim().isNotEmpty) out.write('${e.text.trim()}\n');
        final files = [for (final a in e.attachments) a.name];
        if (files.isNotEmpty) {
          out.write('\n${files.map((f) => '- 📎 `$f`').join('\n')}\n');
        } else if (e.images > 0) {
          out.write('\n- 📎 ${tr('{n} pictures').replaceAll('{n}', '${e.images}')}\n');
        }
      case AssistantEntry():
        final parts = <String>[];
        final calls = <String>[];
        void flushCalls() {
          if (calls.isEmpty) return;
          parts.add(calls.join('\n'));
          calls.clear();
        }

        for (final b in e.orderedBlocks) {
          switch (b.kind) {
            case BlockKind.text:
              if (b.text.trim().isEmpty) continue;
              flushCalls();
              parts.add(b.text.trim());
            case BlockKind.toolCall:
              final status = switch (tools[b.toolCallId]?.status) {
                ToolStatus.done => '✓',
                ToolStatus.failed => '✗',
                _ => '·',
              };
              final summary = _oneLine(toolSummary(b.toolName, b.liveArgs));
              calls.add('- $status `${b.toolName ?? 'tool'}`${summary.isEmpty ? '' : ' ${_code(summary)}'}');
            case BlockKind.thinking:
              continue;
          }
        }
        flushCalls();
        if (e.error != null) parts.add('> ⚠️ ${_oneLine(e.error!)}');
        if (e.aborted) parts.add('> ${tr('Stopped')}');
        if (parts.isEmpty) continue;
        out.write('\n## ${tr('Agent')}\n\n${parts.join('\n\n')}\n');
      case NoticeEntry():
        out.write('\n> ${e.error ? '⚠️ ' : ''}${_oneLine(e.text)}\n');
      case CompactionEntry():
        final saved = e.tokensBefore != null && e.tokensAfter != null
            ? ' (${formatTokens(e.tokensBefore!)} → ${formatTokens(e.tokensAfter!)} ${tr('tokens')})'
            : '';
        out.write('\n> ${tr('Older turns were summarized to keep the chat affordable')}$saved\n');
      case JobEntry():
        final code = e.exitCode == null ? '' : ', exit ${e.exitCode}';
        out.write('\n> ${tr('Background job')} ${_code(_oneLine(e.label))}: ${e.status}$code, ${formatDurationShort(e.took)}\n');
    }
  }
  return out.toString();
}

String _two(int n) => n.toString().padLeft(2, '0');
String _oneLine(String s) => s.trim().split('\n').first.trim();

/// Inline code that survives backticks inside it.
String _code(String s) => s.contains('`') ? '`` $s ``' : '`$s`';

/// A file name for the export: the chat's title, kept to letters, digits and dashes, and when it was made.
String chatExportName(String title, DateTime at) {
  var slug = title.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '-').replaceAll(RegExp(r'^-+|-+$'), '');
  if (slug.length > 40) slug = slug.substring(0, 40).replaceAll(RegExp(r'-+$'), '');
  final stamp = '${at.year}${_two(at.month)}${_two(at.day)}-${_two(at.hour)}${_two(at.minute)}';
  return 'griphub-${slug.isEmpty ? 'chat' : slug}-$stamp.md';
}

/// Text past this goes out as a file only: an Android share carries text in one transaction, which fails beyond about
/// a megabyte, and a messenger cuts far sooner.
const _shareTextMax = 100000;

/// Share, copy or save the open chat as Markdown.
Future<void> showChatExport(BuildContext context, AgentController agent) async {
  final at = clock();
  final markdown = chatMarkdown(
    title: agent.chatTitle,
    entries: agent.entries,
    tools: agent.tools,
    project: sessionFolder(agent.cwd, agent.info['workspace'] as String? ?? ''),
    model: agent.model?.name,
    at: at,
  );
  final name = chatExportName(agent.chatTitle, at);
  final messenger = ScaffoldMessenger.maybeOf(context);

  Future<String> file() async {
    final dir = Directory('${Directory.systemTemp.path}/griphub-export')..createSync(recursive: true);
    final f = File('${dir.path}/$name');
    await f.writeAsString(markdown);
    return f.path;
  }

  Future<void> run(BuildContext sheet, Future<String?> Function() action) async {
    Navigator.pop(sheet);
    try {
      final said = await action();
      if (said != null) messenger?.showSnackBar(SnackBar(content: Text(said)));
    } catch (e) {
      messenger?.showSnackBar(SnackBar(content: Text(friendlyError(e))));
    }
  }

  await showModalBottomSheet<void>(
    context: context,
    builder: (sheet) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(tr('Share this chat'), style: Theme.of(sheet).textTheme.titleLarge),
            const SizedBox(height: 4),
            Text(
              tr("As Markdown: messages, the agent's answers and the tools it used. Its thinking and the tools' output are left out."),
              style: Theme.of(sheet).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            SettingsGroup(
              children: [
                if (markdown.length <= _shareTextMax)
                  SettingsRow(
                    icon: LucideIcons.messageSquareShare,
                    title: tr('Share as text'),
                    subtitle: tr('To a chat app, an email or a note'),
                    onTap: () => run(sheet, () async {
                      await agent.client.shareText(markdown, subject: agent.chatTitle);
                      return null;
                    }),
                  ),
                SettingsRow(
                  icon: LucideIcons.fileText,
                  title: tr('Share as a Markdown file'),
                  subtitle: name,
                  onTap: () => run(sheet, () async {
                    await agent.client.shareFile(await file());
                    return null;
                  }),
                ),
                SettingsRow(
                  icon: LucideIcons.copy,
                  title: tr('Copy as Markdown'),
                  onTap: () => run(sheet, () async {
                    await Clipboard.setData(ClipboardData(text: markdown));
                    return tr('Chat copied');
                  }),
                ),
                SettingsRow(
                  icon: LucideIcons.download,
                  title: tr('Save to Downloads'),
                  subtitle: 'Download/GripHub',
                  onTap: () => run(sheet, () async {
                    final where = await agent.client.saveToDownloads(await file());
                    return '${tr('Saved to')} $where';
                  }),
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
}
