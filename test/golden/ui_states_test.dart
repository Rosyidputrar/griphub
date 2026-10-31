// Second half of the UI audit (UI-10 to UI-24): states, motion, semantics and touch targets.
import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:griphub_agent/agent/models.dart';
import 'package:griphub_agent/main.dart';
import 'package:griphub_agent/ui/chat_screen.dart';
import 'package:griphub_agent/ui/code_view.dart';
import 'package:griphub_agent/ui/diff_view.dart';
import 'package:griphub_agent/ui/home_shell.dart';
import 'package:griphub_agent/ui/illustration.dart';
import 'package:griphub_agent/ui/mesh.dart';
import 'package:griphub_agent/ui/kit.dart';
import 'package:griphub_agent/ui/search_screen.dart';
import 'package:griphub_agent/ui/settings_hub.dart';
import 'package:griphub_agent/ui/message_views.dart';
import 'package:griphub_agent/ui/theme.dart';

import 'harness.dart';

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

  group('UI-11: a streaming reply', streamingTests);
  group('UI-12: long diffs', diffTests);
  group('UI-13: status bar', statusBarTests);
  group('UI-14: touch targets', touchTargetTests);
  group('UI-15: reduced motion', motionTests);
  group('UI-16: the chat list', chatsListTests);
  group('UI-17: announcements', announcementTests);
  group('UI-18: switch rows', switchRowTests);
  group('UI-19: wide screens', wideScreenTests);
  group('UI-20: Back', backTests);
  group('UI-21: pills', pillTests);
  group('UI-22: text size', textScaleTests);
  group('UI-24: attachments, avatar, credit', attachmentSemanticsTests);

  group('UI-10: a list that cannot be read says so', () {
    testWidgets('Home\'s Recent and the Chats tab show the error with a retry, and the retry works', (tester) async {
      final host = FakeHost();
      var fail = true;
      host.answers['sessions'] = (_) => fail ? const HostError('The server did not answer.') : <Object>[];
      await pumpLook(tester, const Look(), HomeShell(agent: newAgent()), height: 1600);
      await frames(tester);
      expect(find.text('The server did not answer.'), findsOneWidget, reason: 'Recent');
      await tester.tap(find.bySemanticsLabel(RegExp('^Chats')).first);
      await frames(tester, 12);
      expect(find.text('The server did not answer.'), findsOneWidget, reason: 'the Chats tab, not a spinner forever');
      fail = false;
      await tester.tap(find.text('Try again').last);
      await frames(tester, 12);
      expect(find.text('The server did not answer.'), findsNothing, reason: 'the Chats tab read the list again');
      expect(find.text('No chats yet. Tap + to start one.'), findsOneWidget);
    });
  });
}

void splitIs(String text, List<String> done, String rest) {
  final (d, r) = splitFinishedBlocks(text);
  expect(d, done, reason: 'finished blocks of ${text.replaceAll('\n', r'\n')}');
  expect(r, rest, reason: 'the rest of ${text.replaceAll('\n', r'\n')}');
}

