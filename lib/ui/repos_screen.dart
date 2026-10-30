import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:simple_icons/simple_icons.dart';

import '../agent/agent_controller.dart';
import '../agent/features.dart';
import '../agent/integrations.dart';
import 'accounts_screen.dart';
import 'errors.dart';
import 'git_screen.dart';
import 'kit.dart';
import 'task_log.dart';
import 'i18n.dart';
import 'theme.dart';

/// Pick a GitHub repository, clone it into the workspace and start a session in it.
class ReposScreen extends StatefulWidget {
  const ReposScreen({super.key, required this.agent});
  final AgentController agent;

  @override
  State<ReposScreen> createState() => _ReposScreenState();
}

class _ReposScreenState extends State<ReposScreen> {
  Integrations get it => widget.agent.integrations;
  Future<List<RepoInfo>>? repos;
  String query = '';

  @override
  void initState() {
    super.initState();
    if (it.github != null) repos = it.repos();
  }

  /// A repository on the phone offers pull and branch switching first; one that isn't is cloned and opened.
  Future<void> _tap(RepoInfo repo) async {
    final dir = repo.path;
    if (!repo.cloned || dir == null) return _open(repo);
    final open = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (_) => RepoActionsSheet(repo: repo, dir: dir, features: widget.agent.features),
    );
    if (open == true && mounted) await _open(repo);
  }

  Future<void> _open(RepoInfo repo) async {
    final path = await runWithLog<String>(
      context,
      title: repo.cloned
          ? tr('Opening {name}').replaceAll('{name}', repo.name)
          : tr('Cloning {name}').replaceAll('{name}', repo.fullName),
      task: (log, _) => it.clone(repo.fullName, onLine: log),
    );
    if (path == null || !mounted) return;
    if (!await widget.agent.newSession(dir: path)) return;
    if (mounted) Navigator.of(context).popUntil((r) => r.isFirst);
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final text = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(
        title: Text(tr('Open a repository')),
      ),
      body: it.github == null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(SimpleIcons.github, size: 32, color: p.muted),
                    const SizedBox(height: 12),
                    Text(tr('Connect GitHub to see your repositories'), style: text.titleSmall),
                    const SizedBox(height: 16),
                    FilledButton(
                      onPressed: () async {
                        await Navigator.of(context)
                            .push(MaterialPageRoute(builder: (_) => AccountsScreen(agent: widget.agent)));
                        if (mounted && it.github != null) {
                          setState(() {
                            repos = it.repos();
                          });
                        }
                      },
                      child: Text(tr('Connect GitHub')),
                    ),
                  ],
                ),
              ),
            )
          : Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                  child: TextField(
                    onChanged: (v) => setState(() => query = v.toLowerCase()),
                    decoration: InputDecoration(
                      hintText: tr('Search repositories'),
                      prefixIcon: Icon(LucideIcons.search, size: 18),
                    ),
                  ),
                ),
                Expanded(
                  child: FutureBuilder<List<RepoInfo>>(
                    future: repos,
                    builder: (context, snap) {
                      if (snap.hasError) {
                        return Center(child: Text(friendlyError(snap.error), style: text.bodySmall));
                      }
                      if (!snap.hasData) {
                        return const Center(
                          child: BusySpinner(size: 18),
                        );
                      }
                      final list = snap.data!
                          .where((r) => query.isEmpty || r.fullName.toLowerCase().contains(query))
                          .toList();
                      return RefreshIndicator(
                        onRefresh: () async {
                          final next = it.repos();
                          setState(() {
                            repos = next;
                          });
                          await next;
                        },
                        child: ListView.separated(
                          padding: const EdgeInsets.fromLTRB(8, 0, 8, 24),
                          itemCount: list.length,
                          separatorBuilder: (_, _) => Divider(height: 1, indent: 16, endIndent: 16, color: p.border),
                          itemBuilder: (context, i) => _RepoTile(repo: list[i], onTap: () => _tap(list[i])),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
    );
  }
}

class _RepoTile extends StatelessWidget {
  const _RepoTile({required this.repo, required this.onTap});
  final RepoInfo repo;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final text = Theme.of(context).textTheme;
    final meta = [
      ?repo.language,
      if (repo.stars > 0) '★ ${repo.stars}',
      if (repo.pushedAt != null) '${tr('updated')} ${formatAgo(repo.pushedAt!)}',
    ].join('  ·  ');
    return InkWell(
      borderRadius: BorderRadius.circular(Radii.md),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Icon(repo.isPrivate ? LucideIcons.lock : LucideIcons.bookMarked, size: 18, color: p.muted),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(repo.fullName, style: text.titleSmall),
                  if (repo.description != null) ...[
                    const SizedBox(height: 3),
                    Text(repo.description!, maxLines: 2, overflow: TextOverflow.ellipsis, style: text.bodySmall),
                  ],
                  if (meta.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(meta, style: text.labelSmall?.copyWith(color: p.faint)),
                  ],
                ],
              ),
            ),
            if (repo.cloned)
              Container(
                margin: const EdgeInsets.only(left: 8, top: 2),
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(Radii.pill),
                  border: Border.all(color: p.border),
                ),
                child: Text(tr('On device'), style: text.labelSmall),
              ),
          ],
        ),
      ),
    );
  }

}

