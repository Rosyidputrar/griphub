// The chat's context being summarized (pi's compaction, and the host's context limit): the line in the chat runs a
// clock, then says how much it saved or why it failed, and the limit is set in Usage.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:griphub_agent/agent/models.dart';
import 'package:griphub_agent/ui/live_clock.dart';
import 'package:griphub_agent/ui/message_views.dart';
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
        'result': {'tokensBefore': 320000, 'estimatedTokensAfter': 24000},
      },
    });
    await frames(tester, 2);
    expect(c.running, isFalse);
    expect(c.error, isNull);
    expect([c.tokensBefore, c.tokensAfter], [320000, 24000]);
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
    agent.addHistoryMessage({'role': 'compactionSummary', 'summary': '…', 'tokensBefore': 410000});
    final c = agent.entries.single as CompactionEntry;
    expect([c.running, c.tokensBefore, c.startedAt], [false, 410000, null]);
  });

  for (final look in _looks) {
    testWidgets('golden: running, saved, from history, failed ${look.name}', (tester) async {
      FakeHost();
      pinClock();
      final done = CompactionEntry(startedAt: goldenNow.subtract(const Duration(seconds: 14)), limit: 300000)
        ..running = false
        ..took = const Duration(seconds: 14)
        ..tokensBefore = 320000
        ..tokensAfter = 24000;
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
