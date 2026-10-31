// The subagent's steps shown as the chat shows its own: thinking, text between tools, tool cards with Copy and syntax
// highlighting, what the person sent, pictures, the call being written, following the newest step, sharing, and what a
// screen reader hears.
import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:griphub_agent/agent/subagents.dart';
import 'package:griphub_agent/ui/code_view.dart';
import 'package:griphub_agent/ui/diff_view.dart';
import 'package:griphub_agent/ui/message_views.dart';
import 'package:griphub_agent/ui/subagent_card.dart';
import 'package:griphub_agent/ui/subagent_timeline.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'harness.dart';
import 'subagent_golden_test.dart' show agentWithSubagents, subRecord;

const png = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==';
final longCommand = 'flutter build apk --release ${List.generate(30, (i) => '--dart-define=K$i=v$i').join(' ')} && echo SELESAI';

Map<String, dynamic> call(String id, String name, Map<String, dynamic> input, {String output = '', String status = 'done', List<Map<String, dynamic>>? images}) => {
  'id': id,
  'name': name,
  'args': name == 'bash' ? (input['command'] as String).split(' ').take(3).join(' ') : input['path'] ?? '',
  'input': input,
  'output': output,
  'status': status,
  'images': ?images,
  'startedAt': 1000,
  'finishedAt': status == 'running' ? null : 3000,
};

SubagentState state({String status = 'running'}) {
  final store = SubagentStore();
  store.applyRecord({
    'type': 'subagent_started',
    'subagent': {
      ...subRecord('s', status: status, tools: [
        call('b', 'bash', {'command': longCommand}, output: 'BUILD OK\n${'line\n' * 5}SELESAI'),
        call('e', 'edit', {'path': 'lib/a.dart', 'edits': [{'oldText': 'final a = 1;', 'newText': 'final a = 2;'}]}),
        call('w', 'write', {'path': 'README.md', 'content': '# Judul\n\nIsi berkas.'}),
        call('r', 'read', {'path': 'shot.png'}, images: [{'mimeType': 'image/png', 'data': png}]),
        call('f', 'bash', {'command': 'false'}, output: 'exit 1', status: 'failed'),
      ]),
      'timeline': [
        {'kind': 'thinking', 'text': 'Pikirkan dulu urutannya.', 'at': 900},
        {'kind': 'tool', 'id': 'b', 'at': 1000},
        {'kind': 'text', 'text': 'Build **berhasil**; sekarang ubah kodenya.', 'at': 1100},
        {'kind': 'tool', 'id': 'e', 'at': 1200},
        {'kind': 'user', 'text': 'Tambahkan README juga.', 'at': 1300},
        {'kind': 'tool', 'id': 'w', 'at': 1400},
        {'kind': 'tool', 'id': 'r', 'at': 1500},
        {'kind': 'tool', 'id': 'f', 'at': 1600},
      ],
    },
  });
  return store['s']!;
}

Widget page(SubagentState s) => Scaffold(body: SingleChildScrollView(padding: const EdgeInsets.all(16), child: SubagentTimeline(state: s)));

Finder card(String id) => find.byKey(ValueKey('tool:$id'));