void streamingTests() {
  test('UI-11: finished blocks are split off; a fence keeps its blank lines; the rest is what is being written', () {
    splitIs('One.\n\nTwo is be', ['One.'], 'Two is be');
    splitIs('One.', <String>[], 'One.');
    splitIs('One.\n\n', ['One.'], ''); // a blank line ends it
    splitIs('# Title\n\n- a\n- b\n\nAfter', ['# Title', '- a\n- b'], 'After');
    final fenced = '```\nline 1\n\nline 2\n```\n\nNext';
    splitIs(fenced, ['```\nline 1\n\nline 2\n```'], 'Next');
    splitIs('Intro\n\n```\ncode\n\nmore', ['Intro'], '```\ncode\n\nmore');
  });

  testWidgets('UI-11: while a reply streams, the finished blocks are not rebuilt; at the end it is one markdown body', (tester) async {
    FakeHost();
    const first = 'Paragraf pertama yang sudah selesai.';
    var text = '$first\n\nKalimat ked';
    late StateSetter set;
    await pumpLook(
      tester,
      const Look(),
      Scaffold(
        body: StatefulBuilder(
          builder: (context, s) {
            set = s;
            return TypewriterMarkdown(text: text, live: true);
          },
        ),
      ),
    );
    await tester.pump(const Duration(seconds: 2));
    final firstBlock = tester.widget<MarkdownText>(find.byType(MarkdownText).first);
    expect(firstBlock.data, first);
    set(() => text = '$text kedua yang masih ditulis, lebih panjang.');
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
    expect(identical(tester.widget<MarkdownText>(find.byType(MarkdownText).first), firstBlock), isTrue, reason: 'the same widget: not parsed again');
    await pumpLook(tester, const Look(), const Scaffold(body: TypewriterMarkdown(text: '$first\n\nAkhir.', live: false)));
    expect(find.byType(MarkdownText), findsOneWidget, reason: 'the finished reply is drawn as before');
  });

  testWidgets('UI-11: the typewriter updates about 30 times a second, not every frame', (tester) async {
    FakeHost();
    var builds = 0;
    var text = 'Mulai';
    late StateSetter set;
    await pumpLook(
      tester,
      const Look(),
      Scaffold(
        body: SingleChildScrollView(
          child: _CountBuilds(
            onBuild: () => builds++,
            child: StatefulBuilder(
              builder: (context, s) {
                set = s;
                return TypewriterMarkdown(text: text, live: true);
              },
            ),
          ),
        ),
      ),
    );
    builds = 0;
    // The reply keeps arriving, a few characters a frame, for one second.
    for (var i = 0; i < 60; i++) {
      set(() => text = '$text kata');
      await tester.pump(const Duration(microseconds: 1000000 ~/ 60));
    }
    expect(builds, lessThanOrEqualTo(32), reason: '$builds updates in one second');
    expect(builds, greaterThanOrEqualTo(20), reason: 'still smooth: $builds');
  });
}

/// Counts how often the typewriter's text below it is rebuilt.
class _CountBuilds extends StatelessWidget {
  const _CountBuilds({required this.onBuild, required this.child});
  final VoidCallback onBuild;
  final Widget child;

  @override
  Widget build(BuildContext context) => NotificationListener<TranscriptGrew>(
    onNotification: (_) {
      onBuild();
      return true;
    },
    child: child,
  );
}

String _bigPatch(int n) {
  final b = StringBuffer('diff --git a/big.txt b/big.txt\n--- a/big.txt\n+++ b/big.txt\n@@ -0,0 +1,$n @@\n');
  for (var i = 1; i <= n; i++) {
    b.writeln('+line $i of the generated file');
  }
  return b.toString();
}

void diffTests() {
  testWidgets('UI-12: a 4000-line diff builds only the rows on screen, and the last one shown can be scrolled to', (tester) async {
    FakeHost();
    await pumpLook(tester, const Look(), Scaffold(body: SingleChildScrollView(child: DiffView(patch: _bigPatch(4000)))));
    await tester.pump();
    final built = find.textContaining(RegExp(r'^line \d+ of')).evaluate().length;
    expect(built, lessThan(200), reason: '$built rows built for 4000 lines');
    expect(find.text('line 1 of the generated file'), findsOneWidget);
    final list = tester.state<ScrollableState>(find.descendant(of: find.byType(ListView), matching: find.byType(Scrollable)).first);
    list.position.jumpTo(list.position.maxScrollExtent);
    await tester.pump();
    expect(find.text('line 3999 of the generated file'), findsOneWidget, reason: 'the hunk header counts as one of the 4000 rows shown');
    expect(find.text('1 more lines not shown'), findsOneWidget);
  });

  testWidgets('UI-12: inside a card with a height (the review screen) the long diff scrolls within it', (tester) async {
    FakeHost();
    await pumpLook(tester, const Look(), Scaffold(body: SingleChildScrollView(child: DiffView(patch: _bigPatch(1000), showHeaders: false, maxHeight: 420))));
    await tester.pump();
    expect(tester.getSize(find.byType(DiffView)).height, lessThanOrEqualTo(420));
    expect(find.textContaining(RegExp(r'^line \d+ of')).evaluate().length, lessThan(100));
  });

  testWidgets('UI-12: a short diff is drawn as before, all of it', (tester) async {
    FakeHost();
    await pumpLook(tester, const Look(), Scaffold(body: SingleChildScrollView(child: DiffView(patch: _bigPatch(50)))));
    await tester.pump();
    expect(find.textContaining(RegExp(r'^line \d+ of')).evaluate().length, 50);
    expect(find.byType(ListView), findsNothing);
  });
}

