import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../agent/agent_controller.dart';
import '../agent/features.dart';
import 'changes_screen.dart';
import 'diff_view.dart';
import 'errors.dart';
import 'i18n.dart';
import 'illustration.dart';
import 'kit.dart';
import 'theme.dart';

/// What the agent changed, before it is committed: every changed file with its diff, a commit message the chat's
/// model writes (editable), and Commit, or Commit and push. Undoing the agent's work is one tap away (Changes), so
/// keeping and throwing away live on the same screen.
class ReviewScreen extends StatefulWidget {
  const ReviewScreen({super.key, required this.agent});
  final AgentController agent;

  @override
  State<ReviewScreen> createState() => _ReviewScreenState();
}

class _ReviewScreenState extends State<ReviewScreen> with BusyActions {
  GitReview? _review;
  Object? _error;
  final _message = TextEditingController();
  bool _writing = false;
  Object? _writeError;

  /// Files whose diff is open, and the diffs read so far.
  final _open = <String>{};
  final _patches = <String, Future<String>>{};

  /// The first few files open at once: most reviews are a handful of files, read top to bottom.
  static const _openAtStart = 3;

  Features get _features => widget.agent.features;

  @override
  void initState() {
    super.initState();
    _load(first: true);
  }

  @override
  void dispose() {
    _message.dispose();
    super.dispose();
  }

