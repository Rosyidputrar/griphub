// Layouts that broke on ordinary phones (UI audit): each case is pumped at the sizes that broke it, and fails on any
// overflow instead of only recording it. Goldens show the fixed layout.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:griphub_agent/agent/agent_controller.dart';
import 'package:griphub_agent/agent/models.dart';
import 'package:griphub_agent/ui/chat_screen.dart';
import 'package:griphub_agent/ui/code_view.dart';
import 'package:griphub_agent/ui/griphub_screen.dart';
import 'package:griphub_agent/ui/kit.dart';
import 'package:griphub_agent/ui/onboarding.dart';
import 'package:griphub_agent/ui/settings_hub.dart';
import 'package:griphub_agent/ui/theme.dart';

import 'harness.dart';

/// Fails the test when the layout overflowed while it was pumped.
void expectNoOverflow(String where) {
  expect(layoutErrors, isEmpty, reason: '$where overflowed: ${layoutErrors.join('\n')}');
}

AgentController agentWithModel() => newAgent()
  ..model = ModelInfo({'provider': 'griphub', 'id': 'mock', 'name': 'Mock'});

void main() {
  setUpAll(loadAppFonts);
  setUp(() {
    applyLook(const Look());
    layoutErrors.clear();
  });

  group('UI-02: sheets', sheetTests);
  group('UI-03: first run', firstRunTests);
  group('UI-06: accent colour', accentTests);
  group('UI-07: copy button', copyButtonTests);
  group('the golden harness', harnessTests);

  group('UI-01: the suggestions on an empty chat', () {
    const looks = [
      Look(width: 360),
      Look(width: 320),
      Look(width: 360, textScale: 1.3),
      Look(width: 411, textScale: 1.3),
      Look(width: 320, textScale: 2.0),
      Look(language: 'id', width: 320, textScale: 1.3),
      Look(dark: true, language: 'id', width: 360),
    ];
    for (final look in looks) {
      testWidgets('no overflow ${look.name}', (tester) async {
        FakeHost();
        await pumpLook(tester, look, ChatScreen(agent: agentWithModel()), height: 1400);
        await tester.pump(const Duration(milliseconds: 100));
        collectLayoutErrors(tester, look.name);
        expect(find.text('A site or app, ready to deploy'), look.language == 'en' ? findsOneWidget : findsNothing);
        expectNoOverflow('the suggestion grid');
      });
    }
    for (final look in const [Look(width: 360), Look(language: 'id', width: 320, textScale: 1.3)]) {
      testWidgets('golden ${look.name}', (tester) async {
        FakeHost();
        await pumpLook(tester, look, ChatScreen(agent: agentWithModel()));
        await tester.pump(const Duration(milliseconds: 100));
        await loadImages(tester);
        await expectLater(find.byType(ChatScreen), matchesGoldenFile(golden('empty_chat_suggestions_${look.name}')));
      });
    }
  });
}

/// The chat menu's rows (Rename, Select, Delete) in a sheet, as home_shell.dart builds them.
Widget _menuRows(BuildContext context) => SafeArea(
  child: Padding(
    padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
    child: SettingsGroup(
      children: [
        SettingsRow(icon: Icons.edit, color: Colors.blue, title: 'Rename', onTap: () => Navigator.pop(context, 'rename')),
        SettingsRow(icon: Icons.check_box, color: Colors.grey, title: 'Select', subtitle: 'Pick several chats to delete at once', onTap: () => Navigator.pop(context, 'select')),
        SettingsRow(icon: Icons.delete, color: Colors.red, title: 'Delete', destructive: true, onTap: () => Navigator.pop(context, 'delete')),
      ],
    ),
  ),
);

void sheetTests() {
  // 780 x 340: a phone on its side. A plain sheet stops at 9/16 of that (about 190 dp) and cut Delete off.
  Future<String?> openSheet(WidgetTester tester, {required bool app, double textScale = 1}) async {
    String? picked;
    await pumpLook(
      tester,
      Look(width: 780, textScale: textScale),
      Builder(
        builder: (c) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () async => picked = app
                  ? await showAppSheet<String>(context: c, builder: _menuRows)
                  : await showModalBottomSheet<String>(context: c, builder: _menuRows),
              child: const Text('open'),
            ),
          ),
        ),
      ),
      height: 340,
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    collectLayoutErrors(tester, 'sheet');
    await tester.scrollUntilVisible(find.text('Delete'), 40, scrollable: find.byType(Scrollable).last);
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    return picked;
  }

  testWidgets('UI-02: in landscape every row of a menu sheet can be reached, Delete included', (tester) async {
    expect(await openSheet(tester, app: true), 'delete');
    expectNoOverflow('the menu sheet');
  });

  testWidgets('UI-02: with large text too', (tester) async {
    expect(await openSheet(tester, app: true, textScale: 1.3), 'delete');
    expectNoOverflow('the menu sheet');
  });
}