void statusBarTests() {
  for (final (mode, icons) in [(ThemeMode.light, Brightness.dark), (ThemeMode.dark, Brightness.light)]) {
    testWidgets('UI-13: the status bar icons follow the theme on every screen ($mode), not only under an AppBar', (tester) async {
      FakeHost();
      final before = Appearance.instance.value;
      addTearDown(() => Appearance.instance.value = before);
      Appearance.instance.value = mode;
      await tester.pumpWidget(GripHubApp(agent: newAgent()));
      await tester.pump(const Duration(milliseconds: 300));
      // The app's own region, above every screen (onboarding and the boot screens have no AppBar).
      final region = tester.widget<AnnotatedRegion<SystemUiOverlayStyle>>(find.byType(AnnotatedRegion<SystemUiOverlayStyle>).first);
      expect(region.value.statusBarIconBrightness, icons);
      expect(region.value.statusBarColor, Colors.transparent);
    });
  }
}

void touchTargetTests() {
  void atLeast48(WidgetTester tester, Finder f, String what) {
    final s = tester.getSize(f);
    expect(s.width >= 48 && s.height >= 48, isTrue, reason: '$what is $s');
  }

  testWidgets('UI-14: Home\'s category chips are 48 dp to touch', (tester) async {
    FakeHost();
    await pumpLook(tester, const Look(width: 360), HomeShell(agent: newAgent()), height: 1600);
    await frames(tester);
    for (final label in ['All types', 'Make', 'Code']) {
      atLeast48(tester, find.ancestor(of: find.text(label), matching: find.byType(TapTarget)).first, label);
    }
  });

  testWidgets('UI-14: the search toggles are 48 dp to touch, and say whether they are on', (tester) async {
    final handle = tester.ensureSemantics();
    FakeHost();
    await pumpLook(tester, const Look(width: 360), SearchScreen(agent: newAgent()));
    await frames(tester);
    for (final label in ['Regex', 'Match case']) {
      atLeast48(tester, find.ancestor(of: find.text(label), matching: find.byType(InkWell)).first, label);
    }
    expect(tester.getSemantics(find.ancestor(of: find.text('Regex'), matching: find.byType(Semantics)).first), isSemantics(hasToggledState: true));
    handle.dispose();
  });

  testWidgets('UI-14: the Chats selection bar keeps 48 dp buttons', (tester) async {
    final host = FakeHost();
    host.answers['sessions'] = (_) => [
      {'path': '/s/a.jsonl', 'id': 'a', 'name': 'Nota toko', 'cwd': '/w', 'messageCount': 3, 'modified': 1761900000000},
    ];
    await pumpLook(tester, const Look(width: 360), HomeShell(agent: newAgent()), height: 1600);
    await frames(tester);
    await tester.tap(find.bySemanticsLabel(RegExp('^Chats')).first);
    await frames(tester, 12);
    await tester.longPress(find.text('Nota toko'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Select'));
    await tester.pumpAndSettle();
    // The IconButton itself (its 48 dp touch padding is outside the tooltip it draws).
    atLeast48(tester, find.ancestor(of: find.byTooltip('Cancel'), matching: find.byType(IconButton)).first, 'Cancel');
    atLeast48(tester, find.ancestor(of: find.byTooltip('Delete'), matching: find.byType(IconButton)).first, 'Delete');
  });
}

void motionTests() {
  for (final reduced in [false, true]) {
    testWidgets('UI-15: animations take no time when the system says to remove them (reduced: $reduced)', (tester) async {
      FakeHost();
      await pumpLook(
        tester,
        const Look(),
        Builder(
          builder: (context) => MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: reduced),
            child: Scaffold(
              body: Column(
                children: [
                  PrimaryButton(label: 'Go', onPressed: () {}),
                  const CopyButton(text: 'x'),
                ],
              ),
            ),
          ),
        ),
      );
      final opacity = tester.widget<AnimatedOpacity>(find.descendant(of: find.byType(PrimaryButton), matching: find.byType(AnimatedOpacity)));
      final swap = tester.widget<AnimatedSwitcher>(find.descendant(of: find.byType(CopyButton), matching: find.byType(AnimatedSwitcher)));
      expect(opacity.duration, reduced ? Duration.zero : const Duration(milliseconds: 150));
      expect(swap.duration, reduced ? Duration.zero : const Duration(milliseconds: 150));
    });
  }
}

