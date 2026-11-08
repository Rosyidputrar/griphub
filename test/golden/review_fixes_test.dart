// Regression tests for the review's Flutter findings: a saved chat with odd data still opens; the screen companion
// never runs unseen and survives odd elements; the memory snapshot is asked once; chat titles are shown as written;
// a broken model row does not break the vision screen; pointer lines are hidden only in companion answers; the new
// verification results are worded.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:griphub_agent/agent/companion.dart';
import 'package:griphub_agent/agent/drafts.dart';
import 'package:griphub_agent/agent/models.dart';
import 'package:griphub_agent/ui/memory_screen.dart';
import 'package:griphub_agent/ui/message_views.dart';
import 'package:griphub_agent/ui/vision_translator_screen.dart';
import 'package:griphub_agent/ui/verify_view.dart';

import 'harness.dart';

Future<void> frames(WidgetTester tester, [int n = 8]) async {
  for (var i = 0; i < n; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  setUpAll(loadAppFonts);
  setUp(() {
    layoutErrors.clear();
    Drafts.root = Directory.systemTemp.createTempSync('drafts-').path;
  });

  testWidgets('a saved chat whose memory proposal has an id of another type still opens', (tester) async {
    final host = FakeHost();
    host.answers['messages'] = (_) => [
      {'role': 'user', 'content': 'Ingat aku suka kopi'},
      {
        'role': 'assistant',
        'stopReason': 'toolUse',
        'content': [
          {'type': 'toolCall', 'id': 'call_1', 'name': 'remember', 'arguments': {'text': 'Suka kopi'}},
        ],
      },
      {'role': 'toolResult', 'toolCallId': 'call_1', 'toolName': 'remember', 'content': [{'type': 'text', 'text': 'Proposed'}], 'details': {'proposal': {'id': 7, 'text': 'Suka kopi', 'status': 3}}},
    ];
    final agent = newAgent();
    await tester.pump();
    await agent.loadHistory();
    expect(agent.entries, isNotEmpty, reason: 'the chat opened');
    expect(host.sent('memory_proposals'), isEmpty, reason: 'no id to ask about');
    final p = MemoryProposal({'id': 7, 'text': 'Suka kopi', 'status': 3});
    expect(p.id, '');
    expect(p.status, 'pending');
  });

  testWidgets('companion: the host refusing the start stops capture on the phone at once', (tester) async {
    final host = FakeHost();
    final calls = <String>[];
    host.methods['companionStart'] = (_) {
      calls.add('start');
      return true;
    };
    host.methods['companionStop'] = (_) {
      calls.add('stop');
      return null;
    };
    host.answers['companion_start'] = (_) => HostError('The agent is still working in this chat.');
    final agent = newAgent();
    await tester.pump();
    await expectLater(ScreenCompanion.instance.start(agent), throwsA(anything));
    expect(calls, ['start', 'stop']);
    expect(ScreenCompanion.instance.active, isFalse);
  });

  testWidgets('companion: an element without a usable id is left out, the step still goes', (tester) async {
    final host = FakeHost();
    host.methods['companionStart'] = (_) => true;
    host.methods['companionStop'] = (_) => null;
    host.methods['companionClearHighlight'] = (_) => null;
    host.methods['companionCapture'] = (_) => {'data': 'SlBFRw==', 'mimeType': 'image/jpeg', 'width': 540, 'height': 1200, 'screenWidth': 1080, 'screenHeight': 2400, 'mean': 120.0, 'deviation': 60.0};
    host.methods['a11yStatus'] = (_) => true;
    host.methods['a11yTree'] = (_) => [
      {'id': 5, 'text': 'Rusak', 'x': 0, 'y': 0, 'w': 10, 'h': 10},
      {'text': 'Tanpa id'},
      {'id': 'n1', 'text': 'Transfer', 'x': 40, 'y': 1800, 'w': 300, 'h': 120},
    ];
    host.answers['companion_start'] = (_) => {'active': true};
    host.answers['companion_stop'] = (_) => {'active': false};
    final agent = newAgent();
    await tester.pump();
    await ScreenCompanion.instance.start(agent);
    await ScreenCompanion.instance.step(agent, 'Transfer di mana?');
    final tree = host.sent('companion_turn').single['tree'] as List;
    expect(tree.map((n) => (n as Map)['text']), ['Transfer']);
    await ScreenCompanion.instance.stop(agent);
  });

  testWidgets('what the agent remembered is asked for once, not on every rebuild', (tester) async {
    final host = FakeHost();
    host.answers['memory_snapshot'] = (_) => {'global': [], 'project': [], 'projectPath': null, 'left': 0, 'at': 0};
    final agent = newAgent()..sessionId = 's1';
    await pumpLook(tester, const Look(), MemorySnapshotScreen(agent: agent));
    await frames(tester);
    // Rebuilds (a theme or text size change) do not ask again.
    await pumpLook(tester, const Look(dark: true), MemorySnapshotScreen(agent: agent));
    await frames(tester);
    expect(host.sent('memory_snapshot'), hasLength(1));
  });

  test('a chat named like a sentence of the app is shown as named; an untitled one in the app\'s language', () {
    final named = ChatView.chat('a.jsonl')..name = 'Settings';
    expect(named.untitled, isFalse);
    expect(named.title, 'Settings');
    final blank = ChatView.chat('b.jsonl');
    expect(blank.untitled, isTrue);
  });

  testWidgets('one broken model row does not take the vision translator screen down', (tester) async {
    final host = FakeHost();
    host.answers['vision_translator_info'] = (_) => {
      'models': [
        {'id': null, 'name': 'Rusak'},
        'bukan model',
        {'id': 'gemini-3.8-flash', 'name': 'Gemini 3.8 Flash', 'credits': 1.5, 'available': true},
      ],
      'defaultAllowed': ['gemini-3.8-flash'],
      'current': {'id': 'gemini-3.8-flash'},
    };
    await pumpLook(tester, const Look(), VisionTranslatorScreen(agent: newAgent()), height: 1200);
    await frames(tester, 12);
    expect(find.text('Gemini 3.8 Flash'), findsWidgets);
    expect(find.text('Rusak'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a pointer line is hidden only in the answer to a companion step', (tester) async {
    FakeHost();
    AssistantEntry reply(String text) {
      final a = newAgent();
      a.addHistoryMessage({
        'role': 'assistant',
        'stopReason': 'stop',
        'content': [
          {'type': 'text', 'text': text},
        ],
      });
      return a.entries.whereType<AssistantEntry>().single;
    }

    const text = 'Ketuk Transfer.\nSOROT: #n1';
    await pumpLook(tester, const Look(), SingleChildScrollView(child: AssistantMessageView(reply(text), tools: const {}, companionStep: true)));
    await frames(tester);
    expect(find.textContaining('SOROT'), findsNothing);
    // Anywhere else, the text is the text (a user may write about "SOROT:" in an ordinary chat).
    await pumpLook(tester, const Look(), SingleChildScrollView(child: AssistantMessageView(reply(text), tools: const {})));
    await frames(tester);
    expect(find.textContaining('SOROT'), findsOneWidget);
  });

  test('the new verification results are worded, not raw codes', () {
    for (final status in ['passed-tests-changed', 'setup-changed', 'unmeasured']) {
      expect(verifyStatusLabel(status), isNot(contains('-')), reason: status);
      expect(verifyStatusLabel(status), isNot('No test could be run for this project'), reason: status);
    }
  });
}
