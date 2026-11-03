/// The app's changelog (CHANGELOG.md, packed into the APK as an asset), read into versions and their groups for the
/// changelog screen. It is the users' history, written by hand: one `## vX.Y.Z (date)` heading per version, then
/// `### Baru` / `### Ditingkatkan` / `### Diperbaiki` / `### Keamanan` groups of bullets. A version may have plain
/// bullets and no group ("Rilis pemeliharaan").
///
/// Headings the screen does not show: `# ...` (titles, and the start of the early builds, whose versions come
/// after it), and `## Belum dirilis`, the next release's entries, which are never in an APK's list (the release
/// renames it to its version).
library;

/// The kind of a group, by its heading; [other] for a heading the app does not know (shown as written).
enum ChangeKind { added, improved, fixed, security, other }

ChangeKind _kindOf(String heading) => switch (heading.trim().toLowerCase()) {
  'baru' || 'new' || 'added' => ChangeKind.added,
  'ditingkatkan' || 'improved' || 'changed' => ChangeKind.improved,
  'diperbaiki' || 'fixed' => ChangeKind.fixed,
  'keamanan' || 'security' => ChangeKind.security,
  _ => ChangeKind.other,
};

/// One group of a version: its heading and its bullets (Markdown, sub-bullets and paragraphs kept).
class ChangeGroup {
  const ChangeGroup(this.kind, this.heading, this.items);
  final ChangeKind kind;
  final String heading;
  final List<String> items;
}

/// One version: its number, date, whether it is one of the early builds, and its groups. [groups] has one
/// [ChangeKind.other] group with an empty heading for bullets written without one.
class ChangelogVersion {
  const ChangelogVersion({required this.version, required this.date, required this.early, required this.groups});
  final String version;
  final String date;

  /// Before the public releases, numbered on their own (so the same number can appear twice).
  final bool early;
  final List<ChangeGroup> groups;

  /// A key for the screen to remember the choice by: version numbers repeat across the two numberings.
  String get key => early ? 'early-$version' : version;
}

final _versionHeading = RegExp(r'^##\s+v?(\d+(?:\.\d+)+)\s*(?:\((.*)\))?\s*$');
final _bullet = RegExp(r'^- ');

/// Reads [markdown] into its versions, newest first, as written. Anything it cannot place is skipped, never thrown:
/// a mistake in the file must not keep the screen from opening.
List<ChangelogVersion> parseChangelog(String markdown) {
  final out = <ChangelogVersion>[];
  var early = false;
  String? version;
  var date = '';
  final groups = <ChangeGroup>[];
  ChangeKind? kind;
  var heading = '';
  final items = <String>[];
  final item = StringBuffer();

  void endItem() {
    final t = item.toString().trimRight();
    if (t.isNotEmpty) items.add(t);
    item.clear();
  }

  void endGroup() {
    endItem();
    if (items.isNotEmpty) groups.add(ChangeGroup(kind ?? ChangeKind.other, heading, List.of(items)));
    items.clear();
    kind = null;
    heading = '';
  }

  void endVersion() {
    endGroup();
    if (version != null && groups.isNotEmpty) {
      out.add(ChangelogVersion(version: version!, date: date, early: early, groups: List.of(groups)));
    }
    groups.clear();
    version = null;
  }

  for (final raw in markdown.split('\n')) {
    final line = raw.trimRight();
    if (line.startsWith('# ')) {
      endVersion();
      // The first title is the file's; any later one starts the early builds.
      if (out.isNotEmpty) early = true;
      continue;
    }
    if (line.startsWith('## ')) {
      endVersion();
      final m = _versionHeading.firstMatch(line);
      if (m != null) {
        version = m[1];
        date = (m[2] ?? '').trim();
      }
      continue;
    }
    if (version == null) continue;
    if (line.startsWith('### ')) {
      endGroup();
      heading = line.substring(4).trim();
      kind = _kindOf(heading);
      continue;
    }
    if (line == '---') continue;
    if (_bullet.hasMatch(line)) {
      endItem();
      item.write(line.substring(2));
      continue;
    }
    // A sub-bullet, a numbered step or a paragraph under a bullet belongs to it (indented two spaces, or not).
    if (item.isNotEmpty) {
      item.write('\n');
      item.write(line.startsWith('  ') ? line.substring(2) : line);
    }
  }
  endVersion();
  return out;
}

/// Compares dotted versions ("1.0.119" > "1.0.99").
int compareDotted(String a, String b) {
  final x = a.split('.').map((s) => int.tryParse(s) ?? 0).toList();
  final y = b.split('.').map((s) => int.tryParse(s) ?? 0).toList();
  for (var i = 0; i < x.length || i < y.length; i++) {
    final d = (i < x.length ? x[i] : 0) - (i < y.length ? y[i] : 0);
    if (d != 0) return d.sign;
  }
  return 0;
}

/// The version the screen opens on for an app at [installed]: that version when it is listed, else the newest that
/// is not newer than it (a build between releases), else the newest. Only public releases count: the early builds
/// share numbers with them.
int initialIndex(List<ChangelogVersion> versions, String installed) {
  if (versions.isEmpty) return 0;
  final exact = versions.indexWhere((v) => !v.early && v.version == installed);
  if (exact >= 0) return exact;
  if (installed.isNotEmpty) {
    final older = versions.indexWhere((v) => !v.early && compareDotted(v.version, installed) <= 0);
    if (older >= 0) return older;
  }
  return 0;
}
