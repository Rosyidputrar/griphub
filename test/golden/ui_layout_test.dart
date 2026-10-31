// Layouts that broke on ordinary phones (UI audit): each case is pumped at the sizes that broke it, and fails on any
// overflow instead of only recording it. Goldens show the fixed layout.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:griphub_agent/agent/agent_controller.dart';
import 'package:griphub_agent/agent/models.dart';
import 'package:griphub_agent/ui/chat_screen.dart';
import 'package:griphub_agent/ui/griphub_screen.dart';
import 'package:griphub_agent/ui/kit.dart';
import 'package:griphub_agent/ui/onboarding.dart';

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
