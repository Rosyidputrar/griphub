import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:griphub_agent/agent/agent_backend.dart';
import 'package:griphub_agent/agent/agent_client.dart';
import 'package:griphub_agent/agent/agent_controller.dart';
import 'package:griphub_agent/agent/drafts.dart';
import 'package:griphub_agent/agent/models.dart';
import 'package:griphub_agent/agent/offline_prompts.dart';

import 'support/fake_backend.dart';

/// A message typed while the server can't be reached is kept, in order, and goes once the link is back, instead of
/// failing; one the host then refuses waits with the reason, and nothing typed after it overtakes it. The server is
/// played from the test, so when it drops and comes back is exact.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      PlatformBackend.method,
      (call) async => null,
    );
  });

  late FakeBackend backend;
  late AgentClient client;
  late AgentController agent;
  late Directory root;
  late List<String> prompts;
  String? refuse;

  Future<void> until(bool Function() ok, String what) async {
    final end = DateTime.now().add(const Duration(seconds: 5));
    while (!ok()) {
      if (DateTime.now().isAfter(end)) fail('timed out waiting for $what');
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  File storeFile() => File('${root.path}/offline-prompts.json');

  Future<AgentController> start() async {
    backend = FakeBackend();
    backend.onCommand = (c) {
      switch (c['type']) {
        case 'prompt':
          if (refuse != null) throw FakeFailure(refuse!);
          prompts.add(c['text'] as String);
          return {'queued': null};
        case 'hello' || 'state':
          return {'sessionId': 's', 'sessionFile': 's.jsonl', 'cwd': '/w', 'isStreaming': false};
        case 'messages' || 'providers' || 'models' || 'sessions' || 'subagent_list' || 'approvals_pending':
          return const [];
        case 'runs':
          return {'runs': const [], 'schedules': const [], 'concurrency': 1};
        case 'settings_get':
          return {'dns': 'system'};
      }
      return const {};
    };
    client = AgentClient(backend: backend)
      ..remote = const LaunchSpec(['ssh', 'x'])
      ..backoff = ((_) => const Duration(milliseconds: 10));
    final a = AgentController(client);
    await a.boot();
    expect(a.status, BootStatus.ready, reason: a.bootError);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    return a;
  }

  /// The link drops and stays down until [comeBack].
  Future<void> drop() async {
    client.backoff = (_) => const Duration(hours: 1);
    backend.exit(255);
    await until(() => !client.connection.value.connected, 'the link to drop');
  }

  Future<void> comeBack() async {
    client.backoff = (_) => const Duration(milliseconds: 10);
    await client.reconnectNow();
    await until(() => client.connection.value.connected, 'the link to come back');
  }

  setUp(() async {
    root = Directory.systemTemp.createTempSync('offline-queue-');
    Drafts.root = root.path;
    prompts = [];
    refuse = null;
    agent = await start();
  });

  tearDown(() => root.deleteSync(recursive: true));

  test('typed while the server is away: kept in order, then sent once it is back', () async {
    await drop();
    expect(await agent.send('first'), isTrue, reason: 'kept counts as sent: the composer clears');
    expect(await agent.sendWith('second', images: [{'data': 'AAAA', 'mimeType': 'image/png'}]), isTrue);
    expect(agent.offlineForCurrent.map((p) => p.text), ['first', 'second']);
    expect(prompts, isEmpty, reason: 'nothing went out while the link was down');
    expect(storeFile().existsSync(), isTrue, reason: 'kept on disk, in case the app is closed meanwhile');

    await comeBack();
    await until(() => prompts.length == 2, 'both to be sent');
    expect(prompts, ['first', 'second'], reason: 'in the order they were typed');
    final withImage = backend.sent.lastWhere((c) => c['type'] == 'prompt');
    expect((withImage['images'] as List).single, {'data': 'AAAA', 'mimeType': 'image/png'});
    expect(agent.offlinePrompts, isEmpty);
    expect(storeFile().existsSync(), isFalse);
  });

  test('one that never left (not written to the link) is kept, and goes once the link is back', () async {
    final answer = backend.onCommand!;
    backend.onCommand = (c) => c['type'] == 'prompt' ? throw const FakeFailure('Could not send: broken pipe', code: 'not_sent') : answer(c);
    expect(await agent.send('not written'), isTrue);
    expect(agent.offlineForCurrent.single.text, 'not written');
    expect(agent.entries, isEmpty, reason: 'no error notice for a message that is only waiting');
  });

  test('one the link dropped on its way is not sent again by itself: the host may have it, and it could run twice', () async {
    backend.onCommand = (c) => c['type'] == 'prompt'
        ? throw const FakeFailure('The connection to the server was lost.', code: 'connection_lost')
        : const {};
    expect(await agent.send('maybe arrived'), isFalse, reason: 'the composer keeps the text');
    expect(agent.offlinePrompts, isEmpty);
    expect((agent.entries.single as NoticeEntry).text, contains('check whether it arrived'));
  });

  test('a new message waits behind ones still waiting, even with the link up', () async {
    await drop();
    await agent.send('one');
    refuse = 'Daily budget of 5 credits reached';
    await comeBack();
    await until(() => agent.offlineForCurrent.first.error != null, 'the refusal');
    refuse = null;
    expect(await agent.send('typed after'), isTrue);
    expect(prompts, isEmpty, reason: '"typed after" must not overtake "one"');
    expect(agent.offlineForCurrent.map((p) => p.text), ['one', 'typed after']);
    await agent.retryOffline(agent.offlineForCurrent.first.id);
    expect(prompts, ['one', 'typed after']);
  });

  test('lost on its way while the queue is being sent: it waits for the user, not sent twice', () async {
    await drop();
    await agent.send('first');
    await agent.send('second');
    final answer = backend.onCommand!;
    var calls = 0;
    backend.onCommand = (c) {
      if (c['type'] == 'prompt' && calls++ == 0) throw const FakeFailure('lost', code: 'connection_lost');
      return answer(c);
    };
    await comeBack();
    await until(() => agent.offlineForCurrent.first.error != null, 'the first to be marked');
    expect(agent.offlineForCurrent.first.error, contains('check whether it arrived'));
    expect(prompts, isEmpty, reason: 'nothing resent by itself, and "second" waits behind it');
  });

  test('one the host refuses once back waits with the reason; nothing after it goes first; send again', () async {
    await drop();
    await agent.send('one');
    await agent.send('two');
    refuse = 'Daily budget of 5 credits reached';
    await comeBack();
    await until(() => agent.offlineForCurrent.first.error != null, 'the refusal');
    expect(agent.offlineForCurrent.first.error, 'Daily budget of 5 credits reached');
    expect(prompts, isEmpty, reason: '"two" does not overtake "one"');

    refuse = null;
    await agent.retryOffline(agent.offlineForCurrent.first.id);
    expect(prompts, ['one', 'two']);
    expect(agent.offlinePrompts, isEmpty);
  });

  test('taking one back drops it and gives its text back', () async {
    await drop();
    await agent.send('never mind');
    final p = agent.dropOffline(agent.offlineForCurrent.single.id);
    expect(p?.text, 'never mind');
    expect(agent.offlinePrompts, isEmpty);
    await comeBack();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(prompts, isEmpty);
  });

  test('kept across app runs: the next start sends what the last one could not', () async {
    OfflinePromptStore.instance.save([OfflinePrompt(id: 'x1', text: 'from yesterday', session: 's')]);
    final next = await start();
    await until(() => prompts.contains('from yesterday'), 'the kept message to go');
    expect(next.offlinePrompts, isEmpty);
  });

  test('opening the chat its messages were kept for sends them', () async {
    var chat = 's';
    final answer = backend.onCommand!;
    backend.onCommand = (c) => c['type'] == 'state' || c['type'] == 'open_session'
        ? {'sessionId': chat, 'sessionFile': '$chat.jsonl', 'cwd': '/w', 'isStreaming': false}
        : answer(c);
    agent.offlinePrompts = [OfflinePrompt(id: 'o1', text: 'for the other chat', session: 'other')];
    await agent.flushOffline();
    expect(prompts, isEmpty, reason: 'not while another chat is open');
    chat = 'other';
    // Opened from the chat list. (A resync no longer stands in for this: it keeps the chat on screen, see
    // resync_chat_test.dart.)
    await agent.openSession('other.jsonl');
    await until(() => prompts.isNotEmpty, 'the kept message to go');
    expect(prompts, ['for the other chat']);
  });

  test('a message kept for another chat waits for that chat', () async {
    await drop();
    agent.offlinePrompts = [OfflinePrompt(id: 'o1', text: 'for the other chat', session: 'other')];
    await comeBack();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(prompts, isEmpty);
    expect(agent.offlineForCurrent, isEmpty);
    expect(agent.offlinePrompts.single.text, 'for the other chat');
  });

  test('on this phone nothing is ever kept: a refusal is shown as before', () async {
    final local = AgentClient(backend: FakeBackend()..onCommand = (c) => c['type'] == 'prompt' ? throw const FakeFailure('No model') : const {});
    final a = AgentController(local);
    expect(await a.send('hi'), isFalse);
    expect(a.offlinePrompts, isEmpty);
  });
}
