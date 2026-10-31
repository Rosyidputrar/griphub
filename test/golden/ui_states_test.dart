// Second half of the UI audit (UI-10 to UI-24): states, motion, semantics and touch targets.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
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