void chatsListTests() {
  List<Map<String, dynamic>> many(int n) => [
    for (var i = 0; i < n; i++)
      {'path': '/s/c$i.jsonl', 'id': 'c$i', 'name': 'Chat nomor $i', 'cwd': '/w', 'messageCount': 2, 'modified': 1761900000000 - i * 60000},
  ];

  testWidgets('UI-16: hundreds of chats: only the rows on screen are built, and the agent\'s reports do not rebuild them', (tester) async {
    final host = FakeHost();
    host.answers['sessions'] = (_) => many(400);
    final agent = newAgent();
    await pumpLook(tester, const Look(), HomeShell(agent: agent), height: 900);
    await frames(tester);
    await tester.tap(find.bySemanticsLabel(RegExp('^Chats')).first);
    await frames(tester, 12);
    final built = find.textContaining(RegExp(r'^Chat nomor \d+$')).evaluate().length;
    expect(built, inInclusiveRange(1, 40), reason: '$built of 400 rows built');
    // A row's element stays the same widget when the agent reports something else.
    final row = find.text('Chat nomor 0');
    final before = tester.element(row).widget;
    agent.billingNotice = 'something else changed';
    agent.notifyListeners();
    await tester.pump();
    expect(identical(tester.element(row).widget, before), isTrue, reason: 'not rebuilt for a report that is not about it');
  });

  testWidgets('UI-16: the search text survives the lazy list', (tester) async {
    final host = FakeHost();
    host.answers['sessions'] = (_) => many(400);
    await pumpLook(tester, const Look(), HomeShell(agent: newAgent()), height: 900);
    await frames(tester);
    await tester.tap(find.bySemanticsLabel(RegExp('^Chats')).first);
    await frames(tester, 12);
    await tester.enterText(find.byType(TextField).last, 'nomor 39');
    await frames(tester);
    expect(find.text('Chat nomor 39'), findsOneWidget);
    expect(find.text('Chat nomor 1'), findsNothing);
  });
}

