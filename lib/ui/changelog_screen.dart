import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../agent/changelog.dart';
import 'i18n.dart';
import 'kit.dart';
import 'theme.dart';

/// Where the changelog is in the APK (pubspec.yaml assets).
const changelogAsset = 'CHANGELOG.md';

/// Opens the changelog on the version [installed] (Updater.currentVersion).
Future<void> openChangelog(BuildContext context, String installed) =>
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ChangelogScreen(installed: installed)));

/// What changed in each version, as ArchiveTune shows it: a row of versions to pick from at the top (scrolls
/// sideways, the picked one ticked), and one card for the picked version under it. Read from the copy of
/// CHANGELOG.md inside the APK, so it opens offline and never names where the app is built.
class ChangelogScreen extends StatefulWidget {
  const ChangelogScreen({super.key, required this.installed, this.load});

  /// The version of the app on this phone: the screen opens on it, and marks it.
  final String installed;

  /// Reads the changelog; the asset by default (tests give their own).
  final Future<String> Function()? load;

  @override
  State<ChangelogScreen> createState() => _ChangelogScreenState();
}

class _ChangelogScreenState extends State<ChangelogScreen> {
  List<ChangelogVersion>? _versions;
  Object? _error;

  /// The picked version, by its key; kept across rebuilds (and a rotation) by the state.
  String? _picked;
  final _row = ScrollController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _row.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final text = await (widget.load ?? () => rootBundle.loadString(changelogAsset))();
      final versions = parseChangelog(text);
      if (!mounted) return;
      setState(() {
        _versions = versions;
        if (versions.isNotEmpty) _picked ??= versions[initialIndex(versions, widget.installed)].key;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  bool _isInstalled(ChangelogVersion v) => !v.early && v.version == widget.installed;

  @override
  Widget build(BuildContext context) {
    final versions = _versions;
    final picked = versions?.where((v) => v.key == _picked).firstOrNull;
    return Scaffold(
      appBar: AppBar(title: Text(tr('Changelog'))),
      body: switch ((versions, _error)) {
        (_, final Object e) => Center(
          child: Padding(padding: const EdgeInsets.all(24), child: ErrorNotice(error: e, onRetry: _load, center: true)),
        ),
        (null, _) => const Center(child: BusySpinner.page()),
        (final List<ChangelogVersion> list, _) when list.isEmpty || picked == null => Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(tr('No versions to show yet.'), style: Theme.of(context).textTheme.bodyMedium),
          ),
        ),
        (final List<ChangelogVersion> list, _) => Column(
          children: [
            _VersionRow(
              versions: list,
              picked: picked!.key,
              installed: widget.installed,
              controller: _row,
              onPick: (v) => setState(() => _picked = v.key),
            ),
            Expanded(
              child: ListView(
                // A new list for each version: it opens at its top, not where the last one was scrolled to.
                key: PageStorageKey(picked.key),
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
                children: [_VersionCard(version: picked, installed: _isInstalled(picked))],
              ),
            ),
          ],
        ),
      },
    );
  }
}

/// The versions, newest first, in one row that scrolls sideways: joined buttons (rounded at the row's two ends), the
/// picked one filled and ticked. Each is a 48 dp target that reads as a choice of one ("selected").
class _VersionRow extends StatefulWidget {
  const _VersionRow({
    required this.versions,
    required this.picked,
    required this.installed,
    required this.controller,
    required this.onPick,
  });
  final List<ChangelogVersion> versions;
  final String picked;
  final String installed;
  final ScrollController controller;
  final ValueChanged<ChangelogVersion> onPick;

  @override
  State<_VersionRow> createState() => _VersionRowState();
}

class _VersionRowState extends State<_VersionRow> {
  final _keys = <String, GlobalKey>{};

  @override
  void initState() {
    super.initState();
    // The version it opens on may be far along the row: bring it into view.
    WidgetsBinding.instance.addPostFrameCallback((_) => _reveal(widget.picked, animate: false));
  }

