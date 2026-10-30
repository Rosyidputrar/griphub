// Loading states: every action that waits on the host shows that it does, takes no second tap meanwhile, and never
// shows what belongs to the previous state (a folder, a period) under the new one. With goldens of the new busy
// looks, in light and dark, English and Indonesian, and on a narrow phone with large text.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:griphub_agent/agent/agent_client.dart';
import 'package:griphub_agent/agent/agent_controller.dart';
import 'package:griphub_agent/agent/agent_fs.dart';
import 'package:griphub_agent/agent/drafts.dart';
import 'package:griphub_agent/agent/models.dart';
import 'package:griphub_agent/ui/chat_extras.dart';
import 'package:griphub_agent/ui/chat_screen.dart';
import 'package:griphub_agent/ui/files_screen.dart';
import 'package:griphub_agent/ui/message_views.dart';
import 'package:griphub_agent/ui/model_sheet.dart';
import 'package:griphub_agent/ui/tasks_screen.dart';
import 'package:griphub_agent/ui/usage_screen.dart';

import 'harness.dart';

const _looks = [Look(), Look(dark: true, language: 'id'), Look(language: 'id', textScale: 1.3, width: 320)];

Future<void> frames(WidgetTester tester, [int n = 8]) async {
  for (var i = 0; i < n; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// The phone's own files, except that listing the folders in [slow] waits until the test lets it finish.
class _SlowFs extends LocalFs {
  _SlowFs(this.slow);
  final Set<String> slow;
  final waiting = <String, Completer<void>>{};

  @override
  Future<List<FsEntry>> list(String path, {bool detectGit = false}) async {
    if (slow.contains(path)) await (waiting[path] = Completer<void>()).future;
    return super.list(path, detectGit: detectGit);
  }
}

ModelInfo _model(String id, {String? name}) =>
    ModelInfo({'provider': 'griphub', 'id': id, 'name': name ?? id, 'input': const ['text']});

void main() {
  setUpAll(loadAppFonts);
  setUp(() {
    applyLook(const Look());
    layoutErrors.clear();
  });

  group('switching chats', () {
    testWidgets('a second switch while one is under way does nothing; the first one is shown as opening', (tester) async {
      final host = FakeHost(); // inside the fake-async zone, or replies never arrive
      final late = Completer<Object?>();
      host.answers['open_session'] = (cmd) => late.future;
      final agent = newAgent();
      await tester.pump();
      agent.sessionFile = 'a.jsonl';

      bool? first;
      bool? second;
      bool? fresh;
      agent.openSession('b.jsonl').then((v) => first = v);
      agent.openSession('c.jsonl').then((v) => second = v);
      agent.newSession().then((v) => fresh = v);
      await frames(tester, 3);
      expect(second, isFalse, reason: 'refused at once');
      expect(fresh, isFalse, reason: 'a new chat waits too');
      expect(agent.switchingTo, 'b.jsonl', reason: 'the row being opened is known, for its spinner');
      expect(host.sent('open_session').map((c) => c['path']), ['b.jsonl']);
      expect(host.sent('new_session'), isEmpty);
      // Tapping the chat being opened again does not push it twice either.
      bool? again;
      agent.openSession('b.jsonl').then((v) => again = v);
      await frames(tester, 2);
      expect(again, isFalse);

      late.complete({'sessionFile': 'b.jsonl', 'sessionId': 'b'});
      await frames(tester, 4);
      expect(first, isTrue);
      expect(agent.switchingTo, isNull);
      expect(agent.sessionFile, 'b.jsonl');
    });

    testWidgets('Stop and switch covers the screen while it waits, and says so when the agent does not stop', (tester) async {
      final host = FakeHost();
      final agent = newAgent();
      AgentController.stopToSwitchTimeout = const Duration(milliseconds: 400);
      addTearDown(() => AgentController.stopToSwitchTimeout = const Duration(seconds: 10));
      await pumpLook(tester, const Look(), StopToSwitchOverlay(agent: agent, child: const Scaffold(body: SizedBox())));
      agent.sessionFile = 'a.jsonl';
      agent.busy = true;
      agent.confirmStopToSwitch = () async => true;
      final problems = <String>[];
      agent.switchProblems.stream.listen(problems.add);

      bool? switched;
      agent.openSession('b.jsonl').then((v) => switched = v);
      await frames(tester, 2);
      expect(host.sent('abort'), hasLength(1));
      expect(agent.stoppingToSwitch, isTrue);
      expect(find.text('Stopping the agent…'), findsOneWidget);

      // The turn never ends: after the wait the switch is called off, and the user is told.
      await frames(tester, 12);
      expect(switched, isFalse);
      expect(agent.stoppingToSwitch, isFalse);
      expect(find.text('Stopping the agent…'), findsNothing);
      expect(problems, ['The agent did not stop in time. Try again in a moment.']);
      expect(host.sent('open_session'), isEmpty);
    });

    for (final look in _looks) {
      testWidgets('golden: stopping to switch ${look.name}', (tester) async {
        FakeHost();
        final agent = newAgent();
        await pumpLook(
          tester,
          look,
          StopToSwitchOverlay(
            agent: agent,
            child: Scaffold(appBar: AppBar(title: const Text('GripHub')), body: const SizedBox()),
          ),
        );
        agent.busy = true;
        agent.confirmStopToSwitch = () async => true;
        unawaited(agent.openSession('b.jsonl'));
        await frames(tester, 3);
        expect(layoutErrors, isEmpty);
        await expectLater(find.byType(Scaffold), matchesGoldenFile(golden('stop_to_switch_${look.name}')));
        agent.busy = false;
        await frames(tester, 4);
      });
    }

    testWidgets('edit and fork run one at a time', (tester) async {
      final host = FakeHost();
      final late = Completer<Object?>();
      host.answers['edit_message'] = (_) => late.future;
      final agent = newAgent();
      await tester.pump();
      final first = agent.editMessage('e1');
      expect(agent.rewinding, 'e1');
      await expectLater(agent.forkAt('e2'), throwsA(isA<AgentError>()));
      expect(host.sent('fork_session'), isEmpty);
      late.complete({'text': 'hello'});
      await frames(tester, 4);
      expect(await first, 'hello');
      expect(agent.rewinding, isNull);
    });
  });

  group('files', () {
    testWidgets('opening a folder drops the old listing at once, and a late listing of a folder left behind is ignored',
        (tester) async {
      final root = Directory.systemTemp.createTempSync('files-busy-');
      addTearDown(() => root.deleteSync(recursive: true));
      Directory('${root.path}/slow').createSync();
      File('${root.path}/slow/inside.txt').writeAsStringSync('x');
      File('${root.path}/top.txt').writeAsStringSync('x');
      final fs = _SlowFs({'${root.path}/slow'});
      final agent = newAgent()..fs = fs;

      Future<void> settle() async {
        for (var i = 0; i < 6; i++) {
          await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
          await tester.pump(const Duration(milliseconds: 50));
        }
      }

      await pumpLook(tester, const Look(), FilesScreen(agent: agent, root: root.path));
      await settle();
      expect(find.text('top.txt'), findsOneWidget);

      await tester.tap(find.text('slow'));
      await settle();
      expect(find.text('top.txt'), findsNothing, reason: 'the old folder is not shown under the new title');
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      // Back to the top before the slow folder answered; then it answers.
      await tester.binding.handlePopRoute();
      await settle();
      expect(find.text('top.txt'), findsOneWidget);
      fs.waiting['${root.path}/slow']!.complete();
      await settle();
      expect(find.text('inside.txt'), findsNothing, reason: 'the late listing is for a folder the user left');
      expect(find.text('top.txt'), findsOneWidget);
    });
  });

  group('usage', () {
    testWidgets('switching 7 to 30 days never shows the 7-day numbers under the 30-day tab', (tester) async {
      final host = FakeHost();
      final day = DateTime(2026, 10, 27).toIso8601String().substring(0, 10);
      final thirty = Completer<Object?>();
      host.answers['usage'] = (cmd) => cmd['days'] == 7
          ? [
              {'day': day, 'provider': 'griphub', 'model': 'seven-model', 'input': 1000, 'output': 10, 'requests': 1},
            ]
          : thirty.future;
      final agent = newAgent();
      await pumpLook(tester, const Look(), UsageScreen(agent: agent), height: 2400);
      await frames(tester);
      expect(find.text('seven-model'), findsWidgets);

      await tester.tap(find.text('30 days'));
      await frames(tester);
      expect(find.text('seven-model'), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsWidgets);

      thirty.complete([
        {'day': day, 'provider': 'griphub', 'model': 'thirty-model', 'input': 5000, 'output': 50, 'requests': 4},
      ]);
      await frames(tester);
      expect(find.text('thirty-model'), findsWidgets);
      expect(find.text('seven-model'), findsNothing);
    });
  });

  group('tasks', () {
    Map<String, dynamic> runsState() => {
      'runs': const [],
      'schedules': [
        {'id': 's1', 'name': 'Nightly check', 'prompt': 'p', 'cwd': '/w', 'enabled': true, 'everyMinutes': 60},
      ],
      'concurrency': 1,
    };

    testWidgets('Run now that is refused says why, and never "Queued"', (tester) async {
      final host = FakeHost();
      host.answers['runs'] = (_) => runsState();
      host.answers['schedule_run'] = (_) => const HostError('Daily budget of 5 credits reached');
      final agent = newAgent();
      await pumpLook(tester, const Look(), TasksScreen(agent: agent), height: 1400);
      await frames(tester);
      await tester.tap(find.byTooltip('Show menu').last);
      await frames(tester);
      await tester.tap(find.text('Run now'));
      await frames(tester);
      expect(find.textContaining('Daily budget of 5 credits reached'), findsOneWidget);
      expect(find.textContaining('Queued'), findsNothing);
    });

    testWidgets('Run now that works says "Queued", with a spinner on the row until the host answered', (tester) async {
      final host = FakeHost();
      final late = Completer<Object?>();
      host.answers['runs'] = (_) => runsState();
      host.answers['schedule_run'] = (_) => late.future;
      final agent = newAgent();
      await pumpLook(tester, const Look(), TasksScreen(agent: agent), height: 1400);
      await frames(tester);
      await tester.tap(find.byTooltip('Show menu').last);
      await frames(tester);
      await tester.tap(find.text('Run now'));
      await frames(tester, 2);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      late.complete(runsState());
      await frames(tester);
      expect(find.text('Queued: "Nightly check"'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });
  });

  group('model sheet', () {
    Future<AgentController> pumpSheet(WidgetTester tester, Look look, FakeHost host) async {
      host.answers['providers'] = (_) => const [];
      host.answers['models'] = (_) => [
        _model('model-a', name: 'Model A').json,
        _model('model-b', name: 'Model B').json,
      ];
      final agent = newAgent()..model = _model('model-a', name: 'Model A');
      agent.models = [_model('model-a', name: 'Model A'), _model('model-b', name: 'Model B')];
      await pumpLook(
        tester,
        look,
        Scaffold(
          body: Builder(
            builder: (context) =>
                Center(child: TextButton(onPressed: () => showModelSheet(context, agent), child: const Text('open'))),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await frames(tester);
      return agent;
    }

    testWidgets('stays open with a spinner on the chosen model until the host has it, then closes', (tester) async {
      final host = FakeHost();
      final late = Completer<Object?>();
      host.answers['set_model'] = (_) => late.future;
      final agent = await pumpSheet(tester, const Look(), host);
      await tester.tap(find.text('Model B'));
      await frames(tester, 3);
      expect(find.text('Model B'), findsOneWidget, reason: 'the sheet is still open');
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      // Another model can't be picked meanwhile.
      await tester.tap(find.text('Model A'));
      await frames(tester, 2);
      expect(host.sent('set_model'), hasLength(1));
      late.complete({'model': _model('model-b', name: 'Model B').json, 'thinkingLevel': 'off'});
      await frames(tester);
      expect(find.text('Model B'), findsNothing, reason: 'closed once saved');
      expect(agent.model?.id, 'model-b');
    });

    for (final look in _looks) {
      testWidgets('golden: a switch that failed stays in the sheet ${look.name}', (tester) async {
        final host = FakeHost();
        host.answers['set_model'] = (_) => const HostError('This model is not available right now');
        await pumpSheet(tester, look, host);
        await tester.tap(find.text('Model B'));
        await frames(tester);
        expect(find.textContaining('This model is not available right now'), findsOneWidget);
        expect(layoutErrors, isEmpty);
        await expectLater(find.byType(BottomSheet), matchesGoldenFile(golden('model_sheet_failed_${look.name}')));
      });
    }
  });

  group('chat', () {
    testWidgets('a double tap on Send sends the message once, and Send spins until the host took it', (tester) async {
      Drafts.root = Directory.systemTemp.createTempSync('drafts-').path;
      final host = FakeHost();
      final late = Completer<Object?>();
      host.answers['prompt'] = (_) => late.future;
      final agent = newAgent()..model = _model('model-a');
      await pumpLook(tester, const Look(), ChatScreen(agent: agent));
      await frames(tester);
      await tester.enterText(find.byType(TextField).last, 'Bikin landing page');
      await frames(tester, 2);
      await tester.tap(find.bySemanticsLabel('Send'));
      await frames(tester, 2);
      expect(find.bySemanticsLabel('Sending…'), findsOneWidget);
      await tester.tap(find.bySemanticsLabel('Sending…'));
      await frames(tester, 2);
      expect(host.sent('prompt'), hasLength(1));
      late.complete(null);
      await frames(tester);
      expect(find.bySemanticsLabel('Sending…'), findsNothing);
      expect(tester.widget<TextField>(find.byType(TextField).last).controller!.text, isEmpty);
    });

    for (final look in _looks) {
      testWidgets('golden: a message being rewound ${look.name}', (tester) async {
        FakeHost();
        await pumpLook(
          tester,
          look,
          Scaffold(
            body: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                UserMessageView(
                  UserEntry('Ubah warna tombol jadi hijau'),
                  working: look.language == 'id' ? 'Memundurkan…' : 'Rewinding…',
                ),
              ],
            ),
          ),
          height: 300,
        );
        await frames(tester, 3);
        expect(layoutErrors, isEmpty);
        await expectLater(find.byType(Scaffold), matchesGoldenFile(golden('message_rewinding_${look.name}')));
      });
    }
  });
}
