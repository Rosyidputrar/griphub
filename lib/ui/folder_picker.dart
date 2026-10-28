import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../agent/agent_client.dart';
import '../agent/agent_controller.dart';
import '../agent/agent_fs.dart';
import 'kit.dart';
import 'i18n.dart';
import 'theme.dart';

/// The last path segment, for showing a folder by name.
String folderName(String path) => path.split('/').where((s) => s.isNotEmpty).lastOrNull ?? path;

/// Folder name to show for a session's cwd, or null for the workspace root.
String? sessionFolder(String cwd, String workspace) {
  if (cwd.isEmpty || cwd == workspace || cwd == '$workspace/') return null;
  return folderName(cwd);
}

/// Browse the app workspace or phone storage and pick a folder to work in.
/// Pops with the chosen absolute path.
class FolderPicker extends StatefulWidget {
  const FolderPicker({super.key, required this.agent});
  final AgentController agent;

  static Future<String?> pick(BuildContext context, AgentController agent) =>
      Navigator.of(context).push<String>(MaterialPageRoute(builder: (_) => FolderPicker(agent: agent)));

  @override
  State<FolderPicker> createState() => _FolderPickerState();
}

enum _Root { workspace, phone }

class _FolderPickerState extends State<FolderPicker> with WidgetsBindingObserver {
  _Root root = _Root.workspace;
  late String workspace = widget.agent.info['workspace'] as String? ?? '/';
  String phoneRoot = '/storage/emulated/0';
  bool phoneGranted = false;

  /// False in the Play build, which has no "All files access": only the workspace is offered.
  bool phoneAvailable = true;
  late String path = workspace;
  bool showHidden = false;

