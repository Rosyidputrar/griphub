// Golden renders of the subagent UI: settings screen, inline cards, the
// transcript placement, detail sheet, cross-chat banner and dialogs, across
// light/dark, English/Indonesian, compact mode, large text and a narrow phone.
//
//   flutter test test/golden --update-goldens   # (re)render the PNGs
//   flutter test test/golden                    # compare against them
//
// Every render must lay out cleanly: an overflow fails the test.
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:griphub_agent/agent/agent_controller.dart';
import 'package:griphub_agent/agent/integrations.dart';
import 'package:griphub_agent/agent/models.dart';
import 'package:griphub_agent/ui/kit.dart';
import 'package:griphub_agent/ui/message_views.dart';
import 'package:griphub_agent/ui/subagent_card.dart';
import 'package:griphub_agent/ui/subagent_settings_screen.dart';

import 'harness.dart';

const looks = [
  Look(),
  Look(dark: true, language: 'id'),
  Look(compact: true),
  Look(language: 'id', textScale: 1.3, width: 320),
  Look(textScale: 1.3, width: 320),
];

int _ms(Duration ago) => goldenNow.subtract(ago).millisecondsSinceEpoch;

Map<String, dynamic> subRecord(
  String id, {
  String status = 'running',
  String profile = 'read',
  String parent = 'chat-1.jsonl',
  String title = 'Riset framework UI',
  String? toolCallId,
  Duration started = const Duration(seconds: 75),
  Duration? finished,
  String? tool,
  String? args,
  double? credits,
  String? report,
  String? error,
  String? stopReason,
  String? stopCode,
  List<Map<String, dynamic>> tools = const [],
  List<Map<String, dynamic>> queue = const [],
}) => {
  'id': id,
  'toolCallId': ?toolCallId,
  'parentSessionFile': parent,
  'parentTitle': title,
  'brief':
      'Bandingkan Flutter, React Native dan Kotlin Multiplatform untuk aplikasi chat. Tulis laporan dengan tabel kelebihan/kekurangan.',
  'profile': profile,
  'status': status,
  'createdAt': _ms(started),
  'startedAt': _ms(started),
  'finishedAt': ?(finished == null ? null : _ms(finished)),
  'currentTool': tool,
  'currentArgs': args,
  'toolCalls': tools,
  'queue': queue,
  'inputTokens': 12000,
  'outputTokens': 3400,
  'credits': credits,
  'report': report,
  'error': error,
  'stopReason': stopReason,
  'stopCode': stopCode,
};

final sampleTools = [
  {
    'id': 't1',
    'name': 'web_search',
    'args': 'flutter vs react native 2026',
    'output': '1. Flutter 4 ... 2. React Native 0.82 ...',
    'status': 'done',
    'startedAt': _ms(const Duration(seconds: 70)),
    'finishedAt': _ms(const Duration(seconds: 66)),
  },
  {
    'id': 't2',
    'name': 'read',
    'args': 'lib/ui/chat_screen.dart',
    'output': "import 'package:flutter/material.dart';\nclass ChatScreen extends StatefulWidget {",
    'status': 'done',
    'startedAt': _ms(const Duration(seconds: 60)),
    'finishedAt': _ms(const Duration(seconds: 59)),
  },
  {
    'id': 't3',
    'name': 'bash',
    'args': 'rm -rf build && flutter build apk --release --split-per-abi --target-platform android-arm64',
    'output': 'Error: no Android SDK found',
    'status': 'failed',
    'startedAt': _ms(const Duration(seconds: 50)),
    'finishedAt': _ms(const Duration(seconds: 48)),
  },
  {
    'id': 't4',
    'name': 'web_fetch',
    'args': 'https://docs.flutter.dev/perf/rendering-performance',
    'output': '',
    'status': 'running',
    'startedAt': _ms(const Duration(seconds: 5)),
  },
];

