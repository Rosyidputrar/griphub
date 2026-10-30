// Files: sort a folder by name, the most recently edited, the largest or type (folders first or not), and show one
// kind of file at a time; only kinds the folder has get a chip.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:griphub_agent/agent/agent_fs.dart';
import 'package:griphub_agent/ui/files_screen.dart';

import 'harness.dart';

const _looks = [Look(), Look(dark: true, language: 'id'), Look(language: 'id', textScale: 1.3, width: 320)];

FsEntry _e(String name, {bool dir = false, int size = 0, int minutesAgo = 0}) => FsEntry(
  path: '/w/$name',
  type: dir ? FsType.dir : FsType.file,
  size: size,
  modified: goldenNow.subtract(Duration(minutes: minutesAgo)),
);

/// A project with a bit of everything, its files of known sizes and edited at known times, without touching the disk.
class _Fs extends LocalFs {
  @override
  Future<List<FsEntry>> list(String path, {bool detectGit = false}) async {
    FsEntry e(String name, {bool dir = false, int size = 0, int minutesAgo = 0}) => FsEntry(
      path: '$path/$name',
      type: dir ? FsType.dir : FsType.file,
      size: size,
      modified: goldenNow.subtract(Duration(minutes: minutesAgo)),
    );
    if (path != '/w/shop') return const [];
    return [
      e('lib', dir: true, minutesAgo: 5),
      e('assets', dir: true, minutesAgo: 60 * 24),
      e('main.dart', size: 2400, minutesAgo: 3),
      e('README.md', size: 900, minutesAgo: 600),
      e('logo.png', size: 48000, minutesAgo: 60 * 24 * 3),
      e('data.csv', size: 12000, minutesAgo: 30),
      e('app.zip', size: 250000, minutesAgo: 60 * 24 * 10),
      e('notes.txt', size: 50, minutesAgo: 1),
    ];
  }
}

Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump(const Duration(milliseconds: 50));
  }
}

List<String> _names(WidgetTester tester, List<String> among) {
  final found = <(double, String)>[];
  for (final n in among) {
    final f = find.text(n);
    if (f.evaluate().isNotEmpty) found.add((tester.getTopLeft(f.first).dy, n));
  }
  found.sort((a, b) => a.$1.compareTo(b.$1));
  return [for (final (_, n) in found) n];
}

void main() {
  setUpAll(loadAppFonts);
  setUp(() {
    applyLook(const Look());
    layoutErrors.clear();
  });

  group('the order', () {
    final entries = [
      _e('b.txt', size: 10, minutesAgo: 5),
      _e('src', dir: true, minutesAgo: 1),
      _e('A.png', size: 500, minutesAgo: 60),
      _e('c.dart', size: 200, minutesAgo: 0),
      _e('docs', dir: true, minutesAgo: 90),
    ];
    List<String> names(FileSort s, {bool foldersFirst = true}) =>
        [for (final e in sortEntries(entries, s, foldersFirst: foldersFirst)) e.name];

    test('by name, folders first, case aside', () {
      expect(names(FileSort.name), ['docs', 'src', 'A.png', 'b.txt', 'c.dart']);
    });
    test('most recently edited first', () {
      expect(names(FileSort.recent), ['src', 'docs', 'c.dart', 'b.txt', 'A.png']);
      expect(names(FileSort.recent, foldersFirst: false), ['c.dart', 'src', 'b.txt', 'A.png', 'docs']);
    });
    test('largest first; a folder\'s own size means nothing, so folders go after files when mixed', () {
      expect(names(FileSort.largest), ['docs', 'src', 'A.png', 'c.dart', 'b.txt']);
      expect(names(FileSort.largest, foldersFirst: false), ['A.png', 'c.dart', 'b.txt', 'docs', 'src']);
    });
    test('by type (extension), then name', () {
      expect(names(FileSort.type), ['docs', 'src', 'c.dart', 'A.png', 'b.txt']);
    });
    test('kinds', () {
      expect([for (final e in entries) fileKind(e)], [FileKind.document, FileKind.folder, FileKind.image, FileKind.code, FileKind.folder]);
      expect(fileKind(_e('x.csv')), FileKind.data);
      expect(fileKind(_e('x.zip')), FileKind.archive);
      expect(fileKind(_e('x.mp4')), FileKind.media);
      expect(fileKind(_e('x.bin')), FileKind.other);
      expect(fileKind(_e('pubspec.yaml')), FileKind.code, reason: 'config counts as code');
    });
  });

  for (final look in _looks) {
    testWidgets('golden: the sort button and the kinds this folder has ${look.name}', (tester) async {
      FakeHost();
      await pumpLook(tester, look, FilesScreen(agent: newAgent()..fs = _Fs(), root: '/w/shop'));
      await settle(tester);
      expect(layoutErrors, isEmpty);
      await expectLater(find.byType(Scaffold), matchesGoldenFile(golden('files_sort_${look.name}')));
    });
  }

  testWidgets('choosing an order and a kind changes the list; a new folder shows every kind again', (tester) async {
    FakeHost();
    await pumpLook(tester, const Look(), FilesScreen(agent: newAgent()..fs = _Fs(), root: '/w/shop'), height: 1000);
    await settle(tester);
    const files = ['main.dart', 'README.md', 'logo.png', 'data.csv', 'app.zip', 'notes.txt'];
    expect(_names(tester, files), ['app.zip', 'data.csv', 'logo.png', 'main.dart', 'notes.txt', 'README.md']);

    await tester.tap(find.byTooltip('Sort by'));
    await settle(tester);
    await tester.tap(find.text('Recently edited').last);
    await settle(tester);
    expect(_names(tester, files), ['notes.txt', 'main.dart', 'data.csv', 'README.md', 'logo.png', 'app.zip']);

    await tester.tap(find.byTooltip('Sort by'));
    await settle(tester);
    await tester.tap(find.text('Largest').last);
    await settle(tester);
    expect(_names(tester, files), ['app.zip', 'logo.png', 'data.csv', 'main.dart', 'README.md', 'notes.txt']);

    await tester.tap(find.widgetWithText(ChoiceChip, 'Images'));
    await settle(tester);
    expect(_names(tester, files), ['logo.png']);
    expect(find.text('lib'), findsNothing, reason: 'folders are a kind too');
    expect(find.widgetWithText(ChoiceChip, 'Media'), findsNothing, reason: 'no chip for a kind the folder hasn\'t got');

    await tester.tap(find.widgetWithText(ChoiceChip, 'All'));
    await settle(tester);
    expect(_names(tester, files), hasLength(6), reason: 'All shows everything again');

    // Into a folder: the order stays, the kind filter doesn't carry over.
    await tester.tap(find.widgetWithText(ChoiceChip, 'Code'));
    await settle(tester);
    await tester.tap(find.widgetWithText(ChoiceChip, 'All'));
    await settle(tester);
    await tester.tap(find.text('lib'));
    await settle(tester);
    expect(find.text('This folder is empty'), findsOneWidget);
  });
}
