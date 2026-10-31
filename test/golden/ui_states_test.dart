// Second half of the UI audit (UI-10 to UI-24): states, motion, semantics and touch targets.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:griphub_agent/ui/diff_view.dart';
import 'package:griphub_agent/ui/home_shell.dart';
import 'package:griphub_agent/ui/message_views.dart';

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