const report =
    '## Ringkasan\n\n**Flutter** unggul untuk UI kustom.\n\n| Framework | Kelebihan |\n|---|---|\n| Flutter | Satu codebase |\n| RN | Ekosistem JS |\n\n- Poin satu\n- Poin dua';

/// An agent whose store holds one subagent of every status, for chat-1.
AgentController agentWithSubagents() {
  pinClock();
  final agent = newAgent();
  agent.sessionFile = 'chat-1.jsonl';
  final store = agent.subagentStore;
  void start(Map<String, dynamic> r) => store.applyRecord({'type': 'subagent_started', 'subagent': r});
  void finish(Map<String, dynamic> r) => store.applyRecord({'type': 'subagent_finished', 'subagent': r});

  start(
    subRecord(
      'a-running',
      toolCallId: 'call-a',
      tool: 'read',
      args: 'lib/ui/chat_screen.dart',
      credits: 0.06,
      tools: sampleTools,
      queue: [
        {'id': 'q1', 'text': 'Tambahkan juga perbandingan ukuran APK.', 'at': _ms(const Duration(seconds: 10))},
        {'id': 'q2', 'text': 'Fokus ke performa scroll list panjang.', 'at': _ms(const Duration(seconds: 4))},
      ],
    ),
  );
  start(subRecord('b-approval', profile: 'full', tool: 'bash', args: 'rm -rf build && flutter build apk', credits: 0.02));
  store.applyRecord({
    'type': 'subagent_approval_request',
    'subagentId': 'b-approval',
    'approvalId': 'ap1',
    'toolName': 'bash',
    'summary': 'rm -rf build && flutter build apk --release',
    'reason': 'This command can delete data, publish or reach other machines',
    'key': 'bash:rm -rf build',
  });
  start(subRecord('c-queued', status: 'queued', started: Duration.zero));
  store['c-queued']!.startedAt = null;
  start(subRecord('g-stopping', status: 'stopping', tool: 'bash', args: 'npm test', credits: 0.3, tools: sampleTools.take(2).toList()));
  final done = subRecord(
    'd-done',
    status: 'done',
    started: const Duration(minutes: 3, seconds: 20),
    finished: const Duration(seconds: 30),
    credits: 0.14,
    tools: sampleTools.take(2).toList(),
    report: report,
  );
  start(done);
  finish(done);
  final failed = subRecord(
    'e-failed',
    status: 'failed',
    started: const Duration(seconds: 40),
    finished: const Duration(seconds: 20),
    error: '429 Too Many Requests: rate limit exceeded for model claude-sonnet-5.5',
  );
  start(failed);
  finish(failed);
  final stopped = subRecord(
    'f-stopped',
    status: 'stopped',
    started: const Duration(minutes: 31),
    finished: const Duration(seconds: 50),
    credits: 50.4,
    stopReason: 'The subagent cost limit was reached (50 credits).',
    stopCode: 'credit',
    report: 'Laporan parsial: baru membandingkan **dua** framework.',
    tools: sampleTools.take(1).toList(),
  );
  start(stopped);
  finish(stopped);
  return agent;
}

