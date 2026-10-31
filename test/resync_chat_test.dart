import 'package:flutter_test/flutter_test.dart';
import 'package:griphub_agent/agent/agent_backend.dart';
import 'package:griphub_agent/agent/agent_client.dart';
import 'package:griphub_agent/agent/agent_controller.dart';
import 'package:griphub_agent/agent/models.dart';
import 'package:griphub_agent/agent/subagents.dart';

import 'support/fake_backend.dart';

/// A server link that comes back without a replay (`resync`), most often because the server's host was restarted: the
/// chat on screen must stay the chat on screen. The host comes back in another chat (its most recent, or a new empty
/// one), and adopting it showed "Connect a model to begin" in place of the chat the user was working in.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      PlatformBackend.method,
      (call) async => null,
    );
  });

  late FakeBackend backend;
  late AgentController agent;
  late String hostChat;
  late Set<String> chatsOnDisk;
  late List<Map<String, dynamic>> opened;

  Map<String, dynamic> stateOf(String chat) => {
    'sessionId': chat,
    'sessionFile': '/s/$chat.jsonl',
    'cwd': chat == 'work' ? '/w/shop' : '/w',
    'isStreaming': false,
    if (chat == 'work') 'model': {'provider': 'griphub', 'id': 'm', 'name': 'M', 'input': ['text']},
  };

  List<Map<String, dynamic>> messagesOf(String chat) => chat == 'work'
      ? [
          {'role': 'user', 'content': 'Fix the login', 'timestamp': 1},
        ]
      : [];

  setUp(() async {
    hostChat = 'work';
    chatsOnDisk = {'/s/work.jsonl'};
    opened = [];
    backend = FakeBackend();
    backend.onCommand = (c) {
      switch (c['type']) {
        case 'hello' || 'state':
          return stateOf(hostChat);
        case 'open_session':
          opened.add(c);
          final path = c['path'] as String;
          if (!chatsOnDisk.contains(path)) throw const FakeFailure('ENOENT: no such chat');
          hostChat = path.split('/').last.replaceAll('.jsonl', '');
          return stateOf(hostChat);
        case 'messages':
          return messagesOf(hostChat);
        case 'providers' || 'models' || 'sessions' || 'subagent_list' || 'approvals_pending' || 'job_list':
          return const [];
        case 'runs':
          return {'runs': const [], 'schedules': const [], 'concurrency': 1};
        case 'settings_get':
          return {'dns': 'system'};
      }
      return const {};
    };
    final client = AgentClient(backend: backend)
      ..remote = const LaunchSpec(['ssh', 'x'])
      ..backoff = ((_) => const Duration(milliseconds: 10));
    agent = AgentController(client);
    await agent.boot();
    expect(agent.status, BootStatus.ready, reason: agent.bootError);
    await agent.loadHistory();
    expect(agent.sessionFile, '/s/work.jsonl');
    expect(agent.entries.whereType<UserEntry>().single.text, 'Fix the login');
  });

  test('the host restarted into a new empty chat: the chat on screen is opened again, not swapped for it', () async {
    hostChat = 'fresh'; // what a restarted host opens
    await agent.resync();
    expect(opened.single['path'], '/s/work.jsonl');
    expect(opened.single['cwd'], '/w/shop', reason: 'the folder goes along, for a chat with no file yet');
    expect(agent.sessionFile, '/s/work.jsonl');
    expect(agent.model, isNotNull, reason: 'not the "Connect a model" screen');
    expect(agent.entries.whereType<UserEntry>().single.text, 'Fix the login');
  });

  test('the same chat on both sides (a gap, no restart): nothing is reopened', () async {
    await agent.resync();
    expect(opened, isEmpty);
    expect(agent.sessionFile, '/s/work.jsonl');
  });

  test('the chat on screen was deleted meanwhile: the host\'s chat is shown, nothing breaks', () async {
    hostChat = 'fresh';
    chatsOnDisk.clear();
    await agent.resync();
    expect(opened.single['path'], '/s/work.jsonl', reason: 'it tried');
    expect(agent.sessionFile, '/s/fresh.jsonl');
    expect(agent.entries, isEmpty);
  });

  test('a subagent the app saw at work and the restarted host no longer has shows as lost, not running for good', () async {
    Map<String, dynamic> sub(String id, String status) => {
      'id': id,
      'parentSessionFile': '/s/work.jsonl',
      'parentTitle': 'Chat',
      'task': 'task $id',
      'profile': 'full',
      'status': status,
      'createdAt': 0,
      'toolCalls': const [],
    };
    agent.subagentStore.applyRecord({'type': 'subagent_started', 'subagent': sub('gone', 'running')});
    agent.subagentStore.applyRecord({'type': 'subagent_started', 'subagent': sub('kept', 'running')});
    final answer = backend.onCommand!;
    backend.onCommand = (c) => c['type'] == 'subagent_list' ? [sub('kept', 'running')] : answer(c);
    await agent.refreshSubagents();
    final gone = agent.subagentStore['gone']!;
    expect(gone.status, SubagentStatus.failed);
    expect(gone.error, AgentController.lostSubagent);
    expect(agent.subagentStore['kept']!.status, SubagentStatus.running, reason: 'the host still has it');
  });
}
