import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../agent/agent_controller.dart';
import 'auto_backup.dart';
import 'code_view.dart';
import 'errors.dart';
import 'kit.dart';
import 'i18n.dart';
import 'theme.dart';
import 'transfer_dialog.dart';

/// Back up and restore chats, skills, templates, schedules and project memory as a zip.
class BackupScreen extends StatefulWidget {
  const BackupScreen({super.key, required this.agent, this.pickFile});
  final AgentController agent;

  /// Chooses a zip on the phone; tests replace the system file picker.
  final Future<String?> Function()? pickFile;

  @override
  State<BackupScreen> createState() => _BackupScreenState();
}

class _BackupScreenState extends State<BackupScreen> {
  /// Remembered for the app's lifetime so Restore defaults to it: one for this phone, one for the server, since a path
  /// on one means nothing on the other.
  static final _lastBackup = <bool, String>{};

  late final _path = TextEditingController(text: _lastBackup[_server] ?? '');
  bool _includeWorkspace = false;
  bool _backingUp = false;
  bool _restoring = false;
  ({String path, int files})? _result;

  /// A zip put on the server by "Choose file", to be removed again once it is restored.
  String? _uploaded;

  AgentController get agent => widget.agent;

  /// With the agent on a server, backups are made and restored there (server_agent.md, phase 6).
  bool get _server => !agent.fs.isLocal;

  @override
  void dispose() {
    _path.dispose();
    super.dispose();
  }

  void _snack(String msg) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _backup() async {
    setState(() => _backingUp = true);
    try {
      final r = await agent.features.backup(includeWorkspace: _includeWorkspace);
      _lastBackup[_server] = r.path;
      if (mounted) {
        setState(() {
          _result = r;
          _path.text = r.path;
        });
      }
    } catch (e) {
      _snack(friendlyError(e));
    } finally {
      if (mounted) setState(() => _backingUp = false);
    }
  }

  /// Brings the backup that was made on the server to this phone, and puts it in Downloads.
  Future<void> _download() async {
    final r = _result;
    if (r == null) return;
    final local = await runTransfer<String>(
      context,
      connection: widget.agent.client.connection,
      title: tr('Downloading the backup'),
      task: (h) => agent.fs.toPhoneFile(r.path, onProgress: h.onProgress, cancel: h.cancel),
    );
    if (local == null) return;
    try {
      _snack('${tr('Saved to')} ${await agent.client.saveToDownloads(local)}');
    } catch (e) {
      _snack(friendlyError(e));
    }
  }

  Future<void> _choose() async {
    try {
      final picked = widget.pickFile != null
          ? await widget.pickFile!()
          : (await FilePicker.pickFiles(type: FileType.custom, allowedExtensions: ['zip'])).firstOrNull?.path;
      if (picked == null || !mounted) return;
      if (!_server) {
        setState(() => _path.text = picked);
        return;
      }
      // The backup has to be where the agent is: put it on the server, restore from there.
      final name = picked.split('/').last;
      final dir = '${agent.info['workspace'] ?? ''}/backups';
      final target = '$dir/.restore-$name';
      final ok = await runTransfer<bool>(
        context,
        connection: widget.agent.client.connection,
        title: tr('Sending {name}').replaceAll('{name}', name),
        task: (h) async {
          await agent.fs.mkdir(dir);
          await agent.fs.upload(picked, target, onProgress: h.onProgress, cancel: h.cancel);
          return true;
        },
      );
      if (ok == true && mounted) {
        await _dropUploaded(keep: target);
        setState(() {
          _uploaded = target;
          _path.text = target;
        });
      }
    } catch (e) {
      _snack(friendlyError(e));
    }
  }

  /// Removes the zip "Choose file" sent to the server (unless it is [keep], the one just sent again under that name).
  Future<void> _dropUploaded({String? keep}) async {
    final u = _uploaded;
    _uploaded = null;
    if (u != null && u != keep) await agent.fs.delete(u).catchError((Object _) {});
  }

