// The "+" of the bottom bar opens two choices over the page, Chat and Coding (lib/ui/plus_menu.dart): the plus turns
// into a cross, the page dims, Back and a tap on the page close it, Chat starts a plain conversation at once, and
// Coding goes on to the sheet that asks for the folder.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:griphub_agent/ui/home_shell.dart';
import 'package:griphub_agent/ui/i18n.dart';
import 'package:griphub_agent/ui/plus_menu.dart';

import 'harness.dart';

const _looks = [Look(), Look(dark: true, language: 'id'), Look(language: 'id', textScale: 1.3, width: 320)];

Future<void> frames(WidgetTester tester, [int n = 8]) async {
  for (var i = 0; i < n; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  setUpAll(loadAppFonts);
  setUp(() {
    applyLook(const Look());
    layoutErrors.clear();
  });

  late FakeHost host;

  Future<void> home(WidgetTester tester, Look look) async {
    host = FakeHost();
    host.answers['projects'] = (_) => [
      {'name': 'shop', 'path': '/ws/shop', 'git': true},
    ];
    host.answers['sessions'] = (_) => [
      {'path': '/s/a.jsonl', 'id': 'a', 'name': 'Berita hari ini', 'cwd': '/ws/.chats', 'chatMode': 'chat', 'messageCount': 3, 'modified': 1761900000000},
      {'path': '/s/b.jsonl', 'id': 'b', 'name': 'Landing page kedai kopi', 'cwd': '/ws/kedai-kopi', 'messageCount': 5, 'modified': 1761890000000},
    ];
    host.answers['new_session'] = (c) => {
      'sessionFile': 'new.jsonl',
      'sessionId': 'new',
      'chatMode': c['chatMode'] ?? 'coding',
      'cwd': c['chatMode'] == 'chat' ? '/ws/.chats' : (c['cwd'] ?? '/ws'),
    };
    final agent = newAgent()..info = {'workspace': '/ws'};
    await pumpLook(tester, look, HomeShell(agent: agent), height: 844);
    await frames(tester);
    await tester.tap(find.bySemanticsLabel(RegExp('^${tr('Chats')}')).first);
    await frames(tester, 12);
  }

  Finder plus() => find.bySemanticsLabel(tr('New chat'));
  // Inside the menu only: the Chats tab has its own "Chat" and "Coding" filter.
  Finder inMenu(String text) => find.descendant(of: find.byType(PlusMenuLayer), matching: find.text(text));
  Finder chat() => inMenu(tr('Chat'));
  Finder coding() => inMenu(tr('Coding'));

  for (final look in _looks) {
    testWidgets('the menu is out, with both choices in view (${look.name})', (tester) async {
      await home(tester, look);
      expect(coding(), findsNothing, reason: 'closed: nothing of it on the screen');
      await tester.tap(plus());
      await frames(tester, 12);
      expect(layoutErrors, isEmpty);
      expect(chat(), findsOneWidget);
      expect(coding(), findsOneWidget);
      expect(inMenu(tr('Ask, look up news, write')), findsOneWidget);
      expect(inMenu(tr('Build in a project folder')), findsOneWidget);
      // Both above the bar, and apart from each other.
      final bar = tester.getTopLeft(find.bySemanticsLabel(RegExp('^${tr('Home')}'))).dy;
      expect(tester.getBottomLeft(chat()).dy, lessThan(bar));
      expect(tester.getTopLeft(coding()).dy, lessThan(tester.getTopLeft(chat()).dy), reason: 'Coding is the farther one');
      await expectLater(find.byType(MaterialApp), matchesGoldenFile(golden('plus_menu_${look.name}')));
    });
  }

  testWidgets('each choice is a 48 dp target at least', (tester) async {
    await home(tester, const Look(language: 'id', textScale: 1.3, width: 320));
    await tester.tap(plus());
    await frames(tester, 12);
    for (final f in [chat(), coding()]) {
      final tile = find.ancestor(of: f, matching: find.byType(InkWell)).first;
      final s = tester.getSize(tile);
      expect(s.height >= 48 && s.width >= 48, isTrue, reason: '$f is $s');
    }
  });

  testWidgets('the plus turns into a cross and says it is expanded; a second tap closes it', (tester) async {
    final handle = tester.ensureSemantics();
    await home(tester, const Look());
    expect(tester.getSemantics(plus()), isSemantics(isButton: true, isExpanded: false, hasExpandedState: true, label: 'New chat'));
    await tester.tap(plus());
    await frames(tester, 12);
    expect(tester.getSemantics(plus()), isSemantics(isButton: true, isExpanded: true, hasExpandedState: true, label: 'New chat'));
    await tester.tap(plus());
    await frames(tester, 12);
    expect(coding(), findsNothing);
    handle.dispose();
  });

  testWidgets('Back closes the menu first, and stays on the tab', (tester) async {
    await home(tester, const Look());
    await tester.tap(plus());
    await frames(tester, 12);
    await tester.binding.handlePopRoute();
    await frames(tester, 12);
    expect(coding(), findsNothing, reason: 'the menu is closed');
    expect(find.text('Berita hari ini'), findsOneWidget, reason: 'still on the Chats tab, not sent to Home');
    // Back again, now with nothing out, goes to Home as before: the Chats tab is gone from the screen.
    await tester.binding.handlePopRoute();
    await frames(tester, 12);
    expect(find.text(tr('Search anything')), findsNothing);
  });

  testWidgets('a tap on the page behind closes it, and nothing starts', (tester) async {
    await home(tester, const Look());
    await tester.tap(plus());
    await frames(tester, 12);
    await tester.tapAt(const Offset(195, 200));
    await frames(tester, 12);
    expect(coding(), findsNothing);
    expect(host.sent('new_session'), isEmpty);
  });

  testWidgets('switching tab with the menu out closes it', (tester) async {
    await home(tester, const Look());
    await tester.tap(plus());
    await frames(tester, 12);
    await tester.tap(find.bySemanticsLabel(RegExp('^${tr('Home')}')).first);
    await frames(tester, 12);
    expect(coding(), findsNothing);
  });

  testWidgets('Chat starts a plain conversation at once: no folder is sent, and no sheet', (tester) async {
    await home(tester, const Look());
    await tester.tap(plus());
    await frames(tester, 12);
    await tester.tap(chat());
    await frames(tester, 20);
    final sent = host.sent('new_session');
    expect(sent, hasLength(1));
    expect(sent.single['chatMode'], 'chat');
    expect(sent.single.containsKey('cwd'), isFalse);
    expect(find.text(tr('Coding chat')), findsNothing, reason: 'the folder sheet is for Coding');
  });

  testWidgets('Coding goes on to the sheet that asks for the folder, and starts nothing yet', (tester) async {
    await home(tester, const Look());
    await tester.tap(plus());
    await frames(tester, 12);
    await tester.tap(coding());
    await frames(tester, 20);
    await sheetSettles(tester);
    expect(find.text(tr('Coding chat')), findsOneWidget);
    expect(find.text(tr('New project')), findsOneWidget);
    expect(host.sent('new_session'), isEmpty);
    expect(coding(), findsNothing, reason: 'the menu is gone behind the sheet');
  });

  testWidgets('with animations off the choices are there at once, with no half-way picture', (tester) async {
    // What main.dart does with the setting: the platform says animations are off.
    tester.platformDispatcher.accessibilityFeaturesTestValue = const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    await home(tester, const Look());
    await tester.tap(plus());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    expect(chat(), findsOneWidget);
    expect(coding(), findsOneWidget);
    final opacity = tester.widgetList<Opacity>(find.ancestor(of: chat(), matching: find.byType(Opacity))).first.opacity;
    expect(opacity, 1.0);
  });
}