  String get base => root == _Root.workspace ? workspace : phoneRoot;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _checkAccess();
    _loadChildren();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // The grant happens in system settings; re-check when the user comes back.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _checkAccess();
  }

  Future<void> _checkAccess() async {
    // A server agent has only its workspace: the phone's storage is not where it works.
    if (!widget.agent.fs.isLocal) {
      setState(() {
        phoneAvailable = false;
        root = _Root.workspace;
      });
      return;
    }
    final a = await widget.agent.client.storageAccess();
    if (!mounted) return;
    setState(() {
      phoneGranted = a.granted;
      phoneAvailable = a.available;
      if (!phoneAvailable && root == _Root.phone) {
        root = _Root.workspace;
        path = base;
      }
      phoneRoot = a.root;
    });
    _loadChildren();
  }

  void _switch(_Root r) {
    setState(() {
      root = r;
      path = base;
    });
    _loadChildren();
  }

  /// Folder listing, loaded off the UI thread: listing a large phone
  /// directory synchronously inside build() froze the UI. Stale results
  /// (path changed mid-load) are discarded.
  List<FsEntry> _dirs = [];
  Map<String, bool> _git = {};

  /// A listing on its way (on a server it can take a moment), and why the last one failed: an empty or unreachable
  /// folder must not read as "No folders here", which invites making one.
  bool _loading = true;
  String? _loadError;

  Future<void> _loadChildren() async {
    final dir = path;
    final show = showHidden;
    // Shown with the next frame (every caller rebuilds now: initState, _go, _switch, _retry).
    _loading = true;
    _loadError = null;
    try {
      // This phone's folders, or the server's (server_agent.md, phase 5).
      final entries = await widget.agent.fs.list(dir, detectGit: true);
      // Links are left out: a link to a folder elsewhere is not a project of its own.
      final dirs = entries.where((d) => d.isDir && !d.isLink && (show || !d.name.startsWith('.'))).toList()
        ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      final flags = {for (final d in dirs) d.path: d.isGit};
      if (!mounted || path != dir || showHidden != show) return;
      setState(() {
        _dirs = dirs;
        _git = flags;
        _loading = false;
      });
    } catch (e) {
      if (!mounted || path != dir) return;
      setState(() {
        _dirs = [];
        _git = {};
        _loading = false;
        _loadError = e is AgentError && e.code == 'offline' ? tr('Not connected to the server.') : tr('$e');
      });
    }
  }

  void _retry() {
    setState(() {});
    _loadChildren();
  }

  void _go(String p) {
    setState(() => path = p);
    _loadChildren();
  }

  Future<void> _newFolder() async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr('New folder')),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'my-project'),
          onSubmitted: (v) => Navigator.pop(context, v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: Text(tr('Cancel'))),
          FilledButton(onPressed: () => Navigator.pop(context, controller.text), child: Text(tr('Create'))),
        ],
      ),
    );
    // Not disposed here: the dialog is still animating out with it (the files screen's dialogs do the same).
    final clean = name?.trim().replaceAll(RegExp(r'[/\\:*?"<>|]+'), '-');
    if (clean == null || clean.isEmpty) return;
    try {
      final dir = joinPath(path, clean);
      await widget.agent.fs.mkdir(dir);
      _go(dir);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${tr('Could not create it')}: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final text = Theme.of(context).textTheme;
    final locked = root == _Root.phone && !phoneGranted;
    final crumbs = path.substring(base.length).split('/').where((s) => s.isNotEmpty).toList();
    final children = locked ? const <FsEntry>[] : _dirs;

    return Scaffold(
      appBar: AppBar(
        title: Text(tr('Choose a folder')),
        actions: [
          IconButton(
            tooltip: tr(showHidden ? 'Hide hidden folders' : 'Show hidden folders'),
            icon: Icon(showHidden ? LucideIcons.eye : LucideIcons.eyeOff, size: 18),
            onPressed: () {
              setState(() => showHidden = !showHidden);
              _loadChildren();
            },
          ),
          if (!locked)
            IconButton(
              tooltip: tr('New folder'),
              icon: const Icon(LucideIcons.folderPlus, size: 20),
              onPressed: _newFolder,
            ),
          const SizedBox(width: 4),
        ],
      ),
      body: Column(
        children: [
          if (!phoneAvailable)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text(
                widget.agent.fs.isLocal
                    ? tr(
                        'Projects live in the GripHub AI Agent workspace. To bring in files from your phone, open a project and use '
                        'Files → Import from phone.',
                      )
                    : tr(
                        'Projects live in the workspace on your server. To bring in files from your phone, open a project and '
                        'use Files → Import from phone.',
                      ),
                style: text.bodySmall,
              ),
            )
          else
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
              child: PillSegments<_Root>(
                value: root,
                options: {_Root.workspace: tr('Workspace'), _Root.phone: tr('Phone storage')},
                icons: const {_Root.workspace: LucideIcons.boxes, _Root.phone: LucideIcons.smartphone},
                onChanged: _switch,
              ),
            ),
          // Breadcrumbs: tap a segment to jump back up.
          SizedBox(
            height: 36,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              children: [
                _Crumb(
                  label: !widget.agent.fs.isLocal
                      ? 'server'
                      : root == _Root.workspace
                      ? 'workspace'
                      : 'phone',
                  icon: !widget.agent.fs.isLocal
                      ? LucideIcons.server
                      : root == _Root.workspace
                      ? LucideIcons.boxes
                      : LucideIcons.smartphone,
                  active: crumbs.isEmpty,
                  onTap: () => _go(base),
                ),
                for (var i = 0; i < crumbs.length; i++) ...[
                  Icon(LucideIcons.chevronRight, size: 14, color: p.faint),
                  _Crumb(
                    label: crumbs[i],
                    active: i == crumbs.length - 1,
                    onTap: () => _go('$base/${crumbs.take(i + 1).join('/')}'),
                  ),
                ],
              ],
            ),
          ),
          Divider(height: 16, color: p.border),
          Expanded(
            child: locked
                ? ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      SurfaceCard(
                        padding: const EdgeInsets.all(20),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            const IconTile(icon: LucideIcons.folderLock, color: Color(0xFFF59E0B), size: 44),
                            const SizedBox(height: 14),
                            Text(tr('Allow file access'), style: text.titleMedium),
                            const SizedBox(height: 6),
                            Text(
                              tr(
                                'To work in Download, Documents or any other folder on your phone, GripHub AI Agent needs '
                                '"All files access". Turn it on for GripHub AI Agent on the next screen, then come back.',
                              ),
                              style: text.bodySmall,
                            ),
                            const SizedBox(height: 16),
                            PrimaryButton(
                              label: tr('Allow access'),
                              icon: LucideIcons.shieldCheck,
                              onPressed: widget.agent.client.requestStorageAccess,
                            ),
                          ],
                        ),
                      ),
                    ],
                  )
                : _loading && children.isEmpty
                ? const Center(child: SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2)))
                : _loadError != null
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(LucideIcons.folderX, size: 32, color: p.faint),
                          const SizedBox(height: 10),
                          Text(tr("Can't open this folder"), style: text.titleSmall),
                          const SizedBox(height: 4),
                          Text(_loadError!, textAlign: TextAlign.center, style: text.bodySmall),
                          const SizedBox(height: 12),
                          OutlinedButton.icon(
                            icon: const Icon(LucideIcons.refreshCw, size: 16),
                            label: Text(tr('Try again')),
                            onPressed: _retry,
                          ),
                        ],
                      ),
                    ),
                  )
                : children.isEmpty
                ? Center(child: Text(tr('No folders here'), style: text.bodySmall))
                : ListView.builder(
                    padding: const EdgeInsets.fromLTRB(8, 0, 8, 16),
                    itemCount: children.length,
                    itemBuilder: (context, i) {
                      final d = children[i];
                      final git = _git[d.path] ?? false;
                      return ListTile(
                        contentPadding: const EdgeInsets.symmetric(horizontal: 12),
                        leading: IconTile(
                          icon: git ? LucideIcons.folderGit2 : LucideIcons.folder,
                          color: git ? p.accent : p.muted,
                          size: 34,
                        ),
                        title: Text(folderName(d.path), style: text.bodyMedium),
                        subtitle: git ? Text(tr('git repository'), style: text.bodySmall) : null,
                        trailing: Icon(LucideIcons.chevronRight, size: 16, color: p.faint),
                        onTap: () => _go(d.path),
                      );
                    },
                  ),
          ),
          if (!locked)
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: PrimaryButton(
                  label: crumbs.isEmpty
                      ? tr(root == _Root.workspace ? 'Open workspace' : 'Open phone storage')
                      : tr('Open {name}').replaceAll('{name}', crumbs.last),
                  icon: LucideIcons.folderOpen,
                  onPressed: () => Navigator.pop(context, path),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _Crumb extends StatelessWidget {
  const _Crumb({required this.label, required this.active, required this.onTap, this.icon});
  final String label;
  final bool active;
  final VoidCallback onTap;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return InkWell(
      borderRadius: BorderRadius.circular(Radii.sm),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        child: Row(
          children: [
            if (icon != null) ...[Icon(icon, size: 14, color: active ? p.accent : p.muted), const SizedBox(width: 5)],
            Text(
              label,
              style: TextStyle(
                fontFamily: mono,
                fontSize: 12.5,
                color: active ? p.text : p.muted,
                fontWeight: active ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