  Future<void> _load({bool first = false}) async {
    setState(() => _error = null);
    try {
      final r = await _features.gitReview();
      if (!mounted) return;
      setState(() {
        _review = r;
        _patches.clear();
        if (first) _open.addAll(r.status.files.take(_openAtStart).map((f) => f.path));
      });
      // A message is the reason to open this screen: write one straight away, unless one is typed already.
      if (first && r.status.isRepo && r.status.files.isNotEmpty && _message.text.trim().isEmpty) _write();
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _write() async {
    setState(() {
      _writing = true;
      _writeError = null;
    });
    try {
      final m = await _features.gitCommitMessage();
      if (!mounted) return;
      // Typing while it was written wins.
      if (_message.text.trim().isEmpty) _message.text = m;
    } catch (e) {
      if (mounted) setState(() => _writeError = e);
    } finally {
      if (mounted) setState(() => _writing = false);
    }
  }

  /// A file's diff: what is not staged and what is, so a file the agent already staged still shows its change.
  Future<String> _patch(GitFile f) => _patches.putIfAbsent(f.path, () async {
    final unstaged = f.unstaged || f.untracked ? await _features.gitDiff(file: f.path) : '';
    final staged = f.staged ? await _features.gitDiff(file: f.path, staged: true) : '';
    return [unstaged, staged].where((p) => p.trim().isNotEmpty).join('\n');
  });

  Future<void> _commit({required bool push}) async {
    final message = _message.text.trim();
    if (message.isEmpty) return;
    final messenger = ScaffoldMessenger.of(context);
    final nav = Navigator.of(context);
    await runBusy(push ? 'push' : 'commit', () async {
      try {
        final done = await _features.gitCommit(message, all: true);
        if (push) await _features.gitPush();
        messenger.showSnackBar(
          SnackBar(content: Text('${tr(push ? 'Committed and pushed' : 'Committed')}: $done')),
        );
        nav.pop(true);
      } catch (e) {
        messenger.showSnackBar(SnackBar(content: Text(friendlyError(e))));
        // A commit that went through before the push failed: what is left to review is less.
        await _load();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final text = Theme.of(context).textTheme;
    final r = _review;
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(tr('Review changes')),
            if (r != null && r.status.isRepo)
              Text(
                r.status.branch,
                style: TextStyle(fontFamily: mono, fontSize: 11.5, color: p.muted),
              ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: tr('Undo the agent\'s changes'),
            icon: const Icon(LucideIcons.undo2, size: 20),
            onPressed: busy()
                ? null
                : () async {
                    await Navigator.of(context).push(
                      MaterialPageRoute<void>(builder: (_) => ChangesScreen(agent: widget.agent)),
                    );
                    if (mounted) await _load();
                  },
          ),
          IconButton(
            tooltip: tr('Refresh'),
            icon: const Icon(LucideIcons.refreshCw, size: 20),
            onPressed: busy() ? null : _load,
          ),
        ],
      ),
      body: _error != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: ErrorNotice(error: _error, onRetry: _load, center: true),
              ),
            )
          : r == null
          ? const Center(child: BusySpinner.page())
          : !r.status.isRepo
          ? _empty(text, tr('Not a git repository'), tr('Set up git for this project in the Git screen to commit its changes.'))
          : r.status.files.isEmpty
          ? _empty(text, tr('Nothing to commit'), tr('Every change in this project is committed.'))
          : Column(
              children: [
                BusyBar(busy: busy()),
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 16),
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(4, 0, 4, 10),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                r.status.files.length == 1
                                    ? tr('1 file changed')
                                    : tr('{n} files changed').replaceAll('{n}', '${r.status.files.length}'),
                                style: text.titleSmall,
                              ),
                            ),
                            DiffStat(additions: r.additions, deletions: r.deletions),
                          ],
                        ),
                      ),
                      for (final f in r.status.files) ...[_file(f, r), const SizedBox(height: 8)],
                    ],
                  ),
                ),
                _composer(r),
              ],
            ),
    );
  }

  Widget _empty(TextTheme text, String title, String body) => ListView(
    padding: const EdgeInsets.fromLTRB(32, 48, 32, 32),
    children: [
      const Illustration('git', height: 150),
      const SizedBox(height: 16),
      Text(title, textAlign: TextAlign.center, style: text.titleMedium),
      const SizedBox(height: 6),
      Text(body, textAlign: TextAlign.center, style: text.bodySmall),
    ],
  );

  /// One changed file: what happened to it, its line counts, and its diff when open.
  Widget _file(GitFile f, GitReview r) {
    final p = context.palette;
    final stat = r.statOf(f.path);
    final open = _open.contains(f.path);
    final (icon, color, what) = switch (f.code.trim()) {
      '??' || 'A' || 'AM' => (LucideIcons.filePlus, p.success, tr('New')),
      'D' || 'AD' => (LucideIcons.fileMinus, p.danger, tr('Deleted')),
      final c when c.startsWith('R') => (LucideIcons.fileSymlink, p.accent, tr('Renamed')),
      _ => (LucideIcons.fileDiff, p.warning, tr('Changed')),
    };
    return Material(
      color: p.surface,
      borderRadius: BorderRadius.circular(Radii.lg),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: () => setState(() => open ? _open.remove(f.path) : _open.add(f.path)),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
              child: Row(
                children: [
                  Semantics(label: what, child: Icon(icon, size: 18, color: color)),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          f.path.substring(f.path.lastIndexOf('/') + 1),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontFamily: mono, fontSize: 13, fontWeight: FontWeight.w600, color: p.text),
                        ),
                        if (f.path.contains('/') || f.from != null)
                          Text(
                            f.from != null ? '${f.from} →' : f.path.substring(0, f.path.lastIndexOf('/')),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontFamily: mono, fontSize: 11.5, color: p.muted),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  DiffStat(additions: stat.additions, deletions: stat.deletions, binary: stat.binary),
                  Icon(open ? LucideIcons.chevronUp : LucideIcons.chevronDown, size: 18, color: p.faint),
                ],
              ),
            ),
          ),
          if (open)
            FutureBuilder<String>(
              future: _patch(f),
              builder: (context, snap) {
                if (snap.hasError) {
                  return Padding(
                    padding: const EdgeInsets.all(12),
                    child: ErrorNotice(
                      error: snap.error,
                      onRetry: () => setState(() => _patches.remove(f.path)),
                    ),
                  );
                }
                if (!snap.hasData) {
                  return const Padding(padding: EdgeInsets.all(16), child: Center(child: BusySpinner()));
                }
                return DiffView(patch: snap.data!, showHeaders: false, maxHeight: 420);
              },
            ),
        ],
      ),
    );
  }

  /// The message and the buttons, kept above the keyboard.
  Widget _composer(GitReview r) {
    final p = context.palette;
    final text = Theme.of(context).textTheme;
    final canPush = r.status.remote != null;
    return Material(
      color: p.bg,
      elevation: 0,
      child: SafeArea(
        top: false,
        child: Container(
          decoration: BoxDecoration(border: Border(top: BorderSide(color: p.border))),
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: _message,
                minLines: 2,
                maxLines: 6,
                enabled: !busy(),
                textCapitalization: TextCapitalization.sentences,
                onChanged: (_) => setState(() {}),
                style: const TextStyle(fontSize: 14),
                decoration: InputDecoration(
                  hintText: _writing ? tr('The agent is writing a message…') : tr('Commit message'),
                  suffixIcon: _writing
                      ? const Padding(
                          padding: EdgeInsets.all(14),
                          child: BusySpinner(size: 18, semanticsLabel: ''),
                        )
                      : IconButton(
                          tooltip: tr('Write it with the agent'),
                          icon: Icon(LucideIcons.sparkles, size: 18, color: p.accent),
                          onPressed: busy()
                              ? null
                              : () {
                                  _message.clear();
                                  _write();
                                },
                        ),
                ),
              ),
              if (_writeError != null)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    '${tr('No message written')}: ${friendlyError(_writeError)}',
                    style: text.bodySmall?.copyWith(color: p.danger),
                  ),
                ),
              const SizedBox(height: 10),
              LayoutBuilder(
                builder: (context, constraints) {
                  final none = busy() || _message.text.trim().isEmpty;
                  final commit = FilledButton.icon(
                    onPressed: none ? null : () => _commit(push: false),
                    style: FilledButton.styleFrom(minimumSize: const Size(0, 48)),
                    icon: busy('commit')
                        ? BusySpinner(size: 16, color: p.inverse)
                        : const Icon(LucideIcons.gitCommitHorizontal, size: 16),
                    label: Text(tr('Commit')),
                  );
                  if (!canPush) return commit;
                  final push = OutlinedButton.icon(
                    onPressed: none ? null : () => _commit(push: true),
                    style: OutlinedButton.styleFrom(minimumSize: const Size(0, 48)),
                    icon: busy('push') ? const BusySpinner(size: 16) : const Icon(LucideIcons.upload, size: 16),
                    label: Text(tr('Commit and push')),
                  );
                  // Side by side when "Commit and push" fits half the width; stacked otherwise, Commit on top.
                  final label = TextPainter(
                    text: TextSpan(text: tr('Commit and push'), style: Theme.of(context).textTheme.labelLarge),
                    textScaler: MediaQuery.textScalerOf(context),
                    maxLines: 1,
                    textDirection: Directionality.of(context),
                  )..layout();
                  final fits = label.width + 72 <= (constraints.maxWidth - 8) / 2;
                  label.dispose();
                  if (!fits) {
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [commit, const SizedBox(height: 8), push],
                    );
                  }
                  return Row(
                    children: [
                      Expanded(child: push),
                      const SizedBox(width: 8),
                      Expanded(child: commit),
                    ],
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}