Future<void> frames(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  setUpAll(loadAppFonts);
  setUp(() => applyLook(const Look()));

  testWidgets('thinking, text, sent messages and tools show in the order they happened', (tester) async {
    await pumpLook(tester, const Look(), page(state()), height: 3000);
    final thinking = find.byType(ThinkingView);
    final text = find.textContaining('sekarang ubah kodenya', findRichText: true);
    final sent = find.byType(SubagentSentMessage);
    expect(thinking, findsOneWidget);
    expect(text, findsOneWidget);
    expect(sent, findsOneWidget);
    double y(Finder f) => tester.getTopLeft(f).dy;
    expect(y(thinking), lessThan(y(card('b'))));
    expect(y(card('b')), lessThan(y(text)));
    expect(y(text), lessThan(y(card('e'))));
    expect(y(card('e')), lessThan(y(sent)));
    expect(y(sent), lessThan(y(card('w'))));
    final bubble = find.descendant(of: sent, matching: find.byType(Container));
    expect(tester.getTopRight(bubble).dx, closeTo(390 - 16, 1), reason: "on the right, as the person's own messages are");
    expect(tester.getTopLeft(bubble).dx, greaterThan(150), reason: 'as wide as its text');
  });

  testWidgets('a command shows whole, highlighted, with Copy; its output too once opened', (tester) async {
    await pumpLook(tester, const Look(), page(state()), height: 3000);
    final box = find.descendant(of: card('b'), matching: find.byType(CodeBox));
    expect(box, findsOneWidget, reason: 'the command is visible without opening the card');
    expect(tester.widget<CodeBox>(box).text, longCommand, reason: 'not cut at 200 characters');
    expect(tester.widget<CodeBox>(box).language, 'bash');
    expect(find.descendant(of: card('b'), matching: find.byType(CopyButton)), findsOneWidget);

    await tester.tap(find.descendant(of: card('b'), matching: find.byIcon(LucideIcons.chevronDown)));
    await frames(tester);
    final boxes = tester.widgetList<CodeBox>(find.descendant(of: card('b'), matching: find.byType(CodeBox))).toList();
    expect(boxes.map((b) => b.text), contains(startsWith('BUILD OK')));
    expect(find.descendant(of: card('b'), matching: find.byType(CopyButton)), findsNWidgets(2));
    final copied = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (c) async {
      if (c.method == 'Clipboard.setData') copied.add((c.arguments as Map)['text'] as String);
      return null;
    });
    await tester.tap(find.descendant(of: card('b'), matching: find.byType(CopyButton)).first);
    await frames(tester);
    expect(copied.single, longCommand);
    await tester.pump(const Duration(seconds: 3)); // the "Copied" check goes back
  });

  testWidgets('an edit opens to its changes; a written file shows its content; pictures show', (tester) async {
    await pumpLook(tester, const Look(), page(state()), height: 3000);
    final write = find.descendant(of: card('w'), matching: find.byType(CodeBox));
    expect(tester.widget<CodeBox>(write).text, '# Judul\n\nIsi berkas.');
    expect(tester.widget<CodeBox>(write).language, 'md');
    expect(find.descendant(of: card('r'), matching: find.byType(ToolImages)), findsOneWidget);

    expect(find.byType(DiffView), findsNothing);
    await tester.tap(find.descendant(of: card('e'), matching: find.text('lib/a.dart')));
    await frames(tester);
    expect(find.descendant(of: card('e'), matching: find.byType(DiffView)), findsOneWidget);
    expect(tester.widget<DiffView>(find.byType(DiffView)).patch, contains('-final a = 1;\n+final a = 2;'));
  });

  testWidgets('a screen reader hears how each call went and whether it is open', (tester) async {
    final semantics = tester.ensureSemantics();
    await pumpLook(tester, const Look(), page(state()), height: 3000);
    expect(find.descendant(of: card('f'), matching: find.bySemanticsLabel(RegExp('Failed'))), findsOneWidget);
    expect(find.descendant(of: card('b'), matching: find.bySemanticsLabel(RegExp('Done'))), findsOneWidget);
    final header = find.descendant(of: card('f'), matching: find.byType(InkWell)).first;
    expect(tester.getSemantics(header), isSemantics(isExpanded: false, hasTapAction: true));
    await tester.tap(header);
    await frames(tester);
    expect(tester.getSemantics(header), isSemantics(isExpanded: true, hasTapAction: true));
    expect(find.descendant(of: find.byType(SubagentSentMessage), matching: find.bySemanticsLabel(RegExp('You sent'))), findsOneWidget);
    semantics.dispose();
  });

  testWidgets('what is being written shows live: thinking, text, and a file as it arrives', (tester) async {
    final s = state();
    s.applyEvent({'type': 'message_update', 'assistantMessageEvent': {'type': 'thinking_delta', 'delta': 'Sedang menimbang'}});
    s.applyEvent({'type': 'message_update', 'assistantMessageEvent': {'type': 'text_delta', 'delta': 'Saya akan menulis'}});
    s.applyEvent({
      'type': 'message_update',
      'assistantMessageEvent': {'type': 'toolcall_delta', 'id': 'n', 'toolName': 'write', 'delta': '{"path":"lib/new.dart","content":"void main() {\\n  print(1);'},
    });
    await pumpLook(tester, const Look(), page(s), height: 3000);
    expect(tester.widgetList<ThinkingView>(find.byType(ThinkingView)).where((t) => t.live), hasLength(1));
    expect(find.byType(TypewriterMarkdown), findsOneWidget);
    final live = tester.widget<LiveTail>(find.byType(LiveTail));
    expect(live.text, contains('print(1);'));
    expect(live.language, 'dart');
    expect(find.text('lib/new.dart'), findsOneWidget);

    // Its message ends: the writing card gives way to the call itself.
    s.applyEvent({
      'type': 'message_end',
      'message': {'role': 'assistant', 'content': [{'type': 'toolCall', 'id': 'n', 'name': 'write', 'arguments': {'path': 'lib/new.dart', 'content': 'void main() {}'}}]},
    });
    s.applyEvent({'type': 'tool_execution_start', 'toolCallId': 'n', 'toolName': 'write', 'args': {'path': 'lib/new.dart', 'content': 'void main() {}'}});
    await pumpLook(tester, const Look(), page(s), height: 3000);
    expect(find.byType(LiveTail), findsNothing);
    expect(card('n'), findsOneWidget);
    expect(tester.widgetList<ThinkingView>(find.byType(ThinkingView)).where((t) => t.live), isEmpty);
  });

  testWidgets('with nothing yet, it says so', (tester) async {
    final store = SubagentStore()..applyRecord({'type': 'subagent_started', 'subagent': subRecord('x')});
    await pumpLook(tester, const Look(), page(store['x']!));
    expect(find.text('No steps yet.'), findsOneWidget);
  });

  test('the shared Markdown has the task, steps and report, without thinking or output', () {
    final s = state(status: 'done')..report = 'Semua beres.';
    final md = subagentMarkdown(s);
    expect(md, contains(s.brief));
    expect(md, contains('Build **berhasil**'));
    expect(md, contains('Tambahkan README juga.'));
    expect(md, contains('✓ `edit`'));
    expect(md, contains('✗ `bash`'));
    expect(md, contains('Semua beres.'));
    expect(md, isNot(contains('Pikirkan dulu')), reason: 'thinking is left out');
    expect(md, isNot(contains('BUILD OK')), reason: "the tools' output is left out");
  });

  group('sheet', () {
    late FakeHost host;
    setUp(() => host = FakeHost());

    testWidgets('Share opens the share choices for this subagent', (tester) async {
      host = FakeHost();
      final agent = agentWithSubagents();
      await pumpLook(tester, const Look(), Scaffold(body: SubagentSheet(state: agent.subagentStore['d-done']!, agent: agent)), height: 1700);
      await tester.tap(find.byTooltip('Share'));
      await frames(tester);
      expect(find.text('Share this subagent'), findsOneWidget);
      expect(find.text('Copy as Markdown'), findsOneWidget);
      expect(host, isNotNull);
    });

    testWidgets('scrolled up while it works, a button goes back to the newest step and keeps following it', (tester) async {
      host = FakeHost();
      final agent = agentWithSubagents();
      final s = agent.subagentStore['a-running']!;
      await pumpLook(tester, const Look(), Scaffold(body: SubagentSheet(state: s, agent: agent)), height: 700);
      final list = find.byType(Scrollable).first;
      ScrollPosition pos() => tester.state<ScrollableState>(list).position;
      expect(pos().maxScrollExtent, greaterThan(200), reason: 'the steps are longer than the sheet');
      expect(find.byTooltip('Scroll to bottom'), findsOneWidget, reason: 'opened at the top, away from the newest step');

      await tester.tap(find.byTooltip('Scroll to bottom'));
      await frames(tester);
      expect(pos().pixels, closeTo(pos().maxScrollExtent, 1));
      expect(find.byTooltip('Scroll to bottom'), findsNothing);
      expect(pos().maxScrollExtent, greaterThan(200));

      // A new step arrives: the sheet stays on it.
      final before = pos().maxScrollExtent;
      for (var i = 0; i < 4; i++) {
        s.applyEvent({'type': 'tool_execution_start', 'toolCallId': 'new$i', 'toolName': 'bash', 'args': {'command': 'echo $i'}});
      }
      agent.notifyListeners();
      await frames(tester);
      await tester.pump(const Duration(seconds: 1)); // a spring back from an estimated end settles
      expect(pos().maxScrollExtent, greaterThan(before));
      expect(pos().pixels, closeTo(pos().maxScrollExtent, 1));

      // Dragging up to read stops following.
      await tester.drag(list, const Offset(0, 300));
      await frames(tester);
      final reading = pos().pixels;
      s.applyEvent({'type': 'tool_execution_start', 'toolCallId': 'more', 'toolName': 'bash', 'args': {'command': 'echo more'}});
      agent.notifyListeners();
      await frames(tester);
      expect(pos().pixels, reading);
      expect(find.byTooltip('Scroll to bottom'), findsOneWidget);
    });
  });
}

// Keeps the Tristate import used where the SDK's semantics matchers need it.
// ignore: unused_element
const _tristate = Tristate.none;