  void _reveal(String key, {bool animate = true}) {
    final ctx = _keys[key]?.currentContext;
    if (ctx == null || !mounted) return;
    Scrollable.ensureVisible(
      ctx,
      alignment: 0.5,
      duration: animate ? Motion.of(context, Motion.normal) : Duration.zero,
      curve: Motion.curve,
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final list = widget.versions;
    // The early builds after a small gap, so the repeated numbers read as another series.
    final firstEarly = list.indexWhere((v) => v.early);
    return SizedBox(
      height: 64,
      child: SingleChildScrollView(
        controller: widget.controller,
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            for (var i = 0; i < list.length; i++) ...[
              if (i == firstEarly && i > 0) ...[
                const SizedBox(width: 10),
                Text(tr('Early builds'), style: Theme.of(context).textTheme.labelSmall?.copyWith(color: p.muted)),
                const SizedBox(width: 10),
              ] else if (i > 0)
                const SizedBox(width: 2),
              _VersionChip(
                key: _keys.putIfAbsent(list[i].key, GlobalKey.new),
                version: list[i],
                picked: list[i].key == widget.picked,
                installed: !list[i].early && list[i].version == widget.installed,
                // Joined into one group per series: the outer corners round, the inner ones nearly square.
                first: i == 0 || i == firstEarly,
                last: i == list.length - 1 || i + 1 == firstEarly,
                onTap: () {
                  HapticFeedback.selectionClick();
                  widget.onPick(list[i]);
                  _reveal(list[i].key);
                },
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _VersionChip extends StatelessWidget {
  const _VersionChip({
    super.key,
    required this.version,
    required this.picked,
    required this.installed,
    required this.first,
    required this.last,
    required this.onTap,
  });
  final ChangelogVersion version;
  final bool picked;
  final bool installed;
  final bool first;
  final bool last;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    const outer = Radius.circular(Radii.pill);
    const inner = Radius.circular(Radii.xs);
    // The picked one rounds all round, as ArchiveTune's pressed shape: it stands out of the joined row.
    final radius = picked
        ? BorderRadius.circular(Radii.pill)
        : BorderRadius.horizontal(left: first ? outer : inner, right: last ? outer : inner);
    final fg = picked ? p.onAccent : p.text;
    final label = 'v${version.version}';
    return Semantics(
      inMutuallyExclusiveGroup: true,
      selected: picked,
      button: true,
      label: [label, if (installed) tr('Your version'), if (version.early) tr('Early builds')].join(', '),
      excludeSemantics: true,
      child: AnimatedContainer(
        duration: Motion.of(context, Motion.fast),
        curve: Motion.curve,
        constraints: const BoxConstraints(minWidth: 88, minHeight: 48),
        decoration: BoxDecoration(color: picked ? p.accent : p.raised, borderRadius: radius),
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            borderRadius: radius,
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (picked) ...[Icon(LucideIcons.check, size: 16, color: fg), const SizedBox(width: 6)],
                  Text(
                    label,
                    maxLines: 1,
                    softWrap: false,
                    style: Theme.of(context).textTheme.labelLarge?.copyWith(color: fg),
                  ),
                  // The phone's own version, marked with a dot when it is not the one picked.
                  if (installed && !picked) ...[
                    const SizedBox(width: 6),
                    Container(
                      width: 6,
                      height: 6,
                      decoration: BoxDecoration(color: p.accent, shape: BoxShape.circle),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// One version: its number and date, "Your version" when it is the phone's, then each group under its own icon.
class _VersionCard extends StatelessWidget {
  const _VersionCard({required this.version, required this.installed});
  final ChangelogVersion version;
  final bool installed;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final text = Theme.of(context).textTheme;
    return SurfaceCard(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text('v${version.version}', style: text.titleLarge?.copyWith(color: p.accentText, fontWeight: FontWeight.w700)),
              if (installed) Pill(tr('Your version'), color: p.success, dot: true),
              if (version.early) Pill(tr('Early build'), color: p.muted),
            ],
          ),
          if (version.date.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(_date(version.date), style: text.labelMedium?.copyWith(color: p.muted)),
          ],
          const SizedBox(height: 8),
          for (final g in version.groups) _Group(group: g),
        ],
      ),
    );
  }

  /// The date as written (Indonesian), with the month in English when the app is.
  static String _date(String d) {
    if (Appearance.instance.language == 'id') return d;
    const months = {
      'Januari': 'January',
      'Februari': 'February',
      'Maret': 'March',
      'April': 'April',
      'Mei': 'May',
      'Juni': 'June',
      'Juli': 'July',
      'Agustus': 'August',
      'September': 'September',
      'Oktober': 'October',
      'November': 'November',
      'Desember': 'December',
    };
    final m = RegExp(r'^(\d+) (\w+) (\d{4})$').firstMatch(d);
    final en = m == null ? null : months[m[2]];
    return en == null ? d : '$en ${m![1]}, ${m[3]}';
  }
}

class _Group extends StatelessWidget {
  const _Group({required this.group});
  final ChangeGroup group;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final text = Theme.of(context).textTheme;
    final (icon, color, title) = switch (group.kind) {
      ChangeKind.added => (LucideIcons.sparkles, p.accent, tr('New')),
      ChangeKind.improved => (LucideIcons.trendingUp, p.success, tr('Improved')),
      ChangeKind.fixed => (LucideIcons.wrench, p.warning, tr('Fixed')),
      ChangeKind.security => (LucideIcons.shieldCheck, p.danger, tr('Security')),
      ChangeKind.other => (LucideIcons.scrollText, p.muted, group.heading),
    };
    final body = text.bodyMedium!.copyWith(color: p.text, height: 1.45);
    final style = MarkdownStyleSheet.fromTheme(Theme.of(context)).copyWith(
      p: body,
      strong: body.copyWith(fontWeight: FontWeight.w600),
      listBullet: body.copyWith(color: p.muted),
      code: text.bodySmall?.copyWith(fontFamily: 'GeistMono', backgroundColor: p.raised),
      listIndent: 18,
      blockSpacing: 6,
    );
    return Padding(
      padding: const EdgeInsets.only(top: 10, bottom: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (title.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                children: [
                  IconTile(icon: icon, color: color, size: 28),
                  const SizedBox(width: 10),
                  Expanded(child: Text(title, style: text.titleSmall)),
                ],
              ),
            ),
          for (final item in group.items)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // A dot in the group's colour, on the first line's middle (at the user's text size).
                  Padding(
                    padding: EdgeInsets.only(
                      top: (MediaQuery.textScalerOf(context).scale(body.fontSize!) * body.height! - 6) / 2,
                      right: 10,
                      left: 9,
                    ),
                    child: Container(
                      width: 6,
                      height: 6,
                      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
                    ),
                  ),
                  Expanded(child: MarkdownBody(data: item, styleSheet: style, softLineBreak: true)),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
