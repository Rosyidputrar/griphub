// tool/release_notes.py, run by the release workflow: the changelog's "Belum dirilis" section is named after the
// version that goes out, a new empty one is opened above it, and the release notes are emptied once published.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:griphub_agent/agent/changelog.dart';

const _changelog = '''# Riwayat Perubahan GripHub

Intro.

---

## Belum dirilis

### Baru
- **Satu hal baru.**
  - Rinciannya.

### Diperbaiki
- Satu perbaikan.

---

## v1.0.119 (1 November 2026)

### Baru
- Yang lama.
''';

const _notes = '''<!-- Catatan rilis: komentar. -->

## Bahasa Indonesia

- Satu.

## English

- One.
''';

ProcessResult _run(List<String> args) => Process.runSync('python3', ['tool/release_notes.py', ...args]);

void main() {
  final python = Process.runSync('python3', ['--version']).exitCode == 0;
  late Directory dir;
  late File cl;
  late File rn;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('relnotes');
    cl = File('${dir.path}/CHANGELOG.md')..writeAsStringSync(_changelog);
    rn = File('${dir.path}/RELEASE_NOTES.md')..writeAsStringSync(_notes);
  });
  tearDown(() => dir.deleteSync(recursive: true));

  List<String> files() => ['--changelog', cl.path, '--notes', rn.path];

  test('stamp names the section after the version, with a long date, and opens a new empty one', () {
    final r = _run(['stamp', '--version', '1.0.130', '--date', '2026-11-03', ...files()]);
    expect(r.exitCode, 0, reason: '${r.stderr}');
    expect(r.stdout, contains('versioned'));
    final text = cl.readAsStringSync();
    expect(text, contains('## v1.0.130 (3 November 2026)\n\n### Baru\n- **Satu hal baru.**'));
    expect(RegExp('^## Belum dirilis', multiLine: true).allMatches(text), hasLength(1));
    expect(text.indexOf('## Belum dirilis'), lessThan(text.indexOf('## v1.0.130')));
    expect(text, contains('## Belum dirilis\n\n_Belum ada perubahan._\n\n---\n\n## v1.0.130'));
    // The screen reads it: the new version first (its entries), the empty section never listed.
    final v = parseChangelog(text);
    expect(v.map((x) => x.version), ['1.0.130', '1.0.119']);
    expect(v.first.date, '3 November 2026');
    expect(v.first.groups.map((g) => g.kind), [ChangeKind.added, ChangeKind.fixed]);
  }, skip: !python);

  test('an empty section is left as it is, and a version that is already there is refused', () {
    expect(_run(['stamp', '--version', '1.0.130', '--date', '2026-11-03', ...files()]).exitCode, 0);
    final once = cl.readAsStringSync();
    final again = _run(['stamp', '--version', '1.0.131', '--date', '2026-11-04', ...files()]);
    expect(again.exitCode, 0);
    expect(again.stdout, contains('nothing to version'));
    expect(cl.readAsStringSync(), once, reason: 'nothing to tell: no heading for a release of tests');
    cl.writeAsStringSync(_changelog.replaceFirst('## v1.0.119', '## v1.0.130'));
    expect(_run(['stamp', '--version', '1.0.130', '--date', '2026-11-03', ...files()]).exitCode, isNot(0));
  }, skip: !python);

  test('a file that is not as expected is not touched, and says why', () {
    cl.writeAsStringSync(_changelog.replaceFirst('## v1.0.119', '## Belum dirilis\n\n- x\n\n## v1.0.119'));
    final before = cl.readAsStringSync();
    final r = _run(['stamp', '--version', '1.0.130', '--date', '2026-11-03', ...files()]);
    expect(r.exitCode, isNot(0));
    expect('${r.stderr}', contains('exactly one'));
    expect(cl.readAsStringSync(), before);
    for (final bad in [['--version', 'x1', '--date', '2026-11-03'], ['--version', '1.0.1', '--date', '03-11-2026'], ['--version', '1.0.1', '--date', '2026-13-03']]) {
      expect(_run(['stamp', ...bad, ...files()]).exitCode, isNot(0), reason: '$bad');
    }
  }, skip: !python);

  test('the release notes: has-notes while there are entries; reset keeps the comment and empties the rest', () {
    expect(_run(['has-notes', ...files()]).exitCode, 0);
    expect(_run(['reset', ...files()]).exitCode, 0);
    expect(rn.readAsStringSync(), '<!-- Catatan rilis: komentar. -->\n\n## Bahasa Indonesia\n\n\n## English\n\n');
    expect(_run(['has-notes', ...files()]).exitCode, 1, reason: 'then the release gets its one-line body');
    rn.writeAsStringSync('no comment\n- x\n');
    expect(_run(['reset', ...files()]).exitCode, isNot(0), reason: 'a file it does not know is left alone');
    expect(rn.readAsStringSync(), 'no comment\n- x\n');
  }, skip: !python);

  test('the real files are what the script expects', () {
    final text = File('CHANGELOG.md').readAsStringSync();
    expect(RegExp('^## Belum dirilis\\s*\$', multiLine: true).allMatches(text), hasLength(1));
    expect(File('RELEASE_NOTES.md').readAsStringSync(), startsWith('<!--'));
    final wf = File('.github/workflows/release.yml').readAsStringSync();
    expect(wf, contains('tool/release_notes.py stamp'));
    expect(wf, contains('tool/release_notes.py reset'));
    expect(wf, contains('finalize:'));
    // Only the finalizing job may write; the build job (which holds the signing key) keeps read-only access.
    expect(RegExp('permissions:\\s*\\n\\s*contents: write').allMatches(wf), hasLength(1));
  });
}