void announcementTests() {
  testWidgets('UI-17: what the agent is doing is read out as it changes', (tester) async {
    final handle = tester.ensureSemantics();
    FakeHost();
    await pumpLook(tester, const Look(), const Scaffold(body: AgentActivity(label: 'Running bash…')));
    expect(tester.getSemantics(find.bySemanticsLabel('Running bash…')), isSemantics(isLiveRegion: true));
    await pumpLook(tester, const Look(), const Scaffold(body: AgentActivity()));
    expect(find.bySemanticsLabel('Working…'), findsOneWidget, reason: 'no label: still says something');
    handle.dispose();
  });

  testWidgets('UI-17: a tool card says how it went in words, and whether it is open', (tester) async {
    final handle = tester.ensureSemantics();
    FakeHost();
    final block = Block(BlockKind.toolCall)
      ..toolCallId = 't1'
      ..toolName = 'bash'
      ..args = {'command': 'npm test'};
    final run = ToolRun('t1')..status = ToolStatus.failed;
    await pumpLook(tester, const Look(), Scaffold(body: ToolCallView(block: block, run: run)));
    // The header is one button to a screen reader: its label now starts with how the call went.
    final header = find.bySemanticsLabel(RegExp(r'^Failed\b'));
    expect(header, findsOneWidget, reason: 'the red x, in words');
    expect(tester.getSemantics(header), isSemantics(hasExpandedState: true, isExpanded: false));
    await tester.tap(find.text('npm test'));
    await tester.pump();
    expect(tester.getSemantics(find.bySemanticsLabel(RegExp(r'^Failed\b'))), isSemantics(hasExpandedState: true, isExpanded: true));
    handle.dispose();
  });

  testWidgets('UI-17: the thinking panel says whether it is open', (tester) async {
    final handle = tester.ensureSemantics();
    FakeHost();
    await pumpLook(tester, const Look(), const Scaffold(body: ThinkingView(text: 'Langkah satu.\nLangkah dua.', live: false)));
    final header = find.bySemanticsLabel(RegExp('Thought process'));
    expect(tester.getSemantics(header), isSemantics(hasExpandedState: true, isExpanded: false));
    await tester.tap(find.text('Thought process'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.getSemantics(find.bySemanticsLabel(RegExp('Thought process'))), isSemantics(hasExpandedState: true, isExpanded: true));
    handle.dispose();
  });
}

void switchRowTests() {
  /// Every semantics node's label, to count how often a title is read.
  List<String> labels(WidgetTester tester) =>
      find.semantics.byPredicate((n) => n.label.isNotEmpty).evaluate().map((n) => n.label).toList();

  testWidgets('UI-18: a settings row with a switch reads its title once, with the state of its switch', (tester) async {
    final handle = tester.ensureSemantics();
    FakeHost();
    var on = true;
    await pumpLook(
      tester,
      const Look(),
      Scaffold(
        body: StatefulBuilder(
          builder: (context, set) => SettingsRow(
            title: 'App lock',
            subtitle: 'Ask for the fingerprint',
            onTap: () => set(() => on = !on),
            trailing: LabeledSwitch(label: 'App lock', value: on, onChanged: (v) => set(() => on = v)),
          ),
        ),
      ),
    );
    final all = labels(tester).join('\n');
    expect(RegExp('App lock').allMatches(all).length, 1, reason: 'read once: $all');
    expect(tester.getSemantics(find.bySemanticsLabel(RegExp('App lock'))), isSemantics(hasToggledState: true, isToggled: true));
    handle.dispose();
  });

  testWidgets('UI-18: a switch on its own still says what it switches', (tester) async {
    final handle = tester.ensureSemantics();
    FakeHost();
    await pumpLook(tester, const Look(), Scaffold(body: Center(child: LabeledSwitch(label: 'Web search', value: false, onChanged: (_) {}))));
    expect(tester.getSemantics(find.bySemanticsLabel('Web search')), isSemantics(hasToggledState: true, isToggled: false));
    handle.dispose();
  });

  testWidgets('UI-18: a row with a menu beside its switch keeps them apart (the menu is not lost)', (tester) async {
    final handle = tester.ensureSemantics();
    FakeHost();
    await pumpLook(
      tester,
      const Look(),
      Scaffold(
        body: SettingsRow(
          title: 'Nightly',
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              LabeledSwitch(label: 'Nightly', value: true, onChanged: (_) {}),
              PopupMenuButton<String>(tooltip: 'More', itemBuilder: (_) => const []),
            ],
          ),
        ),
      ),
    );
    expect(find.byTooltip('More'), findsOneWidget);
    final switches = find.semantics.byPredicate((n) => n.flagsCollection.isToggled != Tristate.none);
    expect(switches.evaluate(), isNotEmpty, reason: 'the switch is its own control: ${labels(tester)}');
    expect(find.semantics.byPredicate((n) => n.tooltip == 'More').evaluate(), isNotEmpty, reason: 'and so is the menu');
    handle.dispose();
  });
}

