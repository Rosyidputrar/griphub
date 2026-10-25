import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:simple_icons/simple_icons.dart';

import '../agent/agent_client.dart';
import '../agent/agent_controller.dart';
import '../agent/integrations.dart';
import 'accounts_screen.dart';
import 'i18n.dart';
import 'kit.dart';
import 'theme.dart';

/// "5 min ago" for the last sync.
String syncAgo(DateTime? t) {
  if (t == null) return tr('Never');
  final d = DateTime.now().difference(t);
  if (d.inMinutes < 1) return tr('Just now');
  if (d.inHours < 1) return '${d.inMinutes} ${tr('min ago')}';
  if (d.inDays < 1) return '${d.inHours} ${tr('h ago')}';
  return '${t.day}/${t.month} ${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
}

/// GitHub sync: chats, projects and settings in a private repository (agent/src/sync.ts).
class SyncScreen extends StatefulWidget {
  const SyncScreen({super.key, required this.agent});
  final AgentController agent;

  @override
  State<SyncScreen> createState() => _SyncScreenState();
}

class _SyncScreenState extends State<SyncScreen> {
  Integrations get it => widget.agent.integrations;

  @override
  void initState() {
    super.initState();
    it.refresh().catchError((_) {});
    it.refreshSync().catchError((_) {});
  }

