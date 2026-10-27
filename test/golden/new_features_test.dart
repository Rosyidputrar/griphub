// Widget tests and goldens for the features added together: swipe to remove
// finished runs, the Repos sheet for clones (pull / switch branch), the
// expired GitHub sign-in, long pastes as attachments, and the per-turn cost
// footer. The fake host answers like the real one (agent/src).
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:griphub_agent/agent/agent_controller.dart';
import 'package:griphub_agent/agent/drafts.dart';
import 'package:griphub_agent/agent/integrations.dart';
import 'package:griphub_agent/agent/models.dart';
import 'package:griphub_agent/ui/message_views.dart';
import 'package:griphub_agent/ui/chat_screen.dart';
import 'package:griphub_agent/ui/repos_screen.dart';
import 'package:griphub_agent/ui/tasks_screen.dart';

import 'harness.dart';

int _ago(int minutes) => goldenNow.subtract(Duration(minutes: minutes)).millisecondsSinceEpoch;

Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// The host's run list, mutated like agent/src/runs.ts (delete refuses active runs; restore puts back once).
class FakeRuns {
  FakeRuns(this.host) {
    host.answers['runs'] = (_) => summary();
    host.answers['run_delete'] = (cmd) {
      final i = runs.indexWhere((r) => r['id'] == cmd['runId']);
      if (i < 0) return {...summary(), 'removed': null};
      final run = runs.removeAt(i);
      return {...summary(), 'removed': {'run': run, 'index': i}};
    };
    host.answers['run_restore'] = (cmd) {
      final run = (cmd['run'] as Map).cast<String, dynamic>();
      if (!runs.any((r) => r['id'] == run['id'])) runs.insert((cmd['index'] as int).clamp(0, runs.length), run);
      return summary();
    };
  }
  final FakeHost host;
  final runs = <Map<String, dynamic>>[
    {'id': 'r1', 'title': 'Perbaiki CSS', 'prompt': 'p', 'cwd': '/w/site', 'status': 'done', 'source': 'queue', 'createdAt': _ago(42), 'finishedAt': _ago(35), 'summary': 'Selesai.'},
    {'id': 'r2', 'title': 'Riset saham', 'prompt': 'p', 'cwd': '/w', 'status': 'running', 'source': 'queue', 'createdAt': _ago(8), 'startedAt': _ago(8)},
    {'id': 'r3', 'title': 'Deploy', 'prompt': 'p', 'cwd': '/w', 'status': 'error', 'source': 'queue', 'createdAt': _ago(90), 'finishedAt': _ago(88), 'summary': 'Gagal.'},
  ];
  Map<String, dynamic> summary() => {'runs': runs, 'schedules': const [], 'concurrency': 1, 'running': 1, 'keepAlive': true};
}