void wideScreenTests() {
  testWidgets('UI-19: on a wide screen the Home content and the nav bar keep a readable width', (tester) async {
    FakeHost();
    await pumpLook(tester, const Look(width: 880), HomeShell(agent: newAgent()), height: 1000);
    await frames(tester);
    final content = tester.getSize(find.byType(ContentWidth).first);
    expect(content.width, 880);
    // The tab inside it: no wider than 720.
    final tab = tester.getRect(find.descendant(of: find.byType(ContentWidth).first, matching: find.byType(SafeArea)).first);
    expect(tab.width, lessThanOrEqualTo(720));
    expect(tab.center.dx, closeTo(440, 1), reason: 'centred');
  });

  testWidgets('UI-19: a message bubble stops at a readable width', (tester) async {
    FakeHost();
    late double wide;
    late double phone;
    await pumpLook(tester, const Look(width: 880), Builder(builder: (c) {
      wide = bubbleWidth(c);
      return const SizedBox();
    }));
    await pumpLook(tester, const Look(width: 390), Builder(builder: (c) {
      phone = bubbleWidth(c);
      return const SizedBox();
    }));
    expect(wide, 560);
    expect(phone, closeTo(390 * 0.82, 0.01), reason: 'a phone is as before');
  });

  testWidgets('UI-19: below its width ContentWidth changes nothing', (tester) async {
    FakeHost();
    await pumpLook(tester, const Look(width: 390), const ContentWidth(child: SizedBox.expand(key: ValueKey('c'))));
    expect(tester.getSize(find.byKey(const ValueKey('c'))).width, 390);
  });
}