void firstRunTests() {
  const looks = [
    Look(width: 320, textScale: 2.0),
    Look(width: 780),
    Look(language: 'id', width: 780, textScale: 1.3),
    Look(width: 360, textScale: 1.3),
  ];
  for (final look in looks) {
    testWidgets('UI-03: onboarding fits ${look.name}', (tester) async {
      FakeHost();
      await pumpLook(tester, look, OnboardingScreen(agent: newAgent()), height: look.width >= 780 ? 340 : 844);
      await tester.pump(const Duration(milliseconds: 100));
      collectLayoutErrors(tester, look.name);
      expectNoOverflow('onboarding');
      // Skip has a 48 dp touch box, and the dots say which page this is.
      final skip = tester.getSize(find.ancestor(of: find.text(look.language == 'id' ? 'Lewati' : 'Skip'), matching: find.byType(TapTarget)));
      expect(skip.width >= 48 && skip.height >= 48, isTrue, reason: 'Skip is $skip');
      expect(find.bySemanticsLabel(look.language == 'id' ? 'Halaman 1 dari 3' : 'Page 1 of 3'), findsOneWidget);
    });
  }

  for (final look in const [Look(language: 'id', width: 320, textScale: 1.3), Look(width: 320, textScale: 2.0)]) {
    testWidgets('UI-03: the API key screen fits ${look.name}', (tester) async {
      final host = FakeHost();
      host.answers['custom_providers'] = (_) => <Object>[];
      await pumpLook(tester, look, GripHubScreen(agent: newAgent()), height: 1400);
      await tester.pump(const Duration(milliseconds: 200));
      collectLayoutErrors(tester, look.name);
      expectNoOverflow('the API key screen');
    });
  }
}

void accentTests() {
  testWidgets('UI-06: each accent swatch says its colour and whether it is chosen, is 48 dp, and the title has room', (tester) async {
    final handle = tester.ensureSemantics();
    FakeHost();
    await pumpLook(tester, const Look(language: 'id', width: 320, textScale: 1.3), SettingsHub(agent: newAgent()), height: 2400);
    await tester.pump(const Duration(milliseconds: 200));
    collectLayoutErrors(tester, 'accent');
    expectNoOverflow('the accent row');
    await tester.scrollUntilVisible(find.text('Warna aksen'), 300, scrollable: find.byType(Scrollable).first);
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -200));
    await tester.pump();
    // The title on one line, not "War / na / aks / en".
    final title = tester.getSize(find.text('Warna aksen'));
    expect(title.width, greaterThan(80));
    for (final name in ['Ungu', 'Biru', 'Hijau', 'Oranye', 'Merah muda', 'Hijau toska']) {
      expect(find.bySemanticsLabel(name), findsOneWidget, reason: name);
    }
    expect(tester.getSemantics(find.bySemanticsLabel('Ungu')), isSemantics(isSelected: true, isButton: true), reason: 'the chosen one says so');
    expect(tester.getSemantics(find.bySemanticsLabel('Hijau')), isSemantics(isSelected: false, isButton: true));
    final target = tester.getSize(find.descendant(of: find.bySemanticsLabel('Hijau'), matching: find.byType(TapTarget)).first);
    expect(target.width >= 48 && target.height >= 48, isTrue, reason: 'swatch target is $target');
    await tester.tap(find.bySemanticsLabel('Hijau'));
    await tester.pump();
    expect(Appearance.instance.accent, 2);
    Appearance.instance.update(accent: 0);
    handle.dispose();
  });
}

void copyButtonTests() {
  testWidgets('UI-07: the reply footer copy button says what it does, is 48 dp, and says when it has copied', (tester) async {
    final handle = tester.ensureSemantics();
    FakeHost();
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String?;
      return null;
    });
    await pumpLook(tester, const Look(), const Scaffold(body: Center(child: CopyButton(text: 'jawaban', showLabel: false))));
    final node = find.bySemanticsLabel('Copy');
    expect(node, findsOneWidget);
    expect(tester.getSemantics(node), isSemantics(isButton: true, hasTapAction: true));
    expect(find.byTooltip('Copy'), findsOneWidget);
    final size = tester.getSize(find.byType(CopyButton));
    expect(size.width >= 48 && size.height >= 48, isTrue, reason: 'it is $size');
    // A screen reader's double tap copies, and the button then says so (a live region).
    tester.semantics.tap(find.semantics.byLabel('Copy'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(copied, 'jawaban');
    expect(tester.getSemantics(find.bySemanticsLabel('Copied')), isSemantics(isLiveRegion: true));
    await tester.pump(const Duration(seconds: 2));
    handle.dispose();
  });

  testWidgets('UI-07: with its label it stays as it was (a code block header)', (tester) async {
    FakeHost();
    await pumpLook(tester, const Look(), const Scaffold(body: Center(child: CopyButton(text: 'x'))));
    expect(find.text('Copy'), findsOneWidget);
    expect(find.byTooltip('Copy'), findsNothing);
  });
}

void harnessTests() {
  Widget overflowing() => const Directionality(
    textDirection: TextDirection.ltr,
    child: Center(child: SizedBox(width: 40, child: Row(children: [SizedBox(width: 100, height: 10)]))),
  );

  testWidgets('the harness fails a test on an overflow', (tester) async {
    await tester.pumpWidget(overflowing());
    expect(() => collectLayoutErrors(tester, 'probe'), throwsA(isA<TestFailure>()));
    layoutErrors.clear();
  });

  testWidgets('a test that means to show an overflow can say so', (tester) async {
    allowOverflow = true;
    addTearDown(() => allowOverflow = false);
    await tester.pumpWidget(overflowing());
    collectLayoutErrors(tester, 'probe');
    expect(layoutErrors.single, contains('overflowed'));
    layoutErrors.clear();
  });
}