/// Runs animations to their end (indeterminate progress bars never settle, so no pumpAndSettle).
Future<void> frames(WidgetTester tester, [int n = 12]) async {
  for (var i = 0; i < n; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<void> expectClean(WidgetTester tester) async {
  final errors = layoutErrors.toList();
  layoutErrors.clear();
  expect(errors, isEmpty, reason: 'layout errors: $errors');
  // No button, chip or settings row text may be cut off.
  final clipped = <String>[];
  final owners = find.byWidgetPredicate((w) => w is ButtonStyleButton || w is ChoiceChip || w is SettingsRow);
  for (final el in find.descendant(of: owners, matching: find.byType(RichText)).evaluate()) {
    final ro = el.renderObject;
    if (ro is RenderParagraph && ro.didExceedMaxLines) clipped.add(ro.text.toPlainText());
  }
  expect(clipped, isEmpty, reason: 'clipped labels: $clipped');
}

void main() {
  setUpAll(loadAppFonts);
  late FakeHost host;
  setUp(() {
    host = FakeHost();
    layoutErrors.clear();
  });

  Future<AgentController> settingsAgent(WidgetTester tester, Look look, {Map<String, dynamic> stored = const {}}) async {
    host.stored.addAll(stored);
    final agent = newAgent();
    agent.integrations.settings = AppSettings(host.publicSettings());
    await pumpLook(tester, look, SubagentSettingsScreen(agent: agent), height: 1500);
    // initState refreshes settings from the host.
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 300));
    return agent;
  }

  group('settings screen', () {
    for (final look in looks) {
      testWidgets('default ${look.name}', (tester) async {
        await settingsAgent(tester, look);
        await expectClean(tester);
        await expectLater(find.byType(SubagentSettingsScreen), matchesGoldenFile(golden('settings_default_${look.name}')));
      });
    }

    testWidgets('custom values, own approval mode (bypass), custom field open', (tester) async {
      await settingsAgent(
        tester,
        const Look(),
        stored: {'subagentCreditLimit': 37.5, 'subagentMinutesLimit': 45, 'subagentApprovalMode': 'auto'},
      );
      await tester.tap(find.textContaining('Custom').first);
      await frames(tester);
      expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, '37.5');
      await expectClean(tester);
      await expectLater(find.byType(SubagentSettingsScreen), matchesGoldenFile(golden('settings_custom_open')));
    });

    testWidgets('no limits, custom field with an inline error', (tester) async {
      await settingsAgent(
        tester,
        const Look(dark: true, language: 'id'),
        stored: {'subagentCreditLimit': 0, 'subagentMinutesLimit': 0},
      );
      await tester.tap(find.text('Kustom').last);
      await frames(tester);
      await tester.enterText(find.byType(TextField), '2,5');
      await tester.tap(find.text('Pakai'));
      await frames(tester);
      expect(find.text('Masukkan jumlah menit bulat, 1 atau lebih.'), findsOneWidget);
      await expectClean(tester);
      await expectLater(find.byType(SubagentSettingsScreen), matchesGoldenFile(golden('settings_error_inline')));
    });
  });

  group('approvals section', () {
    /// Renders only the Approvals part of the screen, and returns its height.
    Future<double> approvals(WidgetTester tester, Look look, String name, {Map<String, dynamic> stored = const {}}) async {
      await settingsAgent(tester, look, stored: stored);
      await frames(tester);
      await expectClean(tester);
      final top = tester.getTopLeft(find.text(look.language == 'id' ? 'PERSETUJUAN' : 'APPROVALS')).dy - 8;
      final bottom = tester.getTopLeft(find.text(look.language == 'id' ? 'NOTIFIKASI' : 'NOTIFICATIONS')).dy - 8;
      await expectLater(
        find.byType(SubagentSettingsScreen),
        matchesGoldenFile(golden('approvals_$name')),
      );
      return bottom - top;
    }

    testWidgets('follow / own / bypass, wide and narrow', (tester) async {
      final follow = await approvals(tester, const Look(), 'follow');
      final own = await approvals(tester, const Look(), 'own', stored: {'subagentApprovalMode': 'ask_all'});
      final bypass = await approvals(tester, const Look(), 'bypass', stored: {'subagentApprovalMode': 'auto'});
      host.stored.clear();
      final narrow = await approvals(
        tester,
        const Look(language: 'id', textScale: 1.3, width: 320),
        'own_narrow',
        stored: {'subagentApprovalMode': 'ask_risky'},
      );
      // ignore: avoid_print
      print('APPROVALS heights follow=$follow own=$own bypass=$bypass narrow=$narrow');
      expect(own, greaterThan(follow));
      expect(bypass, greaterThan(own));
    });

    testWidgets('switching back to the chat leaves no gap', (tester) async {
      final before = await approvals(tester, const Look(), 'follow_before');
      host.stored['subagentApprovalMode'] = 'ask_all';
      // Each switch waits for the host's answer (the row spins and takes no tap until then), which only arrives with
      // real async: without it the second tap would land while the first is still being saved.
      Future<void> answered() async {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
        await frames(tester, 20);
      }

      await tester.tap(find.text('Same as the chat')); // off: own mode
      await answered();
      expect(host.stored.containsKey('subagentApprovalMode'), isTrue, reason: 'own mode saved');
      await tester.tap(find.text('Same as the chat')); // on again
      await answered();
      expect(host.stored.containsKey('subagentApprovalMode'), isFalse, reason: 'following the chat again');
      await expectClean(tester);
      final top = tester.getTopLeft(find.text('APPROVALS')).dy - 8;
      final after = tester.getTopLeft(find.text('NOTIFICATIONS')).dy - 8 - top;
      // ignore: avoid_print
      print('APPROVALS roundtrip before=$before after=$after');
      expect(after, before);
      await expectLater(find.byType(SubagentSettingsScreen), matchesGoldenFile(golden('approvals_follow_after')));
    });
  });

  group('cards', () {
    for (final look in looks) {
      testWidgets('all statuses ${look.name}', (tester) async {
        final agent = agentWithSubagents();
        await pumpLook(
          tester,
          look,
          Scaffold(
            body: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                for (final s in agent.subagentsForCurrent)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 14),
                    child: SubagentCard(state: s, agent: agent),
                  ),
              ],
            ),
          ),
          height: 2000,
        );
        await expectClean(tester);
        await expectLater(find.byType(Scaffold), matchesGoldenFile(golden('cards_${look.name}')));
      });
    }
  });

  group('transcript', () {
    testWidgets('card sits at its subagent call, between the text before and after', (tester) async {
      final agent = agentWithSubagents();
      agent.addHistoryMessage({'role': 'user', 'content': 'Bandingkan framework UI untuk aplikasi chat.'});
      agent.addHistoryMessage({
        'role': 'assistant',
        'content': [
          {'type': 'text', 'text': 'Saya serahkan riset ini ke subagent.'},
          {'type': 'toolCall', 'id': 'call-a', 'name': 'subagent', 'arguments': {'task': 'Bandingkan…'}},
          {'type': 'text', 'text': 'Sambil menunggu, saya cek struktur proyek.'},
        ],
      });
      await pumpLook(
        tester,
        const Look(),
        Scaffold(
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              for (final e in agent.entries)
                Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: switch (e) {
                    UserEntry() => UserMessageView(e),
                    AssistantEntry() => AssistantMessageView(
                      e,
                      tools: agent.tools,
                      subagentCard: placeSubagents(agent).cardFor,
                    ),
                    _ => const SizedBox.shrink(),
                  },
                ),
            ],
          ),
        ),
        height: 700,
      );
      await expectClean(tester);
      await expectLater(find.byType(Scaffold), matchesGoldenFile(golden('transcript_inline')));
    });
  });

  group('sheet', () {
    for (final id in ['a-running', 'b-approval', 'c-queued', 'g-stopping', 'd-done', 'f-stopped', 'e-failed']) {
      for (final look in [const Look(), const Look(dark: true, language: 'id')]) {
        testWidgets('$id ${look.name}', (tester) async {
          final agent = agentWithSubagents();
          await pumpLook(
            tester,
            look,
            Scaffold(body: _asSheet(SubagentSheet(state: agent.subagentStore[id]!, agent: agent))),
            height: 1700,
          );
          await expectClean(tester);
          await expectLater(find.byType(Scaffold), matchesGoldenFile(golden('sheet_${id}_${look.name}')));
        });
      }
    }

    testWidgets('narrow, large text', (tester) async {
      final agent = agentWithSubagents();
      await pumpLook(
        tester,
        const Look(language: 'id', textScale: 1.3, width: 320),
        Scaffold(body: _asSheet(SubagentSheet(state: agent.subagentStore['b-approval']!, agent: agent))),
        height: 1900,
      );
      await expectClean(tester);
      await expectLater(find.byType(Scaffold), matchesGoldenFile(golden('sheet_b-approval_narrow')));
    });

    testWidgets('tool rows expanded, message typed', (tester) async {
      final agent = agentWithSubagents();
      await pumpLook(
        tester,
        const Look(),
        Scaffold(body: SubagentSheet(state: agent.subagentStore['a-running']!, agent: agent)),
        height: 1700,
      );
      await tester.tap(find.text('flutter vs react native 2026'));
      await tester.tap(find.text('rm -rf build && flutter build apk --release --split-per-abi --target-platform android-arm64'));
      await tester.enterText(find.byType(TextField), 'Sertakan juga Compose Multiplatform.');
      await frames(tester);
      await expectClean(tester);
      await expectLater(find.byType(Scaffold), matchesGoldenFile(golden('sheet_tools_expanded')));
    });

    testWidgets('force stop dialog', (tester) async {
      final agent = agentWithSubagents();
      await pumpLook(
        tester,
        const Look(),
        Scaffold(body: SubagentSheet(state: agent.subagentStore['a-running']!, agent: agent)),
        height: 1700,
      );
      await tester.tap(find.widgetWithText(OutlinedButton, 'Force stop'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.byType(AlertDialog), findsOneWidget);
      await expectLater(find.byType(AlertDialog), matchesGoldenFile(golden('dialog_force_stop')));
    });
  });

  group('banner', () {
    Future<AgentController> bannerAgent(List<(String, String, String)> subs) async {
      final agent = newAgent();
      agent.sessionFile = 'open.jsonl';
      for (final (id, parent, title) in subs) {
        agent.subagentStore.applyRecord({'type': 'subagent_started', 'subagent': subRecord(id, parent: parent, title: title)});
      }
      return agent;
    }

    testWidgets('one chat', (tester) async {
      final agent = await bannerAgent([('x0', 'other0.jsonl', 'Riset framework UI')]);
      await pumpLook(tester, const Look(language: 'id', width: 320), Scaffold(body: Column(children: [CrossChatBanner(agent: agent)])), height: 160);
      await expectClean(tester);
      await expectLater(find.byType(Scaffold), matchesGoldenFile(golden('banner_1')));
    });

    testWidgets('several chats, one needs approval', (tester) async {
      final agent = await bannerAgent([
        ('x0', 'other0.jsonl', 'Riset framework UI'),
        ('x1', 'other1.jsonl', 'Perbaiki CI'),
        ('x2', 'other1.jsonl', 'Perbaiki CI'),
      ]);
      agent.subagentStore.applyRecord({
        'type': 'subagent_approval_request',
        'subagentId': 'x1',
        'approvalId': 'a',
        'toolName': 'bash',
        'summary': 'git push',
        'reason': 'r',
        'key': 'k',
      });
      await pumpLook(tester, const Look(width: 320), Scaffold(body: Column(children: [CrossChatBanner(agent: agent)])), height: 160);
      await expectClean(tester);
      await expectLater(find.byType(Scaffold), matchesGoldenFile(golden('banner_3')));
    });

    testWidgets('picker for several chats', (tester) async {
      final agent = await bannerAgent([
        ('x0', 'other0.jsonl', 'Riset framework UI'),
        ('x1', 'other1.jsonl', 'Perbaiki CI'),
        ('x2', 'other1.jsonl', 'Perbaiki CI'),
      ]);
      await pumpLook(tester, const Look(), Scaffold(body: Column(children: [CrossChatBanner(agent: agent)])), height: 700);
      await tester.tap(find.byType(CrossChatBanner));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      await expectClean(tester);
      await expectLater(find.byType(MaterialApp), matchesGoldenFile(golden('banner_picker')));
    });
  });
}

/// The sheet as the app shows it: a bottom sheet surface with its drag handle.
Widget _asSheet(Widget child) => Builder(
  builder: (context) => BottomSheet(
    onClosing: () {},
    enableDrag: false,
    showDragHandle: true,
    builder: (_) => child,
  ),
);
