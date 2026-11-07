import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:griphub_agent/agent/changelog.dart';
import 'package:griphub_agent/ui/changelog_screen.dart';

import 'harness.dart';

const _looks = [Look(), Look(dark: true, language: 'id'), Look(language: 'id', textScale: 1.3, width: 320)];

Future<void> frames(WidgetTester tester, [int n = 8]) async {
  for (var i = 0; i < n; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// The real CHANGELOG.md, as the APK carries it.
final _real = File('CHANGELOG.md').readAsStringSync();

/// The changelog screen (lib/ui/changelog_screen.dart): ArchiveTune's layout, a row of versions and one card.
void main() {
  setUpAll(loadAppFonts);

  ChangelogScreen screen(String installed, [String? text]) =>
      ChangelogScreen(installed: installed, load: () async => text ?? _real);

  for (final look in _looks) {
    testWidgets('golden: opens on this phone\'s version ${look.name}', (tester) async {
      await pumpLook(tester, look, screen('1.0.117'), height: 900);
      await frames(tester);
      expect(layoutErrors, isEmpty);
      await expectLater(find.byType(ChangelogScreen), matchesGoldenFile(golden('changelog_${look.name}')));
    });
  }

  testWidgets('opens on the installed version, marked, and in view in the row', (tester) async {
    await pumpLook(tester, const Look(), screen('1.0.80'));
    await frames(tester);
    expect(find.text('v1.0.80'), findsNWidgets(2), reason: 'its chip and its card');
    expect(find.text('Your version'), findsOneWidget);
    expect(find.textContaining('Pekerjaan latar.'), findsWidgets, reason: "1.0.80's own changes");
    // Far along the row, yet brought into view.
    final chip = tester.getRect(find.text('v1.0.80').first);
    expect(chip.left, greaterThanOrEqualTo(0));
    expect(chip.right, lessThanOrEqualTo(390));
  });

  testWidgets('picking another version shows its card; the row reads as a choice of one', (tester) async {
    final handle = tester.ensureSemantics();
    await pumpLook(tester, const Look(), screen('1.0.119'));
    await frames(tester);
    expect(find.textContaining('Edit & kirim ulang'), findsOneWidget);
    await tester.tap(find.text('v1.0.117'));
    await frames(tester);
    expect(find.textContaining('Edit & kirim ulang'), findsNothing);
    expect(find.textContaining('Agent tidak bisa menulis di luar folder proyek'), findsOneWidget);
    expect(find.text('Security'), findsOneWidget);
    expect(find.text('Your version'), findsNothing, reason: 'not the version on this phone');
    expect(
      tester.getSemantics(find.bySemanticsLabel('v1.0.117')),
      isSemantics(isSelected: true, isButton: true, isInMutuallyExclusiveGroup: true),
    );
    expect(
      tester.getSemantics(find.bySemanticsLabel(RegExp(r'^v1\.0\.119, Your version'))),
      isSemantics(isSelected: false, isButton: true, isInMutuallyExclusiveGroup: true),
    );
    expect(tester.getSize(find.ancestor(of: find.text('v1.0.117'), matching: find.byType(AnimatedContainer)).first).height, greaterThanOrEqualTo(48));
    handle.dispose();
  });

  testWidgets('the early builds come after their label, and are told apart from the releases of the same number', (tester) async {
    await pumpLook(tester, const Look(), screen('1.0.13'));
    await frames(tester);
    expect(find.text('Early builds'), findsOneWidget);
    // 1.0.13 is both a release and an early build: the phone's is the release.
    expect(find.textContaining('batasan per request'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('v1.0.35'), 300, scrollable: find.byType(Scrollable).first);
    await tester.tap(find.text('v1.0.35'));
    await frames(tester);
    expect(find.text('Early build'), findsOneWidget);
    expect(find.textContaining('Animasi gerak di chat'), findsOneWidget);
  });

  testWidgets('the unreleased section is never shown', (tester) async {
    await pumpLook(tester, const Look(), screen('9.9.9'));
    await frames(tester);
    expect(find.textContaining('Belum dirilis'), findsNothing);
    // The newest release in the file, whichever it is today: every release adds one above the last.
    final newest = parseChangelog(_real).firstWhere((x) => !x.early).version;
    expect(find.text('v$newest'), findsNWidgets(2), reason: 'a newer build opens on the newest release');
  });

  testWidgets('entries waiting under "Belum dirilis" are not shown until they have a version', (tester) async {
    final text = _real.replaceFirst('_Belum ada perubahan._', '### Baru\n- **Hal yang belum dirilis.**');
    await pumpLook(tester, const Look(), screen('1.0.131', text));
    await frames(tester);
    expect(find.textContaining('Hal yang belum dirilis'), findsNothing);
    expect(find.textContaining('Belum dirilis'), findsNothing);
    expect(find.text('v1.0.131'), findsNWidgets(2));
  });

  testWidgets('a file that cannot be read says so and tries again', (tester) async {
    var calls = 0;
    await pumpLook(
      tester,
      const Look(),
      ChangelogScreen(
        installed: '1.0.119',
        load: () async {
          calls++;
          if (calls == 1) throw PlatformException(code: 'missing', message: 'Unable to load asset');
          return _real;
        },
      ),
    );
    await frames(tester);
    expect(find.text('Try again'), findsOneWidget);
    await tester.tap(find.text('Try again'));
    await frames(tester);
    expect(calls, 2);
    expect(find.text('v1.0.119'), findsNWidgets(2), reason: 'the version on this phone, in its chip and its card');
  });

  testWidgets('an empty changelog says there is nothing yet', (tester) async {
    await pumpLook(tester, const Look(), screen('1.0.1', '# Title\n'));
    await frames(tester);
    expect(find.text('No versions to show yet.'), findsOneWidget);
  });

  test('CHANGELOG.md is packed into the APK', () {
    expect(File('pubspec.yaml').readAsStringSync(), contains('    - CHANGELOG.md'));
    expect(changelogAsset, 'CHANGELOG.md');
  });
}