  Future<void> _toggle(bool on) async {
    if (on) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(tr('Sync to GitHub?')),
          content: Text(
            [
              tr(
                'GripHub AI Agent creates a private repository griphub-sync in your GitHub account and keeps your chats, projects and settings there.',
              ),
              tr(
                'Provider keys and tokens are never uploaded. Chats can still contain anything you pasted into them, so keep the repository private.',
              ),
            ].join('\n\n'),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: Text(tr('Cancel'))),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(tr('Turn on'))),
          ],
        ),
      );
      if (ok != true) return;
    }
    try {
      await it.setSync(on);
    } on AgentError catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr(e.message))));
    }
  }

  Future<void> _syncNow() async {
    await it.syncNow();
    await it.refreshSync().catchError((_) {});
    final pending = it.sync?.pendingDelete ?? const [];
    if (pending.isNotEmpty && mounted) await _confirmDelete(pending);
  }

  /// Local chats another phone deleted are only removed here after this
  /// confirmation: automatic syncs leave them alone and report them here.
  Future<void> _confirmDelete(List<String> pending) async {
    final p = context.palette;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr('Delete local chats?')),
        content: Text(
          [
            '${pending.length} ${tr('chats')}',
            tr(
              'These chats were deleted on another phone. Delete them here too, or keep them (they will no longer sync).',
            ),
          ].join('\n\n'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(tr('Keep them'))),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(tr('Delete'), style: TextStyle(color: p.danger)),
          ),
        ],
      ),
    );
    if (ok == true) {
      await it.syncNow(confirmDelete: true);
      await it.refreshSync().catchError((_) {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final text = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: Text(tr('GitHub sync'))),
      body: ListenableBuilder(
        listenable: it,
        builder: (context, _) {
          final s = it.sync;
          final signedIn = it.github != null;
          final imported = s?.imported ?? const {};
          final news = [
            if ((imported['chats'] ?? 0) > 0) '${imported['chats']} ${tr('chats')}',
            if ((imported['projects'] ?? 0) > 0) '${imported['projects']} ${tr('projects')}',
            if ((imported['config'] ?? 0) > 0) '${imported['config']} ${tr('settings')}',
            if ((imported['removed'] ?? 0) > 0) '${imported['removed']} ${tr('chats removed')}',
          ];
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
            children: [
              Text(
                tr(
                  'Keep chats and projects in a private GitHub repository, and pick them up on another phone by signing in there.',
                ),
                style: text.bodyMedium?.copyWith(color: p.muted),
              ),
              const SizedBox(height: 16),
              if (!signedIn)
                SettingsGroup(
                  children: [
                    SettingsRow(
                      icon: SimpleIcons.github,
                      color: p.text,
                      title: tr('Connect GitHub'),
                      subtitle: tr('Sign in to GitHub first'),
                      onTap: () async {
                        await Navigator.of(context)
                            .push(MaterialPageRoute(builder: (_) => AccountsScreen(agent: widget.agent)));
                        it.refresh().catchError((_) {});
                      },
                    ),
                  ],
                )
              else ...[
                SettingsGroup(
                  children: [
                    SettingsRow(
                      icon: LucideIcons.refreshCw,
                      color: const Color(0xFF16A34A),
                      title: tr('Sync to GitHub'),
                      subtitle: '${tr('Signed in as')} ${it.github!.login}',
                      trailing: Switch(value: s?.enabled ?? false, onChanged: s == null ? null : _toggle),
                    ),
                    if (s?.enabled ?? false) ...[
                      // The action is the row; when it last ran is its subtitle (a "Sync now" button
                      // beside the time squeezed "Last synced: 5 min ago" onto two broken lines).
                      SettingsRow(
                        icon: LucideIcons.refreshCw,
                        color: p.muted,
                        title: s!.running ? tr('Syncing…') : tr('Sync now'),
                        subtitle: [
                          '${tr('Last synced')}: ${syncAgo(s.lastSync)}',
                          if (news.isNotEmpty) '${tr('Brought in')}: ${news.join(', ')}',
                        ].join(' · '),
                        onTap: s.running ? null : _syncNow,
                        trailing: s.running
                            ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
                            : null,
                      ),
                      if (s.repo != null)
                        SettingsRow(
                          icon: LucideIcons.lock,
                          color: p.muted,
                          title: s.repo!,
                          subtitle: tr('Private repository'),
                          onTap: () => widget.agent.client.openUrl('https://github.com/${s.repo}'),
                        ),
                    ],
                  ],
                ),
                if (s?.lastError != null) ...[
                  const SizedBox(height: 12),
                  Text(tr(s!.lastError!), style: text.bodySmall?.copyWith(color: p.danger)),
                ],
                if (s != null && s.skipped.isNotEmpty) ...[
                  SectionLabel(tr('Too big for GitHub (not synced)')),
                  for (final f in s.skipped)
                    Text(
                      f,
                      style: TextStyle(fontFamily: mono, fontSize: 12, color: p.muted),
                    ),
                ],
                if (s != null && s.localOnly.isNotEmpty) ...[
                  SectionLabel(tr('Only on this phone')),
                  Text(
                    tr('Deleted on another phone, so no longer synced. They stay here until you delete them.'),
                    style: text.bodySmall?.copyWith(color: p.muted),
                  ),
                  const SizedBox(height: 6),
                  for (final n in s.localOnly)
                    Text(
                      n,
                      style: TextStyle(fontFamily: mono, fontSize: 12, color: p.text),
                    ),
                ],
                if (s != null && s.pendingDelete.isNotEmpty) ...[
                  SectionLabel(tr('Chats deleted elsewhere')),
                  Text(
                    tr(
                      'These chats were deleted on another phone. Delete them here too, or keep them (they will no longer sync).',
                    ),
                    style: text.bodySmall?.copyWith(color: p.muted),
                  ),
                  const SizedBox(height: 6),
                  TextButton(
                    onPressed: () => _confirmDelete(s.pendingDelete),
                    child: Text(tr('Review')),
                  ),
                ],
              ],
              SectionLabel(tr('What is synced')),
              Text(
                [
                  '•  ${tr('Chats, including ones deleted or continued on another phone')}',
                  '•  ${tr('Projects: git projects as their remote and branch (cloned on the other phone), other projects as files, without dependency and build folders')}',
                  '•  ${tr('Uncommitted changes in git projects stay on this phone; commit and push them to carry them over')}',
                  '•  ${tr('Prompt templates, skills, agent instructions and custom providers (without keys)')}',
                  '•  ${tr('Syncs a moment after the agent finishes, when you leave the app, and when it starts')}',
                ].join('\n'),
                style: text.bodySmall?.copyWith(color: p.muted, height: 1.6),
              ),
            ],
          );
        },
      ),
    );
  }
}
