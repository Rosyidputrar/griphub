import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../agent/agent_controller.dart';
import '../agent/agent_fs.dart';
import 'i18n.dart';
import 'errors.dart';
import 'folder_picker.dart';
import 'kit.dart';
import 'theme.dart';

/// Where a new chat works: its own project folder (default), an existing
/// folder, or the workspace root. The sheet stays open, its choice showing a spinner, until the new chat exists.
Future<void> showNewChatSheet(BuildContext context, AgentController agent) async {
  agent.integrations.refreshProjects().catchError((_) {});
  final picked = await showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    builder: (_) => _NewChatSheet(agent: agent),
  );
  if (picked != _pick || !context.mounted) return;
  final dir = await FolderPicker.pick(context, agent);
  if (dir == null || !context.mounted) return;
  await runWithProgress(context, tr('Starting the chat…'), () => agent.newSession(dir: dir));
}

const _pick = '\u0000pick';

class _NewChatSheet extends StatefulWidget {
  const _NewChatSheet({required this.agent});
  final AgentController agent;

  @override
  State<_NewChatSheet> createState() => _NewChatSheetState();
}

class _NewChatSheetState extends State<_NewChatSheet> with BusyActions {
  late final String workspace = widget.agent.info['workspace'] as String? ?? '';
  late final name = TextEditingController(text: _suggestName());
  String? error;

  @override
  void dispose() {
    name.dispose();
    super.dispose();
  }

  String _suggestName() {
    final n = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return 'project-${two(n.month)}${two(n.day)}-${two(n.hour)}${two(n.minute)}';
  }

  Future<void> _createProject() async {
    if (busy()) return;
    final clean = name.text.trim().replaceAll(RegExp(r'[/\\:*?"<>|\s]+'), '-');
    if (clean.isEmpty) return;
    // This phone's workspace, or the server's (server_agent.md, phase 5).
    final fs = widget.agent.fs;
    final dir = joinPath(workspace, clean);
    await runBusy('project', () async {
      var made = false;
      try {
        if (await fs.exists(dir)) {
          if ((await fs.list(dir)).isNotEmpty) {
            setState(() => error = '"$clean" already exists. Pick another name, or open it as an existing folder.');
            return;
          }
        } else {
          await fs.mkdir(dir);
          made = true;
        }
        if (await _start(dir)) return;
        // No chat came of it (the user kept the running turn): leave no empty folder behind.
        if (made) await fs.delete(dir).catchError((_) {});
      } catch (e) {
        if (mounted) setState(() => error = friendlyError(e));
      }
    });
  }

  /// Starts the chat in [dir] (the workspace root when null) and closes the sheet once it exists.
  Future<bool> _start(String? dir) async {
    final started = await widget.agent.newSession(dir: dir);
    if (started && mounted) Navigator.pop(context);
    return started;
  }

  /// A row or chip: one start at a time, with the spinner on the choice that was tapped.
  Future<void> _startFrom(String key, String? dir) async {
    if (busy()) return;
    try {
      await runBusy(key, () => _start(dir));
    } catch (e) {
      if (mounted) setState(() => error = friendlyError(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final text = Theme.of(context).textTheme;
    final recent = widget.agent.integrations.projects.take(4).toList();
    // Not closed while a chat is being started: the chat would then appear behind the user's back.
    return PopScope(
      canPop: !busy(),
      child: SafeArea(
        child: Padding(
          padding: EdgeInsets.fromLTRB(20, 0, 20, 16 + MediaQuery.viewInsetsOf(context).bottom),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(tr('New chat'), style: text.titleLarge),
                const SizedBox(height: 4),
                Text(tr('Each chat can have its own folder to work in.'), style: text.bodySmall),
                const SizedBox(height: 16),
                SurfaceCard(
                  highlight: true,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          const IconTile(icon: LucideIcons.folderPlus),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(tr('New project'), style: text.titleSmall),
                                Text(tr('A fresh folder in the workspace'), style: text.bodySmall),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: name,
                        autocorrect: false,
                        style: const TextStyle(fontFamily: mono, fontSize: 14),
                        decoration: InputDecoration(
                          prefixText: 'workspace/',
                          prefixStyle: TextStyle(fontFamily: mono, fontSize: 14, color: p.faint),
                          errorText: error,
                          errorMaxLines: 3,
                        ),
                        onChanged: (_) {
                          if (error != null) setState(() => error = null);
                        },
                        enabled: !busy(),
                        onSubmitted: (_) => _createProject(),
                      ),
                      const SizedBox(height: 12),
                      PrimaryButton(
                        label: tr('Create and start'),
                        icon: LucideIcons.arrowRight,
                        busy: busy('project'),
                        onPressed: busy() ? null : _createProject,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                SettingsGroup(
                  children: [
                    SettingsRow(
                      icon: LucideIcons.folderOpen,
                      color: const Color(0xFF14B8A6),
                      title: tr('Open a folder'),
                      subtitle: tr('Continue in an existing project folder'),
                      onTap: busy() ? null : () => Navigator.pop(context, _pick),
                    ),
                    SettingsRow(
                      icon: LucideIcons.messageSquare,
                      color: p.muted,
                      title: tr('Quick chat'),
                      subtitle: tr('No project folder; works in the workspace root'),
                      trailing: busy('quick') ? const BusySpinner() : null,
                      onTap: busy() ? null : () => _startFrom('quick', null),
                    ),
                  ],
                ),
                if (recent.isNotEmpty) ...[
                  SectionLabel(tr('Recent projects'), padding: EdgeInsets.fromLTRB(4, 20, 4, 8)),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final pr in recent)
                        ActionChip(
                          avatar: busy(pr.path)
                              ? BusySpinner(size: 14, color: p.accent)
                              : Icon(pr.isGit ? LucideIcons.folderGit2 : LucideIcons.folder, size: 15, color: p.accent),
                          label: Text(pr.name, style: const TextStyle(fontFamily: mono, fontSize: 12.5)),
                          backgroundColor: p.raised,
                          side: BorderSide(color: p.border),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.pill)),
                          onPressed: busy() ? null : () => _startFrom(pr.path, pr.path),
                        ),
                    ],
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
