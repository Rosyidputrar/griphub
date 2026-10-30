import 'dart:io';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../agent/agent_controller.dart';
import '../agent/remote_mode.dart';
import '../agent/updater.dart' show formatBytes;
import 'i18n.dart';
import 'errors.dart';
import 'kit.dart';
import 'theme.dart';

String _when(DateTime t) =>
    '${formatAgo(t)} (${t.day}/${t.month} ${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')})';

/// The server's automatic backups (agent/src/autobackup.ts): on or off, when the last one was made and fetched, and,
/// on the phone's own agent, restoring one here.
class ServerBackupCard extends StatefulWidget {
  const ServerBackupCard({super.key, required this.agent});
  final AgentController agent;

  @override
  State<ServerBackupCard> createState() => _ServerBackupCardState();
}

class _ServerBackupCardState extends State<ServerBackupCard> with BusyActions {
  RemoteMode get remote => widget.agent.remote;

  /// Why the server's backup status could not be read (null when it could, or while it is being read). Without it the
  /// switch stays off with no word on why.
  Object? _loadError;

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// Reads the server's backup status; a failure is kept and shown with a way to try again.
  Future<void> _load() async {
    if (!remote.active) return;
    if (mounted) setState(() => _loadError = null);
    try {
      await remote.refreshAutoBackup();
    } catch (e) {
      if (mounted) setState(() => _loadError = e);
    }
  }

  Future<void> _guarded(Object key, Future<void> Function() task) async {
    try {
      await runBusy(key, task);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(friendlyError(e))));
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final text = Theme.of(context).textTheme;
    return ListenableBuilder(
      listenable: remote,
      builder: (context, _) {
        final status = remote.autoBackup;
        final enabled = status?['enabled'] == true;
        final onServer = (status?['backups'] as List? ?? const []).whereType<Map>().toList();
        final local = remote.localBackups();
        final lastError = status?['lastError'] as String?;
        return SurfaceCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  IconTile(icon: LucideIcons.shieldCheck, color: p.success),
                  const SizedBox(width: 12),
                  Expanded(child: Text(tr('Automatic server backup'), style: text.titleSmall)),
                  if (remote.active) ...[
                    if (busy('switch')) ...[const BusySpinner(), const SizedBox(width: 8)],
                    LabeledSwitch(
                      label: tr('Automatic server backup'),
                      value: enabled,
                      onChanged: busy() || status == null
                          ? null
                          : (v) => _guarded('switch', () => remote.setAutoBackup(v)),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 8),
              Text(
                tr(
                  'Every hour when something changed: chats, projects with their .git, skills, API keys and accounts. Dependencies such as node_modules are left out. Encrypted with a key only this phone and your server have; the newest one comes to this phone while the app is open.',
                ),
                style: text.bodySmall,
              ),
              if (remote.active && status == null && _loadError != null) ...[
                const SizedBox(height: 10),
                _Line(
                  icon: LucideIcons.triangleAlert,
                  text: '${tr('Could not read the server\'s backup status')}: ${_loadError.toString().split('\n').first}',
                  color: p.danger,
                ),
                const SizedBox(height: 6),
                Align(
                  alignment: Alignment.centerLeft,
                  child: OutlinedButton.icon(
                    onPressed: _load,
                    icon: const Icon(LucideIcons.refreshCw, size: 16),
                    label: Text(tr('Try again')),
                  ),
                ),
              ],
              if (onServer.isNotEmpty || local.isNotEmpty || lastError != null || remote.backupPullError != null) ...[
                const SizedBox(height: 10),
                if (onServer.isNotEmpty)
                  _Line(
                    icon: LucideIcons.server,
                    text:
                        '${tr('Newest on the server')}: ${_when(DateTime.fromMillisecondsSinceEpoch((onServer.first['at'] as num).toInt()))} · ${formatBytes((onServer.first['size'] as num).toInt())}',
                  ),
                if (local.isNotEmpty)
                  _Line(
                    icon: LucideIcons.smartphone,
                    text: '${tr('Newest on this phone')}: ${_when(RemoteMode.backupTime(local.first))}',
                  ),
                if (remote.pullingBackup)
                  _Line(icon: LucideIcons.download, text: tr('Fetching the newest backup…'), busy: true),
                if (lastError != null) _Line(icon: LucideIcons.triangleAlert, text: lastError, color: p.danger),
                if (remote.backupPullError != null && !remote.pullingBackup)
                  _Line(icon: LucideIcons.triangleAlert, text: remote.backupPullError!, color: p.danger),
              ],
              if (remote.active && enabled) ...[
                const SizedBox(height: 10),
                Align(
                  alignment: Alignment.centerLeft,
                  child: OutlinedButton.icon(
                    onPressed: busy() ? null : () => _guarded('now', () => remote.backupNow(force: true)),
                    icon: busy('now') ? const BusySpinner() : const Icon(LucideIcons.refreshCw, size: 16),
                    label: Text(tr('Back up now')),
                  ),
                ),
              ],
              if (!remote.active && local.isNotEmpty && remote.profile?.backupKey != null) ...[
                const SizedBox(height: 10),
                Align(
                  alignment: Alignment.centerLeft,
                  child: OutlinedButton.icon(
                    onPressed: busy() ? null : () => restoreServerBackup(context, widget.agent, local.first),
                    icon: const Icon(LucideIcons.archiveRestore, size: 16),
                    label: Text(tr('Restore on this phone')),
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}

class _Line extends StatelessWidget {
  const _Line({required this.icon, required this.text, this.color, this.busy = false});
  final IconData icon;
  final String text;
  final Color? color;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: busy ? const BusySpinner(size: 12) : Icon(icon, size: 14, color: color ?? p.muted),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(text, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: color)),
          ),
        ],
      ),
    );
  }
}

/// Asks, then puts [backup] on the agent on this phone, and says what came of it.
Future<void> restoreServerBackup(BuildContext context, AgentController agent, File backup) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(tr("Restore the server's data on this phone?")),
      content: Text(
        tr(
          "From the backup of {when}: the server's chats, projects with their .git, skills, schedules, API keys and accounts come to this phone. Files with the same name are replaced. This phone keeps its own DNS and Linux settings.",
        ).replaceAll('{when}', _when(RemoteMode.backupTime(backup))),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: Text(tr('Not now'))),
        FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(tr('Restore'))),
      ],
    ),
  );
  if (ok != true || !context.mounted) return;
  final messenger = ScaffoldMessenger.maybeOf(context);
  final r = await runWithProgress(
    context,
    tr('Restoring…'),
    () => agent.remote.restoreOnPhone(backup),
    confirm: true,
  );
  if (r == null) return;
  messenger?.showSnackBar(
    SnackBar(
      content: Text(
        [
          tr('Restored {n} files from the server.').replaceAll('{n}', '${r['restored']}'),
          if (r['keptSshKey'] == true) tr("This phone's own SSH key was kept."),
        ].join(' '),
      ),
    ),
  );
}

/// After switching back to the agent on this phone: offers the newest server backup here, once per switch.
Future<void> offerServerRestore(BuildContext context, AgentController agent) async {
  final remote = agent.remote;
  if (remote.active || remote.profile?.backupKey == null) return;
  final local = remote.localBackups();
  if (local.isEmpty || !context.mounted) return;
  await restoreServerBackup(context, agent, local.first);
}