void main() {
  setUpAll(loadAppFonts);
  late FakeHost host;
  setUp(() => applyLook(const Look()));

  group('tasks: swipe to remove', () {
    testWidgets('a finished run swipes away, Undo brings it back in place', (tester) async {
      host = FakeHost(); // inside the fake-async zone, or replies never arrive
      final fake = FakeRuns(host);
      final agent = newAgent();
      await pumpLook(tester, const Look(), TasksScreen(agent: agent), height: 1400);
      await settle(tester);
      expect(find.text('Perbaiki CSS'), findsOneWidget);

      await tester.drag(find.text('Perbaiki CSS'), const Offset(-500, 0));
      await settle(tester);
      expect(find.text('Perbaiki CSS'), findsNothing);
      expect(host.sent('run_delete').single['runId'], 'r1');
      expect(fake.runs.map((r) => r['id']), ['r2', 'r3']);
      expect(find.text('Run removed'), findsOneWidget);

      // Let the snackbar finish sliding in (it ignores taps until then).
      await tester.pump(const Duration(seconds: 1));
      await tester.tap(find.text('Undo'));
      await settle(tester);
      expect(fake.runs.map((r) => r['id']), ['r1', 'r2', 'r3']);
      expect(find.text('Perbaiki CSS'), findsOneWidget);
    });

    testWidgets('swiping the other way works too', (tester) async {
      host = FakeHost(); // inside the fake-async zone, or replies never arrive
      FakeRuns(host);
      await pumpLook(tester, const Look(), TasksScreen(agent: newAgent()), height: 1400);
      await settle(tester);
      await tester.drag(find.text('Deploy'), const Offset(500, 0));
      await settle(tester);
      expect(find.text('Deploy'), findsNothing);
      expect(host.sent('run_delete').single['runId'], 'r3');
    });

    testWidgets('a running run does not swipe away', (tester) async {
      host = FakeHost(); // inside the fake-async zone, or replies never arrive
      FakeRuns(host);
      await pumpLook(tester, const Look(), TasksScreen(agent: newAgent()), height: 1400);
      await settle(tester);
      await tester.drag(find.text('Riset saham'), const Offset(-500, 0));
      await settle(tester);
      expect(find.text('Riset saham'), findsOneWidget);
      expect(host.sent('run_delete'), isEmpty);
    });

    for (final look in const [Look(), Look(dark: true, language: 'id')]) {
      testWidgets('golden: swipe background ${look.name}', (tester) async {
      host = FakeHost(); // inside the fake-async zone, or replies never arrive
        FakeRuns(host);
        await pumpLook(tester, look, TasksScreen(agent: newAgent()), height: 1400);
        await settle(tester);
        final gesture = await tester.startGesture(tester.getCenter(find.text('Perbaiki CSS')));
        for (var i = 0; i < 8; i++) {
          await gesture.moveBy(const Offset(-20, 0));
          await tester.pump(const Duration(milliseconds: 16));
        }
        await expectLater(find.byType(TasksScreen), matchesGoldenFile(golden('tasks_swipe_${look.name}')));
        await gesture.cancel();
      });
    }
  });

  group('repos: a clone opens pull / switch branch', () {
    RepoInfo repo({bool cloned = true}) => RepoInfo({
      'fullName': 'akun2/repo1',
      'name': 'repo1',
      'private': true,
      'cloned': cloned,
      'path': cloned ? '/w/repo1-akun2' : null,
      'defaultBranch': 'main',
    });

    Map<String, dynamic> status({int behind = 0, String? upstream = 'origin/main', bool dirty = false}) => {
      'repo': true,
      'branch': 'main',
      'upstream': upstream,
      'ahead': 0,
      'behind': behind,
      'remote': 'https://github.com/akun2/repo1.git',
      'files': dirty
          ? [
              {'path': 'a.txt', 'code': ' M'},
            ]
          : const [],
    };

    Future<AgentController> open(WidgetTester tester, Look look, {required Map<String, dynamic> fetched}) async {
      host.answers['git_status'] = (_) => status();
      host.answers['git_fetch'] = (_) => fetched;
      final agent = newAgent();
      await pumpLook(
        tester,
        look,
        Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: FilledButton(
                onPressed: () => showModalBottomSheet<bool>(
                  context: context,
                  isScrollControlled: true,
                  builder: (_) => RepoActionsSheet(repo: repo(), dir: '/w/repo1-akun2', features: agent.features),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await settle(tester);
      return agent;
    }

    testWidgets('fetches the clone first and shows how far behind it is', (tester) async {
      host = FakeHost(); // inside the fake-async zone, or replies never arrive
      await open(tester, const Look(), fetched: status(behind: 3));
      expect(host.sent('git_fetch').single['dir'], '/w/repo1-akun2');
      expect(find.text('3 new commits'), findsOneWidget);
      expect(find.text('Folder: repo1-akun2  ·  main'), findsOneWidget);
    });

    testWidgets('pull runs in the clone\'s folder', (tester) async {
      host = FakeHost(); // inside the fake-async zone, or replies never arrive
      host.answers['git_pull'] = (_) => null;
      await open(tester, const Look(), fetched: status(behind: 1));
      await tester.tap(find.text('Pull latest changes'));
      await settle(tester);
      expect(host.sent('git_pull').single['dir'], '/w/repo1-akun2');
    });

    testWidgets('a branch without upstream can\'t be pulled, and says why', (tester) async {
      host = FakeHost(); // inside the fake-async zone, or replies never arrive
      await open(tester, const Look(), fetched: status(upstream: null));
      expect(find.text('This branch has no remote to pull from'), findsOneWidget);
      await tester.tap(find.text('Pull latest changes'));
      await settle(tester);
      expect(host.sent('git_pull'), isEmpty);
    });

    testWidgets('switch branch lists branches of the clone, not of the open chat', (tester) async {
      host = FakeHost(); // inside the fake-async zone, or replies never arrive
      host.answers['git_branches'] = (cmd) => [
        {'name': 'main', 'current': true, 'remote': false},
        {'name': 'origin/fitur-baru', 'current': false, 'remote': true},
      ];
      host.answers['git_checkout'] = (cmd) => status();
      await open(tester, const Look(), fetched: status());
      await tester.tap(find.text('Switch branch'));
      await settle(tester);
      expect(host.sent('git_branches').single['dir'], '/w/repo1-akun2');
      await tester.tap(find.text('origin/fitur-baru'));
      await settle(tester);
      final co = host.sent('git_checkout').single;
      expect(co['branch'], 'fitur-baru');
      expect(co['dir'], '/w/repo1-akun2');
    });

    testWidgets('offline: the local status still shows', (tester) async {
      host = FakeHost(); // inside the fake-async zone, or replies never arrive
      host.answers['git_status'] = (_) => status(behind: 0, dirty: true);
      host.answers['git_fetch'] = (_) => const HostError('Could not resolve host: github.com');
      final agent = newAgent();
      await pumpLook(
        tester,
        const Look(),
        Scaffold(body: RepoActionsSheet(repo: repo(), dir: '/w/repo1-akun2', features: agent.features)),
      );
      await settle(tester);
      expect(find.textContaining('uncommitted changes'), findsOneWidget);
    });

    for (final look in const [Look(), Look(dark: true, language: 'id'), Look(language: 'id', textScale: 1.3, width: 320)]) {
      testWidgets('golden: repo actions ${look.name}', (tester) async {
      host = FakeHost(); // inside the fake-async zone, or replies never arrive
        await open(tester, look, fetched: status(behind: 2, dirty: true));
        await expectLater(find.byType(MaterialApp), matchesGoldenFile(golden('repo_actions_${look.name}')));
      });
    }
  });

  group('chat: long pastes become attachments', () {
    final paste = List.generate(40, (i) => '2026-10-27 16:${(i % 60).toString().padLeft(2, '0')} ERROR job $i failed').join('\n');

    Future<void> pumpChat(WidgetTester tester, Look look) async {
      Drafts.root = Directory.systemTemp.createTempSync('drafts-').path;
      await pumpLook(tester, look, ChatScreen(agent: newAgent()));
      await settle(tester);
    }

    Finder composer() => find.byType(TextField).last;

    testWidgets('a long paste lands as "Pasted content", the field stays as typed', (tester) async {
      host = FakeHost(); // inside the fake-async zone, or replies never arrive
      await pumpChat(tester, const Look());
      await tester.enterText(composer(), 'Kenapa error ini?');
      await tester.enterText(composer(), 'Kenapa error ini?$paste');
      await settle(tester);
      expect(tester.widget<TextField>(composer()).controller!.text, 'Kenapa error ini?');
      expect(find.text('Pasted content'), findsOneWidget);
      // Nothing pops over the composer.
      expect(find.byType(SnackBar), findsNothing);
    });

    testWidgets('tapping the paste previews it; "Paste as text" puts it in the field instead', (tester) async {
      host = FakeHost(); // inside the fake-async zone, or replies never arrive
      await pumpChat(tester, const Look());
      await tester.enterText(composer(), 'Lihat: ');
      await tester.enterText(composer(), 'Lihat: $paste');
      await settle(tester);
      await tester.tap(find.text('Pasted content'));
      await settle(tester);
      expect(find.text('40 lines · 1 KB'), findsOneWidget);
      await tester.tap(find.text('Paste as text'));
      await settle(tester);
      expect(find.text('Pasted content'), findsNothing);
      expect(tester.widget<TextField>(composer()).controller!.text, 'Lihat: $paste');
    });

    testWidgets('closing the preview keeps the paste attached', (tester) async {
      host = FakeHost(); // inside the fake-async zone, or replies never arrive
      await pumpChat(tester, const Look());
      await tester.enterText(composer(), paste);
      await settle(tester);
      await tester.tap(find.text('Pasted content'));
      await settle(tester);
      await tester.tapAt(const Offset(20, 20));
      await settle(tester);
      expect(find.text('Pasted content'), findsOneWidget);
      expect(tester.widget<TextField>(composer()).controller!.text, '');
    });

    testWidgets('a short paste stays text', (tester) async {
      host = FakeHost(); // inside the fake-async zone, or replies never arrive
      await pumpChat(tester, const Look());
      await tester.enterText(composer(), 'npm ERR! code ERESOLVE');
      await settle(tester);
      expect(find.text('Pasted content'), findsNothing);
      expect(tester.widget<TextField>(composer()).controller!.text, 'npm ERR! code ERESOLVE');
    });

    for (final look in const [Look(), Look(dark: true, language: 'id')]) {
      testWidgets('golden: composer with a paste ${look.name}', (tester) async {
        host = FakeHost(); // inside the fake-async zone, or replies never arrive
        await pumpChat(tester, look);
        await tester.enterText(composer(), paste);
        await settle(tester);
        await expectLater(find.byType(ChatScreen), matchesGoldenFile(golden('composer_paste_${look.name}')));
        await tester.tap(find.text(look.language == 'id' ? 'Konten yang ditempel' : 'Pasted content').first);
        await settle(tester);
        await expectLater(find.byType(MaterialApp), matchesGoldenFile(golden('paste_preview_${look.name}')));
      });
    }
  });

  group('chat: what a turn cost', () {
    /// A finished assistant message as the host sends it (message_end / messages), with its usage and estimate.
    AssistantEntry reply(
      String? text, {
      int input = 0,
      int output = 0,
      int cacheRead = 0,
      double? credits,
      bool floored = false,
      bool withCost = true,
      String? subagentCall,
      String model = 'deepseek-v4-flash',
    }) => AssistantEntry()
      ..applyMessage({
        'role': 'assistant',
        'model': model,
        'stopReason': 'stop',
        'content': [
          if (text != null) {'type': 'text', 'text': text},
          if (subagentCall != null) {'type': 'toolCall', 'id': subagentCall, 'name': 'subagent', 'arguments': {'task': 'riset'}},
        ],
        'usage': {'input': input, 'output': output, 'cacheRead': cacheRead, 'cacheWrite': 0, 'totalTokens': input + output + cacheRead},
        if (withCost) 'griphubCost': {'credits': credits, 'floored': floored},
      });

    final turn = <ChatEntry>[
      UserEntry('riset saham'),
      reply(null, input: 2000, output: 300, cacheRead: 40000, credits: 0.0127, subagentCall: 'call-sub'),
      reply(null, input: 900, output: 100, credits: 0.01, floored: true),
      reply('Ini laporannya.', input: 1200, output: 2400, cacheRead: 45000, credits: 0.0146),
    ];

    test('every request of the turn adds up; subagents are listed apart', () {
      final cost = turnFooters(turn, busy: false)[3]!.cost!;
      expect(cost.requests, 3);
      expect(cost.floored, 1);
      expect(cost.tokens, 2000 + 300 + 40000 + 900 + 100 + 1200 + 2400 + 45000);
      expect(cost.cached, 85000);
      expect(cost.credits, closeTo(0.0373, 1e-9));
      expect(cost.subagentCalls, ['call-sub']);
    });

    test('one request without a price makes the total unknown, tokens still count', () {
      final cost = turnFooters([
        UserEntry('a'),
        reply(null, input: 10, output: 5, credits: 0.1),
        reply('b', input: 10, output: 5, credits: null),
      ], busy: false)[2]!.cost!;
      expect(cost.credits, isNull);
      expect(cost.tokens, 30);
    });

    test('an older host without estimates: tokens only; no usage at all: no cost', () {
      expect(turnFooters([UserEntry('a'), reply('b', input: 7, output: 3, withCost: false)], busy: false)[1]!.cost!.credits, isNull);
      final bare = AssistantEntry()
        ..applyMessage({'role': 'assistant', 'model': 'm', 'stopReason': 'stop', 'content': [{'type': 'text', 'text': 'x'}]});
      expect(turnFooters([UserEntry('a'), bare], busy: false)[1]!.cost, isNull);
    });

    test('turns are counted separately', () {
      final two = [...turn, UserEntry('lanjut'), reply('Oke.', input: 100, output: 10, credits: 0.002)];
      final f = turnFooters(two, busy: false);
      expect(f[5]!.cost!.requests, 1);
      expect(f[5]!.cost!.credits, 0.002);
    });

    Widget view(List<ChatEntry> entries, {double? subagentCredits = 0.208}) {
      final footers = turnFooters(entries, busy: false);
      final last = entries.length - 1;
      return Scaffold(
        body: Padding(
          padding: const EdgeInsets.all(16),
          child: AssistantMessageView(
            entries[last] as AssistantEntry,
            tools: const {},
            modelLabel: (id) => id == 'deepseek-v4-flash' ? 'DeepSeek V4 Flash' : id,
            subagentCost: (id) => id == 'call-sub' ? (credits: subagentCredits) : null,
            footer: footers[last],
          ),
        ),
      );
    }

    testWidgets('the footer shows tokens, credits and the subagent apart', (tester) async {
      host = FakeHost(); // inside the fake-async zone, or replies never arrive
      await pumpLook(tester, const Look(), view(turn));
      expect(find.text('92k tokens · ~0.037 credits · (+0.208 subagent)'), findsOneWidget);
      await tester.tap(find.text('DeepSeek V4 Flash · '));
      await settle(tester);
      expect(find.text('3 (1 at the minimum)'), findsOneWidget);
      expect(find.text('92k (92% cache)'), findsOneWidget);
      expect(find.text('~0.037 credits · Rp 11'), findsOneWidget);
      expect(find.text('~0.208 credits · Rp 62'), findsOneWidget);
    });

    testWidgets('an unknown price shows tokens only, and the sheet says why', (tester) async {
      host = FakeHost(); // inside the fake-async zone, or replies never arrive
      await pumpLook(tester, const Look(), view([UserEntry('a'), reply('b', input: 1200, output: 300, credits: null, model: 'my-llm')]));
      expect(find.text('2k tokens'), findsOneWidget);
      await tester.tap(find.text('my-llm · '));
      await settle(tester);
      expect(find.text('No GripHub price is known for this model, so only its tokens are shown.'), findsOneWidget);
    });

    for (final look in const [Look(), Look(dark: true, language: 'id'), Look(language: 'id', textScale: 1.3, width: 320)]) {
      testWidgets('golden: turn cost footer and sheet ${look.name}', (tester) async {
        host = FakeHost(); // inside the fake-async zone, or replies never arrive
        await pumpLook(tester, look, view(turn));
        expect(layoutErrors.where((e) => e.contains(look.name)), isEmpty, reason: 'nothing overflows');
        await expectLater(find.byType(AssistantMessageView), matchesGoldenFile(golden('turn_cost_footer_${look.name}')));
        await tester.tap(find.byType(GestureDetector).last);
        await settle(tester);
        await expectLater(find.byType(MaterialApp), matchesGoldenFile(golden('turn_cost_sheet_${look.name}')));
      });
    }
  });
}
