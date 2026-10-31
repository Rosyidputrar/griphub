// The chat's context being summarized (pi's compaction, and the host's context limit): the line in the chat runs a
// clock, then says how much it saved, what it cost or why it failed, and the limit is set in Usage. The turns it
// replaced can still be read, on a screen of their own.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:griphub_agent/agent/agent_controller.dart';
import 'package:griphub_agent/agent/models.dart';
import 'package:griphub_agent/ui/live_clock.dart';
import 'package:griphub_agent/ui/message_views.dart';
import 'package:griphub_agent/ui/summarized_turns_screen.dart';
import 'package:griphub_agent/ui/usage_screen.dart';

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

  testWidgets('a summary runs a clock in the chat, then says how much it saved', (tester) async {
    final host = FakeHost();
    final agent = newAgent();
    pinClock();
    await tester.pump();
    host.emit({
      'type': 'event',
      'event': {'type': 'compaction_start', 'reason': 'limit', 'limit': 300000},
    });
    await frames(tester, 2);
    final c = agent.entries.single as CompactionEntry;
    expect(c.running, isTrue);
    expect(c.limit, 300000);
    expect(agent.entries.whereType<NoticeEntry>(), isEmpty, reason: 'no "Compacting…" notice left behind any more');
    host.emit({
      'type': 'event',
      'event': {
        'type': 'compaction_end',
        'reason': 'limit',
        'aborted': false,
        'result': {
          'tokensBefore': 320000,
          'estimatedTokensAfter': 24000,
          'griphubCost': {'credits': 0.42, 'floored': false},
        },
      },
    });
    await frames(tester, 2);
    expect(c.running, isFalse);
    expect(c.error, isNull);
    expect([c.tokensBefore, c.tokensAfter], [320000, 24000]);
    expect(c.credits, 0.42, reason: 'a summary is a paid request too');
  });

  testWidgets('a summary that failed says why', (tester) async {
    final host = FakeHost();
    final agent = newAgent();
    await tester.pump();
    host.emit({
      'type': 'event',
      'event': {'type': 'compaction_start', 'reason': 'threshold'},
    });
    host.emit({
      'type': 'event',
      'event': {'type': 'compaction_end', 'reason': 'threshold', 'aborted': false, 'errorMessage': 'Compaction failed: 402 credits'},
    });
    await frames(tester, 2);
    final c = agent.entries.single as CompactionEntry;
    expect(c.limit, isNull, reason: "pi's own, near the model's limit");
    expect(c.error, 'Compaction failed: 402 credits');
  });

  test("a summary read back from the chat's history", () {
    final agent = newAgent();
    agent.addHistoryMessage({
      'role': 'compactionSummary',
      'summary': '…',
      'tokensBefore': 410000,
      'griphubCost': {'credits': 1.5, 'floored': false},
    });
    final c = agent.entries.single as CompactionEntry;
    expect([c.running, c.tokensBefore, c.startedAt, c.credits], [false, 410000, null, 1.5]);
    agent.addHistoryMessage({'role': 'compactionSummary', 'summary': '…', 'tokensBefore': 9000});
    expect((agent.entries.last as CompactionEntry).credits, isNull, reason: 'a chat from before the host said');
  });

  for (final look in _looks) {
    testWidgets('golden: running, saved, from history, failed ${look.name}', (tester) async {
      FakeHost();
      pinClock();
      final done = CompactionEntry(startedAt: goldenNow.subtract(const Duration(seconds: 14)), limit: 300000)
        ..running = false
        ..took = const Duration(seconds: 14)
        ..tokensBefore = 320000
        ..tokensAfter = 24000
        ..credits = 0.42;
      final failed = CompactionEntry(startedAt: goldenNow.subtract(const Duration(seconds: 3)))
        ..running = false
        ..took = const Duration(seconds: 3)
        ..error = 'Compaction failed: 402 credits';
      await pumpLook(
        tester,
        look,
        Scaffold(
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              CompactionView(CompactionEntry(startedAt: goldenNow.subtract(const Duration(seconds: 6)), limit: 300000)),
              CompactionView(done),
              CompactionView(CompactionEntry(running: false, tokensBefore: 410000)),
              CompactionView(failed),
            ],
          ),
        ),
        height: 260,
      );
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(LiveClock), findsNWidgets(4));
      expect(layoutErrors, isEmpty);
      await expectLater(find.byType(Scaffold), matchesGoldenFile(golden('compaction_${look.name}')));
    });
  }

  group('the turns a summary replaced', () {
    final saved = <Map<String, dynamic>>[
      {
        'role': 'user',
        'content': [
          {'type': 'text', 'text': 'Fix the login: the email is not trimmed'},
        ],
        'timestamp': 1,
      },
      {
        'role': 'assistant',
        'content': [
          {'type': 'text', 'text': 'Trimmed it in **login.js** before signing in.'},
          {
            'type': 'toolCall',
            'id': 't1',
            'name': 'edit',
            'arguments': {'path': 'login.js'},
          },
        ],
        'model': 'claude-haiku-4.5',
        'timestamp': 2,
      },
      {
        'role': 'toolResult',
        'toolCallId': 't1',
        'content': [
          {'type': 'text', 'text': 'ok'},
        ],
        'isError': false,
      },
      {
        'role': 'user',
        'content': [
          {'type': 'text', 'text': 'And the tests?'},
        ],
        'timestamp': 3,
      },
    ];

    test('read from the host: the messages as entries, with their tools', () async {
      final host = FakeHost()..answers['summarized_messages'] = (_) => saved;
      final turns = await newAgent().summarizedTurns();
      expect(host.sent('summarized_messages'), hasLength(1));
      expect(turns.entries.map((e) => e.runtimeType), [UserEntry, AssistantEntry, UserEntry]);
      expect((turns.entries.first as UserEntry).text, 'Fix the login: the email is not trimmed');
      expect(turns.tools['t1']?.status, ToolStatus.done);
      expect((turns.entries[1] as AssistantEntry).streaming, isFalse, reason: 'read back, not being written');
    });

    testWidgets('the summary line offers them; a failed one does not', (tester) async {
      final host = FakeHost()..answers['summarized_messages'] = (_) => saved;
      final agent = newAgent();
      final done = CompactionEntry(running: false, tokensBefore: 410000);
      final failed = CompactionEntry(running: false)..error = 'Compaction failed: 402 credits';
      await pumpLook(
        tester,
        const Look(),
        Builder(
          builder: (context) => Scaffold(
            body: Column(
              children: [
                for (final e in [done, failed])
                  CompactionView(
                    e,
                    onShowEarlier: () => Navigator.of(
                      context,
                    ).push(MaterialPageRoute<void>(builder: (_) => SummarizedTurnsScreen(agent: agent))),
                  ),
              ],
            ),
          ),
        ),
      );
      await tester.tap(find.byType(CompactionView).last);
      await frames(tester);
      expect(find.text('Read the earlier turns'), findsNothing, reason: 'nothing was replaced');
      await tester.tap(find.text('OK'));
      await frames(tester);

      await tester.tap(find.byType(CompactionView).first);
      await frames(tester);
      await tester.tap(find.text('Read the earlier turns'));
      await frames(tester);
      expect(find.byType(SummarizedTurnsScreen), findsOneWidget);
      expect(host.sent('summarized_messages'), hasLength(1));
      expect(find.text('Fix the login: the email is not trimmed'), findsOneWidget);
      expect(find.text('And the tests?'), findsOneWidget);

      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String;
        return null;
      });
      await tester.tap(find.byTooltip('Copy as Markdown'));
      await frames(tester);
      expect(copied, contains('Fix the login: the email is not trimmed'));
      expect(copied, contains('Trimmed it in **login.js** before signing in.'));
      expect(find.text('Turns copied'), findsOneWidget);
    });

    testWidgets('a chat whose older turns are not there says so', (tester) async {
      FakeHost().answers['summarized_messages'] = (_) => const [];
      await pumpLook(tester, const Look(), SummarizedTurnsScreen(agent: newAgent()));
      await frames(tester);
      expect(find.textContaining('Nothing to show'), findsOneWidget);
      expect(find.byTooltip('Copy as Markdown'), findsNothing);
    });

    for (final look in _looks) {
      testWidgets('golden: the summarized turns ${look.name}', (tester) async {
        FakeHost().answers['summarized_messages'] = (_) => saved;
        pinClock();
        await pumpLook(tester, look, SummarizedTurnsScreen(agent: newAgent()), height: 700);
        await frames(tester);
        expect(layoutErrors, isEmpty);
        await expectLater(find.byType(Scaffold), matchesGoldenFile(golden('summarized_turns_${look.name}')));
      });
    }
  });

  testWidgets('the limit is set in Usage: 300k until changed, 0 leaves it to the model', (tester) async {
    final host = FakeHost();
    final agent = newAgent();
    await pumpLook(tester, const Look(), UsageScreen(agent: agent), height: 2600);
    await frames(tester);
    expect(find.text('Summarize the chat at'), findsOneWidget);
    expect(find.text('300k tokens'), findsOneWidget);
    await tester.tap(find.text('Summarize the chat at'));
    await frames(tester);
    expect(find.text('Recommended'), findsOneWidget);
    await tester.tap(find.text("At the model's limit"));
    await frames(tester);
    expect(host.sent('settings_set').last['settings'], {'compactAt': 0});
    expect(host.stored['compactAt'], 0, reason: 'kept as 0 (off), not cleared back to the default');
    expect(find.text("At the model's limit"), findsOneWidget, reason: 'the row says what is in force now');
  });
}
