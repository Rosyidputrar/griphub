import 'package:flutter_test/flutter_test.dart';
import 'package:griphub_agent/agent/subagents.dart';

// A 1×1 PNG.
const png = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==';

Map<String, dynamic> record({String status = 'running', List<Map<String, dynamic>>? timeline, List<Map<String, dynamic>> tools = const []}) => {
  'id': 'sub-1',
  'parentSessionFile': 'chat-1.jsonl',
  'parentTitle': 'halo',
  'brief': 'Riset',
  'profile': 'read',
  'status': status,
  'createdAt': 1000,
  'startedAt': 1000,
  'toolCalls': tools,
  'queue': [],
  'timeline': ?timeline,
};

void main() {
  late SubagentStore store;
  SubagentState s() => store['sub-1']!;
  void event(Map<String, dynamic> e) => store.applyRecord({'type': 'subagent_event', 'subagentId': 'sub-1', 'event': e});
  void delta(String type, String text, {String? id, String? toolName}) => event({
    'type': 'message_update',
    'assistantMessageEvent': {'type': type, 'delta': text, 'id': ?id, 'toolName': ?toolName},
  });

  setUp(() {
    store = SubagentStore()..applyRecord({'type': 'subagent_started', 'subagent': record()});
  });

  test('thinking, text and a tool call stream live, then join the timeline in the order the message had them', () {
    delta('thinking_delta', 'Cek dulu ');
    delta('thinking_delta', 'berkasnya.');
    delta('text_delta', 'Saya tulis ');
    delta('toolcall_delta', '{"path":"a.md","content":"# Ha', id: 'c1', toolName: 'write');
    expect(s().liveThinking, 'Cek dulu berkasnya.');
    expect(s().liveText, 'Saya tulis ');
    expect(s().liveArgs['c1'], '{"path":"a.md","content":"# Ha');
    expect(s().liveNames['c1'], 'write');
    expect(s().timeline, isEmpty);

    event({
      'type': 'message_end',
      'message': {
        'role': 'assistant',
        'content': [
          {'type': 'thinking', 'thinking': 'Cek dulu berkasnya.'},
          {'type': 'text', 'text': 'Saya tulis berkasnya.'},
          {'type': 'text', 'text': '   '},
          {'type': 'toolCall', 'id': 'c1', 'name': 'write', 'arguments': {'path': 'a.md', 'content': '# Halo'}},
        ],
      },
    });
    expect([for (final e in s().timeline) e.kind], [SubagentEntryKind.thinking, SubagentEntryKind.text, SubagentEntryKind.tool]);
    expect(s().timeline[1].text, 'Saya tulis berkasnya.');
    expect(s().timeline[2].toolId, 'c1');
    expect(s().liveThinking, isEmpty);
    expect(s().liveText, isEmpty);
    expect(s().liveArgs, isEmpty, reason: 'the call is placed; no writing card stays');

    // The call starts after its message ended; its arguments from the message are its input, and it is not placed twice.
    event({'type': 'tool_execution_start', 'toolCallId': 'c1', 'toolName': 'write'});
    expect(s().tool('c1')!.input, {'path': 'a.md', 'content': '# Halo'});
    expect(s().timeline.where((e) => e.kind == SubagentEntryKind.tool), hasLength(1));
  });

  test('a call keeps its whole input and the pictures in its result', () {
    final long = 'echo ${'x' * 500}';
    event({'type': 'tool_execution_start', 'toolCallId': 'b1', 'toolName': 'bash', 'args': {'command': long}});
    event({
      'type': 'tool_execution_end',
      'toolCallId': 'b1',
      'isError': false,
      'result': {
        'content': [
          {'type': 'text', 'text': 'ok'},
          for (var i = 0; i < 3; i++) {'type': 'image', 'mimeType': 'image/png', 'data': png},
        ],
      },
    });
    final t = s().tool('b1')!;
    expect(t.input!['command'], long, reason: 'not cut at the one-line summary');
    expect(t.args.length, lessThan(long.length));
    expect(t.output, 'ok');
    expect(t.images, hasLength(2));
    expect(t.images.first.mimeType, 'image/png');
    expect(s().timeline.single.toolId, 'b1', reason: 'placed when it started, with no message before it');
  });

  test('a message the person sent joins the timeline where it was taken', () {
    event({'type': 'tool_execution_start', 'toolCallId': 'r1', 'toolName': 'read', 'args': {'path': 'a'}});
    event({'type': 'subagent_user_message', 'text': 'Fokus ke performa.', 'at': 5000});
    final e = s().timeline.last;
    expect(e.kind, SubagentEntryKind.user);
    expect(e.text, 'Fokus ke performa.');
    expect(e.at, DateTime.fromMillisecondsSinceEpoch(5000));
  });

  test("the host's record replaces the timeline and carries each call's input and pictures", () {
    delta('thinking_delta', 'setengah');
    store.applyRecord({
      'type': 'subagent_finished',
      'subagent': record(
        status: 'done',
        tools: [
          {
            'id': 'e1',
            'name': 'edit',
            'args': 'a.dart',
            'input': {'path': 'a.dart', 'oldText': 'a', 'newText': 'b'},
            'images': [
              {'mimeType': 'image/png', 'data': png},
            ],
            'output': 'ok',
            'status': 'done',
            'startedAt': 1000,
            'finishedAt': 2000,
          },
        ],
        timeline: [
          {'kind': 'thinking', 'text': 'ubah a', 'at': 900},
          {'kind': 'tool', 'id': 'e1', 'at': 1000},
          {'kind': 'user', 'text': 'lanjut', 'at': 1500},
          {'kind': 'mystery', 'text': '?', 'at': 1600},
          {'kind': 'text', 'text': 'Selesai.', 'at': 2100},
        ],
      ),
    });
    expect([for (final e in s().timeline) e.kind], [
      SubagentEntryKind.thinking,
      SubagentEntryKind.tool,
      SubagentEntryKind.user,
      SubagentEntryKind.text,
    ], reason: 'an unknown kind (a newer host) is skipped');
    expect(s().tool('e1')!.input, {'path': 'a.dart', 'oldText': 'a', 'newText': 'b'});
    expect(s().tool('e1')!.images, hasLength(1));
    expect(s().liveThinking, isEmpty, reason: 'nothing is being written once it finished');
  });

  test('a record from an older host (no timeline) keeps the one built from events', () {
    event({'type': 'tool_execution_start', 'toolCallId': 'r1', 'toolName': 'read', 'args': {'path': 'a'}});
    store.applyRecord({'type': 'subagent_started', 'subagent': record()});
    expect(s().timeline, hasLength(1));
  });
}