/// What can be done with a repository already on the phone: open it in a chat, pull the latest changes, or
/// switch branch. Fetches on open, so "behind" and the branch list match GitHub. Pops true for "open".
class RepoActionsSheet extends StatefulWidget {
  const RepoActionsSheet({super.key, required this.repo, required this.dir, required this.features});
  final RepoInfo repo;
  final String dir;
  final Features features;

  @override
  State<RepoActionsSheet> createState() => _RepoActionsSheetState();
}

class _RepoActionsSheetState extends State<RepoActionsSheet> {
  GitStatus? _status;

  /// Fetching from the remote; the status shown is the phone's until it lands.
  bool _fetching = true;

  @override
  void initState() {
    super.initState();
    _refresh(fetch: true);
  }

  Future<void> _refresh({bool fetch = false}) async {
    try {
      if (_status == null || !fetch) {
        final local = await widget.features.gitStatus(dir: widget.dir);
        if (mounted) setState(() => _status = local);
      }
      if (fetch) {
        final fetched = await widget.features.gitFetch(dir: widget.dir);
        if (mounted) setState(() => _status = fetched);
      }
    } catch (_) {
      // Offline or no remote: the local status (if any) stays.
    } finally {
      if (mounted) setState(() => _fetching = false);
    }
  }

  Future<void> _pull() async {
    await runWithLog<void>(
      context,
      title: tr('Pulling {name}').replaceAll('{name}', widget.repo.fullName),
      task: (log, _) => widget.features.gitPull(dir: widget.dir, onLine: log),
    );
    if (mounted) await _refresh();
  }

  Future<void> _branch() async {
    final s = await showModalBottomSheet<GitStatus>(
      context: context,
      isScrollControlled: true,
      // Already fetched when this sheet opened.
      builder: (_) => BranchSheet(features: widget.features, dir: widget.dir, fetch: _status == null),
    );
    if (s != null && mounted) setState(() => _status = s);
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final text = Theme.of(context).textTheme;
    final s = _status;
    final folder = widget.dir.split('/').last;
    final pullSubtitle = s == null
        ? null
        : s.upstream == null
        ? tr('This branch has no remote to pull from')
        : s.behind > 0
        ? (s.behind == 1 ? tr('1 new commit') : tr('{n} new commits').replaceAll('{n}', '${s.behind}'))
        : _fetching
        ? tr('Checking for changes…')
        : tr('Up to date');
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(widget.repo.fullName, style: text.titleLarge),
            const SizedBox(height: 4),
            Text(
              [
                if (folder.toLowerCase() != widget.repo.name.toLowerCase()) '${tr('Folder')}: $folder',
                if (s != null && s.isRepo) s.branch,
                if (s != null && s.files.isNotEmpty) tr('uncommitted changes'),
              ].join('  ·  '),
              style: text.bodySmall?.copyWith(color: p.muted),
            ),
            const SizedBox(height: 14),
            SettingsGroup(
              children: [
                SettingsRow(
                  icon: LucideIcons.messageSquarePlus,
                  color: p.accent,
                  title: tr('Open in a new chat'),
                  onTap: () => Navigator.of(context).pop(true),
                ),
                SettingsRow(
                  icon: LucideIcons.arrowDownToLine,
                  color: p.muted,
                  title: tr('Pull latest changes'),
                  subtitle: pullSubtitle,
                  trailing: _fetching && s?.upstream != null
                      ? BusySpinner()
                      : null,
                  onTap: s?.upstream == null ? null : _pull,
                ),
                SettingsRow(
                  icon: LucideIcons.gitBranch,
                  color: p.muted,
                  title: tr('Switch branch'),
                  subtitle: s != null && s.isRepo ? s.branch : null,
                  onTap: _branch,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
