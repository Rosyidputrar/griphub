import 'dart:io';

import 'package:griphub_agent/agent/agent_backend.dart';
import 'package:griphub_agent/agent/agent_client.dart';
import 'package:griphub_agent/agent/agent_controller.dart';
import 'package:griphub_agent/agent/models.dart';
import 'package:griphub_agent/agent/subagents.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/daemon.dart';

/// The controller (what the screens read) over a server agent link that drops: the conversation on screen must come out
/// right, and a dropped link must not look like a crash. The first three cases are ported from CoderRa's
/// test/remote_controller_test.dart; the subagent cases are GripHub's (server_agent.md 4.1, 4.2).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final skip = TestDaemon.skip;

  // The controller tells Android when the agent is busy; there is no Android here.
  setUpAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      PlatformBackend.method,
      (call) async => null,
    );
  });

  late TestDaemon daemon;
  late MockModel model;
  late ProcessBackend backend;
  late AgentClient client;
  late AgentController agent;

  setUp(() async {
    model = await MockModel.start();
    daemon = await TestDaemon.start(model: model);
    backend = ProcessBackend();
    client = AgentClient(backend: backend)
      ..remote = daemon.launchSpec
      ..backoff = ((_) => const Duration(milliseconds: 50));
    agent = AgentController(client);
    await agent.boot();
    expect(agent.status, BootStatus.ready, reason: agent.bootError);
    await TestDaemon.useMockModel(client);
  });

  tearDown(() async {
    await client.stop();
    await daemon.dispose();
    await model.close();
  });

  Future<void> until(bool Function() ok, [String what = 'the condition', int seconds = 20]) async {
    final end = DateTime.now().add(Duration(seconds: seconds));
    while (!ok()) {
      if (DateTime.now().isAfter(end)) fail('timed out waiting for $what');
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  String lastReply() {
    final a = agent.entries.whereType<AssistantEntry>().lastOrNull;
    return a == null ? '' : a.orderedBlocks.where((b) => b.kind == BlockKind.text).map((b) => b.text).join();
  }

  test('a dropped link is not a crash: the app stays on its screens and the reply finishes on its own', () async {
    final reply = MockReply(['Alpha ', 'beta ', 'gamma ', 'delta'], holdAfter: 2);
    model.script.add(reply);
    await agent.send('say the letters');
    await until(() => lastReply().contains('beta'));

    backend.current!.kill();
    await until(() => client.connection.value.state == LinkState.reconnecting);
    expect(agent.status, BootStatus.ready, reason: 'no failure screen');
    expect(agent.bootError, isNull);

    reply.release();
    await until(() => client.connection.value.connected);
    await until(() => !agent.busy, 'the agent to finish');
    expect(lastReply(), 'Alpha beta gamma delta');
    expect(agent.entries.whereType<AssistantEntry>(), hasLength(1), reason: 'nothing doubled');
    expect(agent.entries.whereType<UserEntry>().map((e) => e.text), ['say the letters']);
  }, skip: skip);

  test('after a restart of the daemon the chat is read from the host again and matches what it kept', () async {
    model.script.add(MockReply(['First answer']));
    await agent.send('first');
    await until(() => lastReply() == 'First answer' && !agent.busy);

    await daemon.kill();
    await until(() => client.connection.value.state == LinkState.reconnecting);
    // Something on screen that the host knows nothing about: the resync must replace the transcript, not add to it.
    agent.entries.add(UserEntry('a ghost from before'));
    await daemon.launch();
    await until(() => client.connection.value.connected, 'the reconnect', 30);
    await until(
      () => agent.entries.whereType<UserEntry>().length == 1 && lastReply() == 'First answer',
      'the chat to be reloaded',
    );
    expect(agent.entries.whereType<AssistantEntry>(), hasLength(1));
    expect(agent.entries.whereType<UserEntry>().map((e) => e.text), ['first']);
    expect(agent.status, BootStatus.ready);

    // And it still works afterwards.
    model.script.add(MockReply(['Second answer']));
    await agent.send('second');
    await until(() => lastReply() == 'Second answer' && !agent.busy);
    expect(agent.entries.whereType<AssistantEntry>(), hasLength(2));
  }, skip: skip);

  test('a first connection that fails is a failed start with the reason, as on the phone', () async {
    await daemon.kill();
    final c = AgentClient(backend: ProcessBackend())..remote = daemon.launchSpec;
    final a = AgentController(c);
    await a.boot();
    expect(a.status, BootStatus.failed);
    expect(a.bootError, contains('not running'));
    await c.stop();
  }, skip: skip);

  test(
    'a subagent that finishes while the link is down shows up finished, with its report, once the link is back',
    () async {
      final reply = MockReply(['Half ', 'of the report, ', 'then the rest.'], holdAfter: 1);
      model.script.add(reply);
      final started = (await client.call<Map>('subagent_start', {
        'task': 'Check the files',
        'profile': 'read',
      })).cast<String, dynamic>();
      final id = started['id'] as String;
      await until(() => agent.subagentStore[id]?.status == SubagentStatus.running, 'the subagent to run');

      backend.current!.kill();
      await until(() => client.connection.value.state == LinkState.reconnecting);
      reply.release(); // it finishes on the server while the phone is away
      await until(() => client.connection.value.connected);
      await until(() => agent.subagentStore[id]?.status == SubagentStatus.done, 'the finished subagent to be replayed');
      expect(agent.subagentStore[id]!.report, 'Half of the report, then the rest.');
      expect(agent.status, BootStatus.ready);
    },
    skip: skip,
  );

  test('a subagent that asks for approval while the phone is away is waiting for it after reconnecting; the answer lets it go on', () async {
    await client.call('settings_set', {
      'settings': {'subagentApprovalMode': 'ask_all'},
    });
    final ask = MockReply([], holdAfter: 0, toolCall: ('write', {'path': 'from-subagent.txt', 'content': 'hi'}));
    model.script
      ..add(ask)
      ..add(MockReply(['Wrote the file.']));
    final started = (await client.call<Map>('subagent_start', {
      'task': 'Write a file',
      'profile': 'full',
    })).cast<String, dynamic>();
    final id = started['id'] as String;
    await until(() => model.requests == 1, 'the subagent to ask its model');

    backend.current!.kill();
    await until(() => client.connection.value.state == LinkState.reconnecting);
    ask.release(); // it reaches for the tool while nobody is looking
    await Future<void>.delayed(const Duration(milliseconds: 300));
    await until(() => client.connection.value.connected);
    await until(() => agent.subagentStore[id]?.approval != null, 'the approval to be replayed');
    expect(agent.subagentStore[id]!.status, SubagentStatus.waitingApproval);
    expect(File('${daemon.workspace}/from-subagent.txt').existsSync(), isFalse);

    final approval = agent.subagentStore[id]!.approval!;
    await agent.replySubagentApproval(id, approval.approvalId, true);
    await until(() => agent.subagentStore[id]?.status == SubagentStatus.done, 'the subagent to finish');
    expect(File('${daemon.workspace}/from-subagent.txt').readAsStringSync(), 'hi');
    expect(agent.subagentStore[id]!.approval, isNull);
  }, skip: skip);
}
