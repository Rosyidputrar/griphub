import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:griphub_agent/agent/changelog.dart';

/// CHANGELOG.md as the changelog screen reads it (lib/agent/changelog.dart).
void main() {
  const sample = '''
# Riwayat Perubahan GripHub

Intro, and a list that is not a version:

- **Baru**: fitur.

---

## Belum dirilis

### Baru
- Not in any APK's list yet.

---

## v1.0.119 (1 November 2026)

### Ditingkatkan
- **Edit & kirim ulang** bertanya dulu.
- Tawaran batas harian:
  - 10, 25, 50 atau 100 kredit;
  - atau tanpa batas.

  Lalu sebuah paragraf.

### Keamanan
- Satu hal.

## v1.0.105 (31 Oktober 2026)

- Rilis pemeliharaan.

## v1.0.13 (26 Oktober 2026)

### Fixed
- English heading.

---

# Build awal

Penjelasan.

## v1.0.13 (25 Oktober 2026)

### Baru
- Build pertama.
''';

  test('versions in order, groups by kind, nested lines kept with their bullet', () {
    final v = parseChangelog(sample);
    expect(v.map((x) => x.key), ['1.0.119', '1.0.105', '1.0.13', 'early-1.0.13']);
    expect(v.first.date, '1 November 2026');
    expect(v.first.groups.map((g) => g.kind), [ChangeKind.improved, ChangeKind.security]);
    expect(v.first.groups.first.items, [
      '**Edit & kirim ulang** bertanya dulu.',
      'Tawaran batas harian:\n- 10, 25, 50 atau 100 kredit;\n- atau tanpa batas.\n\nLalu sebuah paragraf.',
    ]);
    expect(v[1].groups.single.kind, ChangeKind.other, reason: 'bullets without a group');
    expect(v[1].groups.single.heading, '');
    expect(v[2].groups.single.kind, ChangeKind.fixed);
    expect(v[3].early, isTrue);
    expect(v[2].early, isFalse);
  });

  test('the unreleased section and the intro are never listed', () {
    final all = parseChangelog(sample).expand((x) => x.groups).expand((g) => g.items).join('\n');
    expect(all, isNot(contains('Not in any APK')));
    expect(all, isNot(contains('fitur.')));
  });

  test('opens on the installed version, the release before it, or the newest', () {
    final v = parseChangelog(sample);
    expect(initialIndex(v, '1.0.105'), 1);
    expect(initialIndex(v, '1.0.13'), 2, reason: 'the public release, not the early build');
    expect(initialIndex(v, '1.0.110'), 1, reason: 'a build between releases');
    expect(initialIndex(v, '1.0.120'), 0);
    expect(initialIndex(v, ''), 0);
    expect(initialIndex(const [], '1.0.1'), 0);
    expect(compareDotted('1.0.119', '1.0.99'), 1);
  });

  test('a broken file gives what it can, never throws', () {
    expect(parseChangelog(''), isEmpty);
    expect(parseChangelog('## v1.0.1\n'), isEmpty, reason: 'a version with nothing in it');
    expect(parseChangelog('## v1.0.1\n### Baru\n- a\n## vbad\n- b')[0].groups.single.items, ['a']);
  });

  test('the real CHANGELOG.md: every version has something, nothing names the repository', () {
    final text = File('CHANGELOG.md').readAsStringSync();
    final v = parseChangelog(text);
    expect(v.length, greaterThanOrEqualTo(30));
    expect(v.where((x) => x.early), isNotEmpty);
    for (final x in v) {
      expect(x.groups, isNotEmpty, reason: x.key);
      expect(x.date, isNotEmpty, reason: x.key);
    }
    expect(v.map((x) => x.key).toSet().length, v.length, reason: 'keys are unique');
    // Users read this inside the app: no repository, account, link or commit.
    expect(text, isNot(matches(RegExp(r'github\.com|seseegy|rosyid|pull request|PR #|\b[0-9a-f]{7,40}\b', caseSensitive: false))));
  });
}