  Future<void> _restore() async {
    final path = _path.text.trim();
    if (path.isEmpty) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr('Restore backup?')),
        content: Text(
          tr(
            _server
                ? 'Chats, skills, templates, schedules and project memory on the server are overwritten with the backup\'s copies. This cannot be undone.'
                : 'Chats, skills, templates, schedules and project memory are overwritten with the backup\'s copies. '
                      'This cannot be undone.',
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(tr('Cancel'))),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: context.palette.danger),
            child: Text(tr('Restore')),
          ),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _restoring = true);
    try {
      final r = await agent.features.restoreBackup(path);
      if (path == _uploaded) await _dropUploaded();
      _snack(
        [
          tr('Restored {n} files').replaceAll('{n}', '${r.restored}'),
          if (r.skipped > 0) tr('{n} blocked entries skipped').replaceAll('{n}', '${r.skipped}'),
        ].join(' · '),
      );
    } catch (e) {
      _snack(friendlyError(e));
    } finally {
      if (mounted) setState(() => _restoring = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final text = Theme.of(context).textTheme;
    final r = _result;
    return Scaffold(
      appBar: AppBar(title: Text(tr('Backup & restore'))),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 40),
        children: [
          if (agent.remote.configured) ...[
            SectionLabel(tr('Server'), padding: const EdgeInsets.fromLTRB(4, 8, 4, 10)),
            ServerBackupCard(agent: agent),
          ],
          SectionLabel(tr('Back up'), padding: EdgeInsets.fromLTRB(4, 8, 4, 10)),
          SurfaceCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    IconTile(icon: LucideIcons.archive, color: p.accent),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        tr('Chats, skills, templates, schedules and project memory in one zip.'),
                        style: text.bodyMedium,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: _includeWorkspace,
                  onChanged: _backingUp ? null : (v) => setState(() => _includeWorkspace = v),
                  title: Text(tr('Include workspace files'), style: text.titleSmall),
                  subtitle: Text(tr('Your project folders too; the zip can get large.'), style: text.bodySmall),
                ),
                const SizedBox(height: 8),
                PrimaryButton(
                  label: tr('Create backup'),
                  icon: LucideIcons.archive,
                  busy: _backingUp,
                  onPressed: _backup,
                ),
                if (r != null) ...[
                  const SizedBox(height: 16),
                  Container(
                    padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
                    decoration: BoxDecoration(color: p.raised, borderRadius: BorderRadius.circular(Radii.md)),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                _server
                                    ? tr('Backup made on the server · {n} files').replaceAll('{n}', '${r.files}')
                                    : tr('{n} files').replaceAll('{n}', '${r.files}'),
                                style: text.labelSmall,
                              ),
                              const SizedBox(height: 2),
                              SelectableText(
                                r.path,
                                style: text.bodySmall?.copyWith(fontFamily: mono, color: p.text),
                              ),
                            ],
                          ),
                        ),
                        CopyButton(text: r.path, showLabel: false),
                      ],
                    ),
                  ),
                  // The zip is on the server; keeping a copy on the phone is the step that makes it a backup.
                  if (_server) ...[
                    const SizedBox(height: 10),
                    PrimaryButton(
                      label: tr('Download to this phone'),
                      icon: LucideIcons.smartphone,
                      onPressed: _download,
                    ),
                  ],
                ],
                const SizedBox(height: 12),
                Row(
                  children: [
                    Icon(LucideIcons.keyRound, size: 14, color: p.muted),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        tr('Provider keys, tokens and app settings are not included; set them up again after a restore.'),
                        style: text.bodySmall,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          SectionLabel(tr('Restore')),
          SurfaceCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    IconTile(icon: LucideIcons.archiveRestore, color: p.warning),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        _server
                            ? tr(
                                'Enter the path of a backup zip on the server, or choose one from your phone (it is sent to the server first).',
                              )
                            : tr('Enter the path of a backup zip, or choose one from your phone.'),
                        style: text.bodyMedium,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: _path,
                  autocorrect: false,
                  onChanged: (_) => setState(() {}),
                  style: const TextStyle(fontFamily: mono, fontSize: 13),
                  decoration: InputDecoration(labelText: tr('Backup file'), hintText: '/…/griphub-backup.zip'),
                ),
                const SizedBox(height: 10),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: _restoring ? null : _choose,
                    icon: const Icon(LucideIcons.folderOpen, size: 16),
                    label: Text(tr('Choose file')),
                  ),
                ),
                const SizedBox(height: 8),
                PrimaryButton(
                  label: tr('Restore'),
                  icon: LucideIcons.rotateCcw,
                  busy: _restoring,
                  onPressed: _path.text.trim().isEmpty ? null : _restore,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
