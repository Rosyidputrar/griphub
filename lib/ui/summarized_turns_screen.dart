import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../agent/agent_controller.dart';
import '../agent/models.dart';
import 'chat_export.dart';
import 'i18n.dart';
import 'kit.dart';
import 'message_views.dart';

/// The open chat's older turns that a summary replaced, to read again: the model no longer gets them, but they were
/// the user's work, and the chat itself shows only the summary's line in their place. Read only; they can be copied as
/// Markdown, like an export.
class SummarizedTurnsScreen extends StatefulWidget {
  const SummarizedTurnsScreen({super.key, required this.agent});
  final AgentController agent;

  @override
  State<SummarizedTurnsScreen> createState() => _SummarizedTurnsScreenState();
}

class _SummarizedTurnsScreenState extends State<SummarizedTurnsScreen> {
  late Future<({List<ChatEntry> entries, Map<String, ToolRun> tools})> _turns = widget.agent.summarizedTurns();

  AgentController get agent => widget.agent;

  Future<void> _copy(List<ChatEntry> entries, Map<String, ToolRun> tools) async {
    final markdown = chatMarkdown(
      title: '${agent.chatTitle} · ${tr('Summarized turns')}',
      entries: entries,
      tools: tools,
      model: agent.model?.name,
    );
    await Clipboard.setData(ClipboardData(text: markdown));
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('Turns copied'))));
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return FutureBuilder(
      future: _turns,
      builder: (context, snap) {
        final turns = snap.data;
        return Scaffold(
          appBar: AppBar(
            title: Text(tr('Summarized turns')),
            actions: [
              if (turns != null && turns.entries.isNotEmpty)
                IconButton(
                  tooltip: tr('Copy as Markdown'),
                  icon: const Icon(LucideIcons.copy),
                  onPressed: () => _copy(turns.entries, turns.tools),
                ),
            ],
          ),
          body: switch (snap) {
            AsyncSnapshot(hasError: true) => Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: ErrorNotice(
                  error: snap.error,
                  center: true,
                  onRetry: () => setState(() => _turns = agent.summarizedTurns()),
                ),
              ),
            ),
            _ when turns == null => const Center(child: BusySpinner.page()),
            _ when turns.entries.isEmpty => Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  tr(
                    'Nothing to show: this chat has not been summarized, or its older turns are no longer in its file.',
                  ),
                  style: text.bodyMedium,
                  textAlign: TextAlign.center,
                ),
              ),
            ),
            _ => ListView.builder(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
              itemCount: turns.entries.length + 1,
              itemBuilder: (context, i) {
                if (i == 0) {
                  return Text(
                    tr(
                      'These turns were replaced by a summary to keep the chat affordable: the model no longer gets them. They are shown as they were, to read.',
                    ),
                    style: text.bodySmall,
                  );
                }
                final e = turns.entries[i - 1];
                final child = switch (e) {
                  UserEntry() => UserMessageView(e, fs: agent.fs),
                  AssistantEntry() => AssistantMessageView(
                    e,
                    tools: turns.tools,
                    cwd: agent.cwd,
                    agent: agent,
                    modelLabel: agent.modelLabel,
                  ),
                  NoticeEntry() => NoticeView(e),
                  JobEntry() => JobNoticeView(e),
                  CompactionEntry() => CompactionView(e),
                };
                return Padding(
                  padding: EdgeInsets.only(top: e is UserEntry ? 28 : 14),
                  child: child,
                );
              },
            ),
          },
        );
      },
    );
  }
}