void backTests() {
  testWidgets('UI-20: Back on Chats, Skills or Projects goes to Home instead of leaving the app', (tester) async {
    FakeHost();
    await pumpLook(tester, const Look(), HomeShell(agent: newAgent()), height: 1600);
    await frames(tester);
    for (final tab in ['Chats', 'Skills', 'Projects']) {
      await tester.tap(find.bySemanticsLabel(RegExp('^$tab')).first);
      await frames(tester, 12);
      final handled = await tester.binding.handlePopRoute();
      await frames(tester, 12);
      expect(handled, isTrue, reason: 'Back on $tab was handled by the app');
      expect(find.text('Recent'), findsOneWidget, reason: 'and Home is showing again');
    }
  });

  testWidgets('UI-20: picking chats, Back leaves the picking first and stays on Chats', (tester) async {
    final host = FakeHost();
    host.answers['sessions'] = (_) => [
      {'path': '/s/a.jsonl', 'id': 'a', 'name': 'Nota toko', 'cwd': '/w', 'messageCount': 3, 'modified': 1761900000000},
    ];
    await pumpLook(tester, const Look(), HomeShell(agent: newAgent()), height: 1600);
    await frames(tester);
    await tester.tap(find.bySemanticsLabel(RegExp('^Chats')).first);
    await frames(tester, 12);
    await tester.longPress(find.text('Nota toko'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Select'));
    await tester.pumpAndSettle();
    expect(find.text('1 selected'), findsOneWidget);
    await tester.binding.handlePopRoute();
    await frames(tester, 12);
    expect(find.text('1 selected'), findsNothing, reason: 'the picking ended');
    expect(find.text('Nota toko'), findsOneWidget, reason: 'still on Chats');
  });
}

void pillTests() {
  testWidgets('UI-21: a danger pill on a card uses a text colour that reads', (tester) async {
    FakeHost();
    await pumpLook(tester, const Look(), Scaffold(body: Container(color: Palette.light.surface, child: Pill('Failed', color: Palette.light.danger))));
    final text = tester.widget<Text>(find.text('Failed'));
    final bg = Color.alphaBlend(Palette.light.danger.withValues(alpha: 0.12), Palette.light.surface);
    final ratio = contrastRatio(text.style!.color!, bg);
    expect(ratio, greaterThanOrEqualTo(4.5), reason: '$ratio:1');
  });
}

void textScaleTests() {
  test('UI-22: the app\'s and the system\'s text sizes multiply, up to 2.2x', () {
    expect(effectiveTextScale(1.25, 2.0), maxTextScale);
    expect(effectiveTextScale(1.0, 1.3), closeTo(1.3, 1e-9));
    expect(effectiveTextScale(1.25, 1.0), 1.25);
    expect(effectiveTextScale(0.9, 1.0), 0.9, reason: 'smaller text is left alone');
  });

  for (final look in const [Look(textScale: 2.0), Look(language: 'id', textScale: 2.0, width: 360)]) {
    testWidgets('UI-22: the chat and Settings are laid out at 2x text (${look.name})', (tester) async {
      FakeHost();
      final agent = newAgent()..model = ModelInfo({'provider': 'griphub', 'id': 'mock', 'name': 'Mock'});
      await pumpLook(tester, look, ChatScreen(agent: agent), height: 1400);
      await frames(tester);
      collectLayoutErrors(tester, 'chat ${look.name}');
      await pumpLook(tester, look, SettingsHub(agent: newAgent()), height: 2400);
      await frames(tester);
      collectLayoutErrors(tester, 'settings ${look.name}');
    });
  }

  testWidgets('UI-22: golden at 2x text: the chat', (tester) async {
    FakeHost();
    final agent = newAgent()..model = ModelInfo({'provider': 'griphub', 'id': 'mock', 'name': 'Mock'});
    await pumpLook(tester, const Look(textScale: 2.0), ChatScreen(agent: agent));
    await frames(tester);
    await loadImages(tester);
    await expectLater(find.byType(ChatScreen), matchesGoldenFile(golden('chat_text_x2.0')));
  });

  testWidgets('UI-22: golden at 2x text: Settings', (tester) async {
    FakeHost();
    await pumpLook(tester, const Look(language: 'id', textScale: 2.0), SettingsHub(agent: newAgent()));
    await frames(tester);
    await loadImages(tester);
    await expectLater(find.byType(SettingsHub), matchesGoldenFile(golden('settings_text_x2.0_id')));
  });
}

void attachmentSemanticsTests() {
  testWidgets('UI-24: a sent file chip and a photo say what they are and open, and the chip is 48 dp', (tester) async {
    final handle = tester.ensureSemantics();
    FakeHost();
    await pumpLook(
      tester,
      const Look(),
      const Scaffold(
        body: MessageAttachments(
          attachments: [
            (path: '/w/notes.pdf', name: 'notes.pdf', mime: 'application/pdf', size: 2048),
            (path: '/w/shot.png', name: 'shot.png', mime: 'image/png', size: 4096),
          ],
        ),
      ),
    );
    await tester.pump();
    final chip = find.bySemanticsLabel('Open file notes.pdf');
    expect(chip, findsOneWidget);
    expect(tester.getSemantics(chip), isSemantics(isButton: true, hasTapAction: true));
    expect(tester.getSize(chip).height, greaterThanOrEqualTo(48));
    expect(tester.getSemantics(find.bySemanticsLabel('Open photo shot.png')), isSemantics(isButton: true, isImage: true));
    handle.dispose();
  });

  testWidgets('UI-24: an avatar has a name for a screen reader', (tester) async {
    final handle = tester.ensureSemantics();
    FakeHost();
    await pumpLook(tester, const Look(), const Scaffold(body: Center(child: Avatar(name: 'Rosyid Putra'))));
    expect(tester.getSemantics(find.bySemanticsLabel('Rosyid Putra')), isSemantics(isImage: true));
    handle.dispose();
  });

  testWidgets('UI-24: the Storyset credit is a 48 dp link', (tester) async {
    final handle = tester.ensureSemantics();
    FakeHost();
    String? opened;
    await pumpLook(tester, const Look(), Scaffold(body: Center(child: StorysetCredit(openUrl: (u) async => opened = u))));
    final link = find.bySemanticsLabel('Illustrations by Storyset');
    expect(tester.getSemantics(link), isSemantics(isLink: true));
    expect(tester.getSize(find.byType(TapTarget)).height, greaterThanOrEqualTo(48));
    await tester.tap(find.byType(TapTarget));
    expect(opened, 'https://storyset.com');
    handle.dispose();
  });
}
