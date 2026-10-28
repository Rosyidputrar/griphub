import 'package:flutter_test/flutter_test.dart';
import 'package:griphub_agent/agent/agent_backend.dart';
import 'package:griphub_agent/agent/agent_client.dart';
import 'package:griphub_agent/agent/agent_controller.dart';
import 'package:griphub_agent/agent/subagents.dart';

import 'support/fake_backend.dart';

/// When a server link comes back and the server cannot replay what the app missed (`resync`), the app reads everything
/// again: the chat, the subagents, and the approvals still waiting (server_agent.md 4.2). The server is played from the
/// test, so the gap and what the host answers are exact.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // The controller talks to Android (busy flag, notifications); there is no Android here.
  setUpAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      PlatformBackend.method,
      (call) async => null,
    );
  });

  late FakeBackend backend;
  late AgentClient client;
  late AgentController agent;
  late List<Map<String, dynamic>> subagents;
  late List<Map<String, dynamic>> pending;

  Map<String, dynamic> subagent(String id, String status) => {
    'id': id,
    'parentSessionFile': 's.jsonl',
    'parentTitle': 'Chat',
    'task': 'task $id',
    'profile': 'full',
    'status': status,
    'createdAt': 0,
    'toolCalls': const [],
  };

  Map<String, dynamic> subagentApproval(String id, String approvalId) => {
    'type': 'subagent_approval_request',
    'subagentId': id,
    'approvalId': approvalId,
    'toolName': 'bash',
    'summary': 'rm -rf build',
    'reason': 'deletes files',
    'key': 'bash:rm -rf build',
  };

  Future<void> until(bool Function() ok, String what) async {
    final end = DateTime.now().add(const Duration(seconds: 5));
    while (!ok()) {
      if (DateTime.now().isAfter(end)) fail('timed out waiting for $what');
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  setUp(() async {
    backend = FakeBackend();
    subagents = [];
    pending = [];
    backend.onCommand = (c) => switch (c['type']) {
      'hello' || 'state' => {'sessionId': 's', 'sessionFile': 's.jsonl', 'cwd': '/w', 'isStreaming': false},
      'messages' || 'providers' || 'models' || 'sessions' => const [],
      'subagent_list' => subagents,
      'approvals_pending' => pending,
      'runs' => {'runs': const [], 'schedules': const [], 'concurrency': 1},
      'settings_get' => {'dns': 'system'},
      _ => const {},
    };
    client = AgentClient(backend: backend)
      ..remote = const LaunchSpec(['ssh', 'x'])
      ..backoff = ((_) => const Duration(milliseconds: 10));
    agent = AgentController(client);
    await agent.boot();
    expect(agent.status, BootStatus.ready, reason: agent.bootError);
    // Boot reads the waiting approvals in the background; let that land before the test raises its own.
    await until(() => backend.sent.any((c) => c['type'] == 'approvals_pending'), 'boot to read the approvals');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  });

  /// The link drops and comes back to a server that cannot replay (a gap).
  Future<void> dropWithGap() async {
    final before = backend.sent.where((c) => c['type'] == 'approvals_pending').length;
    backend.onResume = (_) => {'gap': true, 'replayed': 0};
    backend.exit(255);
    await until(() => client.connection.value.connected && backend.starts == 2, 'the reconnect');
    await until(
      () => backend.sent.where((c) => c['type'] == 'approvals_pending').length > before,
      'the approvals to be read',
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }

  test('approvals that were waiting come back after a gap, chat and subagent alike', () async {
    subagents.add(subagent('sa1', 'waiting_approval'));
    pending.addAll([
      {
        'type': 'approval',
        'approvalId': 'a1',
        'toolName': 'bash',
        'summary': 'git push',
        'reason': 'publishes',
        'key': 'bash:git push',
      },
      subagentApproval('sa1', 'sa1-ap'),
    ]);
    await dropWithGap();
    expect(agent.features.approvals.map((a) => a.id), ['a1']);
    expect(agent.subagentStore['sa1']?.approval?.approvalId, 'sa1-ap');
    expect(agent.subagentStore['sa1']?.status, SubagentStatus.waitingApproval);
  });

  test(
    'cards the host no longer waits on are gone after a gap; one already answered here is not shown again',
    () async {
      // Before the drop: a chat approval and a subagent approval on screen.
      backend.say({
        'seq': 1,
        'type': 'approval',
        'approvalId': 'old',
        'toolName': 'bash',
        'summary': 'x',
        'reason': 'y',
        'key': 'k',
      });
      subagents.add(subagent('sa2', 'running'));
      await agent.refreshSubagents();
      backend.say({'seq': 2, ...subagentApproval('sa2', 'sa2-old')});
      await until(
        () => agent.features.approvals.isNotEmpty && agent.subagentStore['sa2']?.approval != null,
        'the cards',
      );

      // While away both were answered elsewhere (or timed out): the host lists nothing.
      subagents
        ..clear()
        ..add(subagent('sa2', 'running'));
      await dropWithGap();
      expect(agent.features.approvals, isEmpty);
      expect(agent.subagentStore['sa2']?.approval, isNull);

      // An approval answered on this phone just before the drop stays answered, even if the host still lists it.
      pending.add({
        'type': 'approval',
        'approvalId': 'answered',
        'toolName': 'bash',
        'summary': 'x',
        'reason': 'y',
        'key': 'k',
      });
      backend.say({'seq': 1, 'type': 'approval', ...pending.last});
      await until(() => agent.features.approvals.any((a) => a.id == 'answered'), 'the new card');
      await agent.features.answer(agent.features.approvals.single, allow: true);
      await dropWithGap();
      expect(agent.features.approvals, isEmpty);
    },
  );

  test('a link that drops and resumes without a gap keeps the cards as they are, and does not reload', () async {
    backend.say({
      'seq': 1,
      'type': 'approval',
      'approvalId': 'keep',
      'toolName': 'bash',
      'summary': 'x',
      'reason': 'y',
      'key': 'k',
    });
    await until(() => agent.features.approvals.isNotEmpty, 'the card');
    final before = backend.sent.length;
    backend.exit(255);
    await until(() => client.connection.value.connected && backend.starts == 2, 'the reconnect');
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(agent.features.approvals.map((a) => a.id), ['keep'], reason: 'a dropped link is not a dead host');
    expect(backend.sent.skip(before).map((c) => c['type']), ['resume'], reason: 'nothing to reload');
    expect(agent.status, BootStatus.ready);
  });

  test(
    'an app opened while the server waits for answers shows them at once (nothing is replayed on a first connect)',
    () async {
      final b = FakeBackend();
      final sas = [subagent('sa3', 'waiting_approval')];
      final waiting = [
        {'type': 'approval', 'approvalId': 'cold', 'toolName': 'bash', 'summary': 'x', 'reason': 'y', 'key': 'k'},
        subagentApproval('sa3', 'sa3-ap'),
      ];
      b.onCommand = (c) => switch (c['type']) {
        'hello' || 'state' => {'sessionId': 's', 'sessionFile': 's.jsonl', 'cwd': '/w', 'isStreaming': false},
        'messages' || 'providers' || 'models' => const [],
        'subagent_list' => sas,
        'approvals_pending' => waiting,
        _ => const {},
      };
      final a = AgentController(AgentClient(backend: b)..remote = const LaunchSpec(['ssh', 'x']));
      await a.boot();
      await until(
        () => a.features.approvals.isNotEmpty && a.subagentStore['sa3']?.approval != null,
        'the waiting approvals',
      );
      expect(a.features.approvals.single.id, 'cold');
      expect(a.subagentStore['sa3']!.approval!.approvalId, 'sa3-ap');
    },
  );

  test('on the phone boot does not ask for waiting approvals (its host lives and dies with the app)', () async {
    final b = FakeBackend()..startPlan.add(false);
    b.onCommand = (c) => switch (c['type']) {
      'hello' || 'state' => {'sessionId': 's', 'cwd': '/w', 'isStreaming': false},
      'messages' || 'providers' || 'models' || 'subagent_list' => const [],
      _ => const {},
    };
    final a = AgentController(AgentClient(backend: b));
    final booting = a.boot();
    await until(() => b.starts == 1, 'the start');
    b.say({'type': 'ready'});
    await booting;
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(a.status, BootStatus.ready);
    expect(b.sent.map((c) => c['type']), isNot(contains('approvals_pending')));
    expect(b.sent.map((c) => c['type']), isNot(contains('resume')));
  });
}
