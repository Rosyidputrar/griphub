import 'package:flutter_test/flutter_test.dart';
import 'package:griphub_agent/agent/subagent_notifications.dart';
import 'package:griphub_agent/agent/subagents.dart';

Map<String, dynamic> started({String id = 'sub-1', String parent = 'chat-1.jsonl'}) => {
  'type': 'subagent_started',
  'subagent': {
    'id': id,
    'parentSessionFile': parent,
    'parentTitle': 'halo',
    'brief': 'Riset berita hari ini',
    'profile': 'read',
    'status': 'running',
    'createdAt': 1000,
    'startedAt': 1000,
    'toolCalls': [],
    'queue': [],
    'inputTokens': 0,
    'outputTokens': 0,
    'credits': null,
  },
};

void main() {
  test('started creates state for the parent chat', () {
    final store = SubagentStore();
    store.applyRecord(started());
    expect(store.forParent(file: 'chat-1.jsonl'), hasLength(1));
    expect(store.forParent(file: 'other.jsonl'), isEmpty);
    final s = store['sub-1']!;
    expect(s.brief, 'Riset berita hari ini');
    expect(s.profileKey, 'Read-only');
    expect(s.isActive, isTrue);
  });

  test('tool events build the tool list in order', () {
    final store = SubagentStore();
    store.applyRecord(started());
    store.applyRecord({
      'type': 'subagent_event',
      'subagentId': 'sub-1',
      'event': {'type': 'tool_execution_start', 'toolCallId': 't1', 'toolName': 'web_search', 'args': {'query': 'berita'}},
    });
    store.applyRecord({
      'type': 'subagent_event',
      'subagentId': 'sub-1',
      'event': {
        'type': 'tool_execution_end',
        'toolCallId': 't1',
        'toolName': 'web_search',
        'result': {'content': [{'type': 'text', 'text': 'hasil'}]},
        'isError': false,
      },
    });
    final s = store['sub-1']!;
    expect(s.tools, hasLength(1));
    expect(s.tools.first.name, 'web_search');
    expect(s.tools.first.args, 'berita');
    expect(s.tools.first.output, 'hasil');
    expect(s.tools.first.status, SubagentToolStatus.done);
    expect(s.currentTool, isNull);
  });

  test('settled is not a finish; finished is terminal with the report', () {
    final store = SubagentStore();
    store.applyRecord(started());
    store.applyRecord({'type': 'subagent_event', 'subagentId': 'sub-1', 'event': {'type': 'agent_settled'}});
    expect(store['sub-1']!.status, SubagentStatus.running);
    store.applyRecord({
      'type': 'subagent_finished',
      'subagent': {
        'id': 'sub-1',
        'parentSessionFile': 'chat-1.jsonl',
        'parentTitle': 'halo',
        'brief': 'Riset berita hari ini',
        'profile': 'read',
        'status': 'done',
        'createdAt': 1000,
        'startedAt': 1000,
        'finishedAt': 2000,
        'toolCalls': [],
        'queue': [],
        'inputTokens': 100,
        'outputTokens': 200,
        'credits': 1.5,
        'report': 'LAPORAN',
      },
    });
    final s = store['sub-1']!;
    expect(s.isTerminal, isTrue);
    expect(s.report, 'LAPORAN');
    expect(s.credits, 1.5);
  });

  test('queue records replace the list; approval request and dismiss toggle', () {
    final store = SubagentStore();
    store.applyRecord(started());
    store.applyRecord({
      'type': 'subagent_queued',
      'subagentId': 'sub-1',
      'queue': [
        {'id': 'q1', 'text': 'Tambahkan olahraga', 'at': 1500},
      ],
    });
    expect(store['sub-1']!.queue, hasLength(1));
    store.applyRecord({
      'type': 'subagent_approval_request',
      'subagentId': 'sub-1',
      'approvalId': 'a1',
      'toolName': 'bash',
      'summary': 'rm -rf /tmp/x',
      'reason': 'Perintah berbahaya',
      'key': 'bash:rm -rf /tmp/x',
    });
    expect(store['sub-1']!.status, SubagentStatus.waitingApproval);
    expect(store['sub-1']!.approval?.toolName, 'bash');
    store.applyRecord({'type': 'subagent_approval_dismiss', 'subagentId': 'sub-1', 'approvalId': 'a1'});
    expect(store['sub-1']!.approval, isNull);
    expect(store['sub-1']!.status, SubagentStatus.running);
  });

  test('runningElsewhere excludes the open chat', () {
    final store = SubagentStore();
    store.applyRecord(started(id: 'sub-1', parent: 'chat-1.jsonl'));
    store.applyRecord(started(id: 'sub-2', parent: 'chat-2.jsonl'));
    expect(store.runningElsewhere(file: 'chat-1.jsonl').map((s) => s.id), ['sub-2']);
    expect(store.runningElsewhere(file: 'chat-2.jsonl').map((s) => s.id), ['sub-1']);
  });

  test('host status names map exactly; unknown names keep the current status', () {
    final store = SubagentStore();
    store.applyRecord(started());
    store.applyRecord({'type': 'subagent_status', 'subagentId': 'sub-1', 'status': 'waiting_approval'});
    expect(store['sub-1']!.status, SubagentStatus.waitingApproval);
    store.applyRecord({'type': 'subagent_status', 'subagentId': 'sub-1', 'status': 'mystery'});
    expect(store['sub-1']!.status, SubagentStatus.waitingApproval);
    store.applyRecord({'type': 'subagent_status', 'subagentId': 'sub-1', 'status': 'stopping'});
    expect(store['sub-1']!.status, SubagentStatus.stopping);
  });

  test('a late status never revives a finished subagent; finishing drops its approval', () {
    final store = SubagentStore();
    store.applyRecord(started());
    store.applyRecord({
      'type': 'subagent_approval_request',
      'subagentId': 'sub-1',
      'approvalId': 'a1',
      'toolName': 'bash',
      'summary': 's',
      'reason': 'r',
      'key': 'k',
    });
    final fin = (started()['subagent'] as Map<String, dynamic>)..addAll({'status': 'stopped', 'stopCode': 'credit', 'finishedAt': 3000});
    store.applyRecord({'type': 'subagent_finished', 'subagent': fin});
    expect(store['sub-1']!.approval, isNull);
    expect(store['sub-1']!.stopCode, SubagentStopCode.credit);
    store.applyRecord({'type': 'subagent_status', 'subagentId': 'sub-1', 'status': 'running'});
    expect(store['sub-1']!.status, SubagentStatus.stopped);
  });

  test('a dismiss only clears the request it names', () {
    final store = SubagentStore();
    store.applyRecord(started());
    Map<String, dynamic> req(String id) => {
      'type': 'subagent_approval_request',
      'subagentId': 'sub-1',
      'approvalId': id,
      'toolName': 'bash',
      'summary': 's',
      'reason': 'r',
      'key': 'k',
    };
    store.applyRecord(req('a1'));
    store.applyRecord(req('a2'));
    store.applyRecord({'type': 'subagent_approval_dismiss', 'subagentId': 'sub-1', 'approvalId': 'a1'});
    expect(store['sub-1']!.approval?.approvalId, 'a2');
  });

  test('toolCallId and the current tool argument come through', () {
    final store = SubagentStore();
    final r = started();
    (r['subagent'] as Map)['toolCallId'] = 'call-9';
    store.applyRecord(r);
    store.applyRecord({
      'type': 'subagent_event',
      'subagentId': 'sub-1',
      'event': {'type': 'tool_execution_start', 'toolCallId': 't1', 'toolName': 'read', 'args': {'path': 'a.dart'}},
    });
    expect(store['sub-1']!.toolCallId, 'call-9');
    expect(store['sub-1']!.currentArgs, 'a.dart');
  });

  test('unknown records and unknown subagents are ignored, not crashes', () {
    final store = SubagentStore();
    store.applyRecord({'type': 'subagent_event', 'subagentId': 'nope', 'event': {'type': 'agent_settled'}});
    store.applyRecord({'type': 'subagent_bogus'});
    expect(store.all, isEmpty);
  });

  group('SubagentNotifier', () {
    late List<Map<String, dynamic>> posted;
    late List<int> cancelled;
    late SubagentNotifier notifier;

    SubagentState state({required String id, required String parent, required SubagentStatus status}) {
      final s = SubagentState(
        id: id,
        parentSessionFile: parent,
        parentTitle: 'halo',
        brief: 'Tugas',
        profile: 'read',
        status: status,
        createdAt: DateTime.fromMillisecondsSinceEpoch(1000),
      );
      return s;
    }

    setUp(() {
      posted = [];
      cancelled = [];
      notifier = SubagentNotifier(
        notify: (id, title, body, {channel = 'chats', launch, actions = const []}) async {
          posted.add({'id': id, 'title': title, 'body': body, 'channel': channel, 'launch': launch});
        },
        cancel: (id) async {
          cancelled.add(id);
        },
      );
    });

    test('one running elsewhere posts the running notification, none clears it', () async {
      await notifier.syncRunning([state(id: 'sub-1', parent: 'a.jsonl', status: SubagentStatus.running)]);
      expect(posted, hasLength(1));
      expect(posted.first['id'], SubagentNotifier.runningId);
      expect(posted.first['title'], 'Subagent running');
      // No chat title, brief, or report content in the notification body.
      expect(posted.first['body'], isNot(contains('halo')));
      expect((posted.first['launch'] as Map)['path'], 'a.jsonl');
      await notifier.syncRunning([]);
      expect(cancelled, containsAll([SubagentNotifier.runningId, SubagentNotifier.summaryId]));
    });

    test('several running elsewhere share one summary notification', () async {
      await notifier.syncRunning([
        state(id: 'sub-1', parent: 'a.jsonl', status: SubagentStatus.running),
        state(id: 'sub-2', parent: 'b.jsonl', status: SubagentStatus.running),
      ]);
      expect(posted, hasLength(1));
      expect(posted.first['id'], SubagentNotifier.summaryId);
      expect(posted.first['title'], '2 subagents running');
    });

    test('texts follow the UI language through translate', () async {
      notifier.translate = (en) => const {
        'Subagent running': 'Subagent berjalan',
        'Tap to open the parent chat.': 'Ketuk untuk membuka chat induk.',
      }[en] ?? en;
      await notifier.syncRunning([state(id: 'sub-1', parent: 'a.jsonl', status: SubagentStatus.running)]);
      expect(posted.single['title'], 'Subagent berjalan');
      expect(posted.single['body'], 'Ketuk untuk membuka chat induk.');
    });

    test('running notification: off when disabled, and identical syncs post once', () async {
      final running = [state(id: 'sub-1', parent: 'a.jsonl', status: SubagentStatus.running)];
      await notifier.syncRunning(running);
      await notifier.syncRunning(running);
      expect(posted, hasLength(1));
      await notifier.syncRunning(running, enabled: false);
      expect(cancelled, containsAll([SubagentNotifier.runningId, SubagentNotifier.summaryId]));
      expect(posted, hasLength(1));
    });

    test('one approval request notifies once', () async {
      final s = state(id: 'sub-1', parent: 'a.jsonl', status: SubagentStatus.waitingApproval);
      final ap = SubagentApproval(approvalId: 'a1', toolName: 'bash', summary: 'x', reason: 'r', key: 'k');
      await notifier.notifyApproval(s, ap, enabled: true);
      await notifier.notifyApproval(s, ap, enabled: true);
      expect(posted, hasLength(1));
    });

    test('finished notifies only when enabled; stopped never notifies', () async {
      await notifier.notifyFinished(
        state(id: 'sub-1', parent: 'a.jsonl', status: SubagentStatus.done),
        notifyDone: false,
        notifyFailed: true,
      );
      expect(posted, isEmpty);
      await notifier.notifyFinished(
        state(id: 'sub-1', parent: 'a.jsonl', status: SubagentStatus.done),
        notifyDone: true,
        notifyFailed: true,
      );
      expect(posted.first['title'], 'Subagent finished');
      await notifier.notifyFinished(
        state(id: 'sub-2', parent: 'a.jsonl', status: SubagentStatus.stopped),
        notifyDone: true,
        notifyFailed: true,
      );
      expect(posted, hasLength(1));
    });

    test('approval notification is tracked and cancellable', () async {
      final s = state(id: 'sub-1', parent: 'a.jsonl', status: SubagentStatus.waitingApproval);
      final ap = SubagentApproval(approvalId: 'a1', toolName: 'bash', summary: 'rm -rf x', reason: 'risky', key: 'k');
      await notifier.notifyApproval(s, ap, enabled: true);
      expect(posted.first['channel'], 'approvals');
      final id = posted.first['id'] as int;
      await notifier.cancelApproval('a1');
      expect(cancelled, contains(id));
    });
  });
}
